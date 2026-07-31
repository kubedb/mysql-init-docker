#!/usr/bin/env bash
#set -x
# run_innodb.sh — MySQL InnoDB Cluster init script (unified)
#
# Compatibility: MySQL 8.0.x, 8.4.x, and 9.x with appscode images
# (ghcr.io/appscode-images/mysql). Version-specific behaviour is gated at
# runtime via the version_ge helper below — do not fork this script per
# minor version. If a new version-conditional path is needed, add a
# version_ge gate inline rather than creating a parallel branch.
#
# Version-conditional points (search "version_ge" in this file):
#   - my.cnf: emit `mysql_native_password=ON` only on versions <9.0
#     (plugin was removed in 9.x; mysqld refuses to start with the option)
#   - first-boot RESET: use `RESET BINARY LOGS AND GTIDS` on >=8.4,
#     `RESET MASTER` on older
#   - configureInstance gate: always use dba.checkInstanceConfiguration
#     (gtid_mode shortcut breaks on 9.6+ where it ships ON by default)
#   - TRANSACTION_GTID_TAG GRANT is wrapped with `2>/dev/null`; silently
#     no-ops on versions <9.6 where the privilege does not exist
#
# Notes shared across versions:
#   1. Entrypoint at /usr/local/bin/docker-entrypoint.sh on appscode images
#   2. docker-entrypoint.sh creates root@% — CREATE USER must be IF NOT EXISTS
#   3. mysqlsh on 8.4+ defaults to SQL mode (--js needed for JavaScript API)
#   4. dba.configureInstance() removed `password`/`interactive` options on 8.4+
#   5. REQUIRE SSL strictly enforced on socket on 8.4+ (use TCP for repl auth)

env | sort | grep "POD\|HOST\|NAME"
echo "running">/scripts/setup.txt
RECOVERY_DONE_FILE="/tmp/recovery.done"
if [[ "$PITR_RESTORE" == "true" ]]; then
    while true; do
      sleep 2
      echo "Point In Time Recovery In Progress. Waiting for $RECOVERY_DONE_FILE file"
      if [[ -e "$RECOVERY_DONE_FILE" ]]; then
        echo "$RECOVERY_DONE_FILE found."
        break
      fi
    done
fi

if [[ -e "$RECOVERY_DONE_FILE" ]]; then
  rm $RECOVERY_DONE_FILE
fi

function timestamp() {
    date +"%Y/%m/%d %T"
}

function log() {
    local type="$1"
    local msg="$2"
    echo "$(timestamp) [$script_name] [$type] $msg"
}

# detect_mysql_version parses `mysqld --version` and exports MYSQL_MAJOR /
# MYSQL_MINOR / MYSQL_PATCH. Falls back to "8.4.0" if parsing fails — that
# matches the middle-of-the-road behaviour least likely to break either end.
detect_mysql_version() {
    local raw
    raw=$(mysqld --version 2>/dev/null | grep -oE 'Ver [0-9]+\.[0-9]+\.[0-9]+' | head -1 | awk '{print $2}')
    if [[ -z "$raw" ]]; then
        log "WARNING" "could not parse mysqld --version output; defaulting to 8.4.0"
        raw="8.4.0"
    fi
    MYSQL_MAJOR=${raw%%.*}
    local rest=${raw#*.}
    MYSQL_MINOR=${rest%%.*}
    MYSQL_PATCH=${rest#*.}
    log "INFO" "detected MySQL version family: ${MYSQL_MAJOR}.${MYSQL_MINOR}.${MYSQL_PATCH}"
}

# version_ge MAJ MIN — returns 0 if detected version >= MAJ.MIN, else 1.
# Use to gate version-specific behaviour, e.g. `if version_ge 9 0; then ...`
version_ge() {
    local want_major=$1 want_minor=$2
    if [[ "$MYSQL_MAJOR" -gt "$want_major" ]]; then return 0; fi
    if [[ "$MYSQL_MAJOR" -eq "$want_major" && "$MYSQL_MINOR" -ge "$want_minor" ]]; then return 0; fi
    return 1
}

detect_mysql_version

args=$@
report_host="$HOSTNAME.$GOV_SVC.$POD_NAMESPACE"
log "INFO" "report_host = $report_host"

# wait for the peer-list file created by coordinator
while [ ! -f "/scripts/peer-list" ]; do
    log "WARNING" "peer-list is not created yet"
    sleep 1
done

hosts=$(cat "/scripts/peer-list")
IFS=', ' read -r -a peers <<<"$hosts"
echo "${peers[@]}"
log "INFO" "hosts are ${peers[@]}"

# Create a writable dir for mysqlsh's configureInstance() output.
# Copy user's custom config (read-only Secret mount in conf.d/) into this writable dir.
# Only include the writable dir in my.cnf — mysqlsh will write its config here too.
INNODB_CONF_DIR="/etc/mysql/innodb-conf.d"
mkdir -p "$INNODB_CONF_DIR"
# Copy custom config files from read-only conf.d/ to writable dir
if [ -d /etc/mysql/conf.d ] && ls /etc/mysql/conf.d/*.cnf >/dev/null 2>&1; then
    cp /etc/mysql/conf.d/*.cnf "$INNODB_CONF_DIR/" 2>/dev/null
    log "INFO" "Copied custom config from conf.d/ to writable $INNODB_CONF_DIR/"
fi
# Compute the GR allowlist CIDR (match the innodb-support-80 behaviour).
# IDC's AdminAPI normally writes its own allowlist via mysqlsh, but the
# original 8.0 branch always seeded one in my.cnf for safety, especially in
# IPv6 environments where the dynamic discovery path can be flaky. Compute
# from POD_IP / POD_IP_TYPE if MYSQL_GROUP_REPLICATION_IP_WHITELIST is unset.
whitelist="$MYSQL_GROUP_REPLICATION_IP_WHITELIST"
if [ -z "$whitelist" ]; then
    if [[ "$POD_IP_TYPE" == "IPv6" ]]; then
        whitelist="${POD_IP}/64"
    else
        whitelist="${POD_IP}/16"
    fi
fi

# Compose the full [mysqld] section once so the resulting my.cnf has a
# single contiguous [mysqld] block. mysqld accepts multiple [mysqld]
# sections (it merges them) but it's cleaner and easier to debug with one.
{
    echo "!includedir ${INNODB_CONF_DIR}"
    echo "[mysqld]"
    echo "# Use MySQL communication stack instead of XCom (8.0.27+)."
    echo "# Benefits: no extra port 33061, no IP allowlist needed, uses MySQL auth + SSL."
    echo "loose-group_replication_communication_stack = MYSQL"
    echo "# Faster failover on network partition (match run.sh)"
    echo "loose_group_replication_unreachable_majority_timeout = 20"
    echo "loose_group_replication_exit_state_action = OFFLINE_MODE"

    # Seed allowlist on 8.0.x (matches innodb-support-80). On 8.4+ the
    # communication_stack = MYSQL setting above means GR rides on the regular
    # MySQL port (3306) using MySQL auth + SSL, so the GR-specific IP
    # allowlist is unused — skip emitting it. AdminAPI may also rewrite this
    # when configureInstance runs; the seed value is the pre-AdminAPI default.
    if ! version_ge 8 4 && [[ -n "$whitelist" ]]; then
        echo "loose-group_replication_ip_allowlist = \"${whitelist}\""
    fi

    # Runtime tunables sourced from operator env vars (matches innodb-support-80).
    if [[ -n "$INNODB_BUFFER_POOL_SIZE" ]]; then
        echo "innodb_buffer_pool_size = \"$INNODB_BUFFER_POOL_SIZE\""
    fi
    if [[ -n "$GROUP_REPLICATION_MESSAGE_CACHE_SIZE" ]]; then
        echo "loose-group-replication-message-cache-size = \"$GROUP_REPLICATION_MESSAGE_CACHE_SIZE\""
    fi
    if [[ -n "$BINLOG_EXPIRE_LOGS_SECONDS" ]]; then
        echo "binlog_expire_logs_seconds = \"$BINLOG_EXPIRE_LOGS_SECONDS\""
    fi

    # default-authentication-plugin (alias default_authentication_plugin):
    # deprecated in 8.0.27, REMOVED in 8.4.0. mysqld aborts on unknown variable
    # if set against 8.4+. Emit only on <8.4 so 8.0 clusters keep the legacy
    # default; on 8.4+ the equivalent toggle is the mysql_native_password=ON
    # server variable emitted further below (gated to 8.4-only).
    if ! version_ge 8 4; then
        echo "default-authentication-plugin=mysql_native_password"
    fi

    # log_error_suppression_list silences the "mysql_native_password is
    # deprecated" warning (MY-013360). The warning only fires on 8.0/8.4
    # where the plugin still exists; on 9.x the plugin is removed entirely
    # so the suppression is unneeded. Variable itself is valid on 9.x
    # (harmless) but skipped to keep config surface minimal.
    if ! version_ge 9 0; then
        echo "log_error_suppression_list = 'MY-013360'"
    fi

    # Multi-Primary mode: allow all nodes to accept writes
    if [[ "$PRIMARY_TYPE" == "Multi-Primary" ]]; then
        echo "# Multi-Primary mode (match run.sh)"
        echo "loose-group_replication_single_primary_mode = OFF"
        echo "loose-group_replication_enforce_update_everywhere_checks = ON"
    fi

    # mysql_native_password=ON is a 8.4-only option:
    #   - 8.0.x: the option does not exist; mysqld aborts on "unknown variable".
    #   - 8.4.x: caching_sha2_password is the default; setting =ON re-enables
    #            the legacy plugin for backwards compatibility.
    #   - 9.x:   the plugin was removed entirely; mysqld aborts.
    # Emit only on 8.4.x — i.e. version >= 8.4 AND version < 9.0.
    if version_ge 8 4 && ! version_ge 9 0; then
        echo "# Re-enable legacy auth plugin (8.4-only option)"
        echo "mysql_native_password=ON"
    fi
} >>/etc/mysql/my.cnf

if [[ "$PRIMARY_TYPE" == "Multi-Primary" ]]; then
    log "INFO" "Configured Multi-Primary mode"
fi

function retry {

    local retries="$1"
    shift
    local count=0
    local wait=1
    until "$@"; do
        exit="$?"
        if [ $count -lt $retries ]; then
            log "INFO" "Attempt $count/$retries. Command exited with exit_code: $exit. Retrying after $wait seconds..."
            sleep $wait
        else
            log "INFO" "Command failed in all $retries attempts with exit_code: $exit. Stopping trying any further...."
            return $exit
        fi
        count=$(($count + 1))
        # Allow coordinator to stop retries (match run.sh)
        retryfile="/scripts/retry-stop"
        if [ -e "$retryfile" ]; then
            return 0
        fi
    done
    return 0
}

function wait_for_host_online() {
    log "INFO" "checking for host $2 to come online"
    local mysqlshell="mysql -u$1 -h$2 -p$3"
    local max_restarts=60
    local restarts=0

    while true; do
        if ! kill -0 "$pid" 2>/dev/null; then
            if (( restarts >= max_restarts )); then
                log "ERROR" "mysqld (pid=$pid) died and exceeded $max_restarts restart attempts. Aborting."
                exit 1
            fi
            restarts=$((restarts + 1))
            log "ERROR" "mysqld (pid=$pid) is no longer running. Restart attempt $restarts/$max_restarts..."
            start_mysqld_in_background
            sleep 10
            continue
        fi
        out=$(${mysqlshell} -e "select 1;" | head -n1 | awk '{print$1}')
        log "INFO" "Attempt $i: Pinging '$report_host' has returned: '$out'...................................."
        if [[ "$out" == "1" ]]; then
            break
        fi
        log "INFO" "Pinging '$report_host' has returned: '$out' (pid=$pid alive, restarts=$restarts)"
        echo -n .
        sleep 1
    done

    log "INFO" "mysql daemon is ready to use......."

    # Set read-only immediately after MySQL starts to prevent any external
    # process (e.g. KubeDB health checker) from writing local GTIDs before
    # the node joins the cluster. Cannot be set in my.cnf because it blocks --initialize.
    # (match run.sh)
    local mysql_ro="mysql -u${MYSQL_ROOT_USERNAME} -hlocalhost -p${MYSQL_ROOT_PASSWORD} --port=3306"
    ${mysql_ro} -N -e "SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;" 2>/dev/null
    log "INFO" "Set super_read_only=ON to prevent errant GTIDs"
}

# mysql client shorthand — always use root for local operations
mysql_local="mysql -u${MYSQL_ROOT_USERNAME} -hlocalhost -p${MYSQL_ROOT_PASSWORD} --port=3306"
# mysqlsh shorthand — root for local, --js for JavaScript API
mysqlsh_local="mysqlsh --js -u${MYSQL_ROOT_USERNAME} -p${MYSQL_ROOT_PASSWORD}"
replication_user=repl

clone_progress_interval=${CLONE_PROGRESS_INTERVAL:-15}

# dba.addInstance waits dba.restartWaitTimeout seconds for the post-clone restart.
# Raising it does not help: the clone's self-RESTART fails immediately (MY-013462,
# nothing supervises mysqld in the container) and Group Replication evicts the
# member on that error before any restart wait is consulted. Left at the default.
dba_restart_wait_timeout=${DBA_RESTART_WAIT_TIMEOUT:-60}

# log_clone_progress polls performance_schema.clone_progress and logs how far the
# running clone has got. Mirrors the GroupReplication path in run.sh: seeding a
# large database takes many minutes during which the pod looks idle, so without
# this a healthy long clone is indistinguishable from a stuck one.
#
# The clone is driven by dba.addInstance against the primary, but the data is
# written by the joining instance — this script's own host — so the progress rows
# are local. addInstance blocks until the clone finishes, so this runs as a
# background poller and is stopped once the call returns.
function log_clone_progress() {
    while true; do
        # FILE COPY is the stage that moves the data; the others are negligible.
        progress=$(${mysql_local} -N -B -e "
            SELECT CONCAT(
                     STAGE, ' ',
                     ROUND(100 * DATA / ESTIMATE, 1), '% (',
                     ROUND(DATA / 1024 / 1024), ' MiB of ',
                     ROUND(ESTIMATE / 1024 / 1024), ' MiB, ',
                     ROUND(DATA_SPEED / 1024 / 1024), ' MiB/s)')
              FROM performance_schema.clone_progress
             WHERE ESTIMATE > 0 AND STATE <> 'Not Started'
             ORDER BY ID DESC LIMIT 1;" 2>/dev/null)
        if [[ -n "$progress" ]]; then
            log "INFO" "Clone progress: $progress"
        fi
        sleep "$clone_progress_interval"
    done
}

# Kill any stale mysqlsh AdminAPI session holding the cluster-wide EXCLUSIVE lock
# on $1 (usually the primary). A session holding AdminAPI_lock while in Sleep
# state means a previous mysqlsh call died without releasing — rescan/addInstance/
# rejoinInstance will hang with MYSQLSH 51500. Legitimate in-flight AdminAPI ops
# are always in Query state, never Sleep. Kill Sleep>5s holders to auto-recover.
function clear_stale_cluster_lock() {
    local target_host=$1
    local mysql_root="mysql -u${MYSQL_ROOT_USERNAME} -h${target_host} -p${MYSQL_ROOT_PASSWORD} --port=3306 -N"
    local stuck_ids
    stuck_ids=$(${mysql_root} -e "
        SELECT t.PROCESSLIST_ID
        FROM performance_schema.metadata_locks m
        JOIN performance_schema.threads t ON m.OWNER_THREAD_ID = t.THREAD_ID
        WHERE m.OBJECT_SCHEMA='AdminAPI_cluster'
          AND m.OBJECT_NAME='AdminAPI_lock'
          AND m.LOCK_TYPE='EXCLUSIVE'
          AND t.PROCESSLIST_COMMAND='Sleep'
          AND t.PROCESSLIST_TIME > 5;" 2>/dev/null | awk 'NF')
    if [[ -n "$stuck_ids" ]]; then
        for stuck_id in $stuck_ids; do
            log "WARNING" "Killing stale AdminAPI_lock holder on ${target_host} (conn=${stuck_id}, Sleep>5s)"
            ${mysql_root} -e "KILL ${stuck_id};" 2>/dev/null
        done
        sleep 2
    fi
}

function create_replication_user() {
    log "INFO" "Checking whether replication user exist or not..."

    retry 60 ${mysql_local} -N -e "select count(host) from mysql.user where mysql.user.user='${replication_user}';"
    out=$(${mysql_local} -N -e "select count(host) from mysql.user where mysql.user.user='${replication_user}';" | awk '{print$1}')

    # All operations in a SINGLE session with SQL_LOG_BIN=0 to prevent errant GTIDs.
    # Uses IF NOT EXISTS because appscode images already create root@% via entrypoint.
    # (match run.sh single-session pattern)
    if [[ "$out" -eq "0" ]]; then
        log "INFO" "Replication user not found. Creating new replication user..."
        retry 60 ${mysql_local} -N -e "
            SET SQL_LOG_BIN=0;
            SET GLOBAL super_read_only=OFF;
            SET GLOBAL read_only=OFF;
            CREATE USER IF NOT EXISTS '${replication_user}'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' REQUIRE SSL;
            GRANT CREATE USER, FILE, PROCESS, RELOAD, REPLICATION CLIENT, REPLICATION SLAVE, SELECT, SHUTDOWN, SUPER ON *.* TO '${replication_user}'@'%' WITH GRANT OPTION;
            GRANT DELETE, INSERT, UPDATE ON mysql.* TO '${replication_user}'@'%' WITH GRANT OPTION;
            GRANT ALTER, ALTER ROUTINE, CREATE, CREATE ROUTINE, CREATE TEMPORARY TABLES, CREATE VIEW, DELETE, DROP, EVENT, EXECUTE, INDEX, INSERT, LOCK TABLES, REFERENCES, SHOW VIEW, TRIGGER, UPDATE ON mysql_innodb_cluster_metadata.* TO '${replication_user}'@'%' WITH GRANT OPTION;
            GRANT ALTER, ALTER ROUTINE, CREATE, CREATE ROUTINE, CREATE TEMPORARY TABLES, CREATE VIEW, DELETE, DROP, EVENT, EXECUTE, INDEX, INSERT, LOCK TABLES, REFERENCES, SHOW VIEW, TRIGGER, UPDATE ON mysql_innodb_cluster_metadata_bkp.* TO '${replication_user}'@'%' WITH GRANT OPTION;
            GRANT ALTER, ALTER ROUTINE, CREATE, CREATE ROUTINE, CREATE TEMPORARY TABLES, CREATE VIEW, DELETE, DROP, EVENT, EXECUTE, INDEX, INSERT, LOCK TABLES, REFERENCES, SHOW VIEW, TRIGGER, UPDATE ON mysql_innodb_cluster_metadata_previous.* TO '${replication_user}'@'%' WITH GRANT OPTION;
            GRANT CLONE_ADMIN, BACKUP_ADMIN, CONNECTION_ADMIN, EXECUTE, GROUP_REPLICATION_ADMIN, PERSIST_RO_VARIABLES_ADMIN, REPLICATION_APPLIER, REPLICATION_SLAVE_ADMIN, ROLE_ADMIN, SYSTEM_VARIABLES_ADMIN ON *.* TO '${replication_user}'@'%' WITH GRANT OPTION;
            CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
            GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION;
            FLUSH PRIVILEGES;
            SET GLOBAL read_only=ON;
            SET GLOBAL super_read_only=ON;
            SET SQL_LOG_BIN=1;
        "
        # TRANSACTION_GTID_TAG is required by MySQL 9.6+ but doesn't exist in 8.4.x.
        # Grant separately — must disable super_read_only first (it was re-enabled above).
        ${mysql_local} -N -e "SET SQL_LOG_BIN=0; SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF; GRANT TRANSACTION_GTID_TAG ON *.* TO '${replication_user}'@'%' WITH GRANT OPTION; FLUSH PRIVILEGES; SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON; SET SQL_LOG_BIN=1;" 2>/dev/null
        log "INFO" "Granted TRANSACTION_GTID_TAG (if supported by this MySQL version)"

        # Clear errant GTIDs generated by Docker entrypoint during initialization.
        # MySQL 9.6+ has gtid_mode=ON by default, so the entrypoint's DDL (CREATE USER
        # root, timezone loading, etc.) generates GTIDs before our script runs. These
        # errant GTIDs prevent joining the cluster with recoveryMethod:'incremental'.
        # Even on 8.0/8.4 where gtid_mode defaults to OFF, the entrypoint emits
        # anonymous events into binlog.000001 — also worth clearing on first boot
        # so subsequent log-based backups don't carry the bootstrap noise.
        # Syntax: RESET MASTER on <8.4, RESET BINARY LOGS AND GTIDS on >=8.4.
        log "INFO" "Resetting binary logs and GTIDs to clear entrypoint-generated transactions..."
        if version_ge 8 4; then
            ${mysql_local} -N -e "RESET BINARY LOGS AND GTIDS;" 2>/dev/null
        else
            ${mysql_local} -N -e "RESET MASTER;" 2>/dev/null
        fi
    else
        log "INFO" "Replication user exists. Updating password if changed..."
        # Update password in case it was rotated via RotateAuth (match run.sh)
        retry 60 ${mysql_local} -N -e "
            SET SQL_LOG_BIN=0;
            SET GLOBAL super_read_only=OFF;
            SET GLOBAL read_only=OFF;
            ALTER USER '${replication_user}'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
            ALTER USER IF EXISTS 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
            FLUSH PRIVILEGES;
            SET GLOBAL read_only=ON;
            SET GLOBAL super_read_only=ON;
            SET SQL_LOG_BIN=1;
        "
        # TRANSACTION_GTID_TAG is required by MySQL 9.6+ but doesn't exist in 8.4.x.
        # Grant it separately so failure on older versions doesn't break the script.
        ${mysql_local} -N -e "SET SQL_LOG_BIN=0; SET GLOBAL super_read_only=OFF; GRANT TRANSACTION_GTID_TAG ON *.* TO '${replication_user}'@'%' WITH GRANT OPTION; FLUSH PRIVILEGES; SET GLOBAL super_read_only=ON; SET SQL_LOG_BIN=1;" 2>/dev/null
    fi

    # Ensure the InnoDB Cluster privileges on EVERY start, not only when the
    # replication user is created.
    #
    # A standalone -> InnoDBCluster promotion preserves the data directory by
    # design, so ${replication_user} already exists there — created by run.sh with
    # only REPLICATION SLAVE and BACKUP_ADMIN. The creation branch above is guarded
    # on the user not existing, so on a promoted database it is skipped and the
    # InnoDB-specific grants are never issued. MySQL Router bootstraps as this user
    # and then loops forever on:
    #
    #   Error executing MySQL query "SELECT * FROM mysql_innodb_cluster_metadata.schema_version":
    #   SELECT command denied to user 'repl'@'...' for table 'schema_version' (1142)
    #
    # leaving the Router never Ready and — because the primary Service selects the
    # Router for InnoDBCluster — the database unreachable, even though the members
    # are ONLINE and writable.
    #
    # GRANT is idempotent, so re-issuing on an already-granted user is a no-op.
    log "INFO" "Ensuring replication user has the InnoDB Cluster privileges..."
    retry 60 ${mysql_local} -N -e "
        SET SQL_LOG_BIN=0;
        SET GLOBAL super_read_only=OFF;
        SET GLOBAL read_only=OFF;
        GRANT CREATE USER, FILE, PROCESS, RELOAD, REPLICATION CLIENT, REPLICATION SLAVE, SELECT, SHUTDOWN, SUPER ON *.* TO '${replication_user}'@'%' WITH GRANT OPTION;
        GRANT DELETE, INSERT, UPDATE ON mysql.* TO '${replication_user}'@'%' WITH GRANT OPTION;
        GRANT ALTER, ALTER ROUTINE, CREATE, CREATE ROUTINE, CREATE TEMPORARY TABLES, CREATE VIEW, DELETE, DROP, EVENT, EXECUTE, INDEX, INSERT, LOCK TABLES, REFERENCES, SHOW VIEW, TRIGGER, UPDATE ON mysql_innodb_cluster_metadata.* TO '${replication_user}'@'%' WITH GRANT OPTION;
        GRANT ALTER, ALTER ROUTINE, CREATE, CREATE ROUTINE, CREATE TEMPORARY TABLES, CREATE VIEW, DELETE, DROP, EVENT, EXECUTE, INDEX, INSERT, LOCK TABLES, REFERENCES, SHOW VIEW, TRIGGER, UPDATE ON mysql_innodb_cluster_metadata_bkp.* TO '${replication_user}'@'%' WITH GRANT OPTION;
        GRANT ALTER, ALTER ROUTINE, CREATE, CREATE ROUTINE, CREATE TEMPORARY TABLES, CREATE VIEW, DELETE, DROP, EVENT, EXECUTE, INDEX, INSERT, LOCK TABLES, REFERENCES, SHOW VIEW, TRIGGER, UPDATE ON mysql_innodb_cluster_metadata_previous.* TO '${replication_user}'@'%' WITH GRANT OPTION;
        GRANT CLONE_ADMIN, BACKUP_ADMIN, CONNECTION_ADMIN, EXECUTE, GROUP_REPLICATION_ADMIN, PERSIST_RO_VARIABLES_ADMIN, REPLICATION_APPLIER, REPLICATION_SLAVE_ADMIN, ROLE_ADMIN, SYSTEM_VARIABLES_ADMIN ON *.* TO '${replication_user}'@'%' WITH GRANT OPTION;
        FLUSH PRIVILEGES;
        SET GLOBAL read_only=ON;
        SET GLOBAL super_read_only=ON;
        SET SQL_LOG_BIN=1;
    "

    touch /scripts/ready.txt
}

restart_required=0
already_configured=0

function configure_instance() {
    log "INFO" "configuring instance $report_host."

    # Use dba.checkInstanceConfiguration() to determine if configuration is needed.
    # NOTE: Cannot use gtid_mode=ON check because MySQL 9.6+ ships with gtid_mode=ON
    # by default, which would incorrectly skip configureInstance() on first boot.
    retry 60 ${mysqlsh_local} --sql -e "select 1;"
    check_result=$(${mysqlsh_local} -e "dba.checkInstanceConfiguration('${MYSQL_ROOT_USERNAME}:${MYSQL_ROOT_PASSWORD}@${report_host}:3306');" 2>&1)
    if echo "$check_result" | grep -q "status.*ok"; then
        log "INFO" "$report_host is already_configured."
        already_configured=1
        return
    fi

    log "INFO" "Instance needs configuration. Running dba.configureInstance()..."

    # In MySQL Shell 8.4+/9.x:
    #   - Pass credentials via URI (not via 'password' option — removed)
    #   - mycnfPath required so Shell writes config instead of prompting
    #   - restart:false — we handle restart ourselves (container environment)
    #   - Pipe 'yes' to auto-confirm any remaining prompts
    yes | ${mysqlsh_local} -e "dba.configureInstance('${MYSQL_ROOT_USERNAME}:${MYSQL_ROOT_PASSWORD}@${report_host}:3306',{mycnfPath:'/etc/mysql/my.cnf',restart:false});"

    # Manually restart mysqld after configuration (match run.sh pattern:
    # restart:false + manual shutdown, because mysqlsh can't restart a process it didn't start)
    log "INFO" "Shutting down mysqld for restart after configure..."
    mysqladmin -u${MYSQL_ROOT_USERNAME} -hlocalhost -p${MYSQL_ROOT_PASSWORD} --port=3306 shutdown
    wait $pid
    restart_required=1
}

function create_cluster() {
    local mysqlsh_remote="mysqlsh --js -u${MYSQL_ROOT_USERNAME} -p${MYSQL_ROOT_PASSWORD} -h${report_host}"
    clusterName=$(echo -n $BASE_NAME | sed 's/-/_/g')
    # Temporarily disable read-only for cluster bootstrap (match run.sh)
    ${mysql_local} -N -e "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;" 2>/dev/null
    # communicationStack:'MYSQL' — uses MySQL protocol on port 3306 instead of XCom on 33061.
    # consistency defaults to BEFORE_ON_PRIMARY_FAILOVER on 8.4+/9.x.
    if [[ "$PRIMARY_TYPE" == "Multi-Primary" ]]; then
        log "INFO" "Creating InnoDB Cluster in Multi-Primary mode"
        retry 5 $mysqlsh_remote -e "cluster=dba.createCluster('$clusterName',{communicationStack:'MYSQL',manualStartOnBoot:true,multiPrimary:true,force:true});"
    else
        retry 5 $mysqlsh_remote -e "cluster=dba.createCluster('$clusterName',{communicationStack:'MYSQL',manualStartOnBoot:true});"
    fi
}

function fix_metadata_uuids() {
    # After a pod restart with data loss (PVC deleted), MySQL generates a new server_uuid.
    # The InnoDB Cluster metadata still has the old UUID, causing dba.getCluster() to fail
    # with "unmanaged replication group" or "Metadata for instance not found".
    #
    # Strategy: find a peer that is BOTH (a) registered in metadata with a matching
    # server_uuid AND (b) currently ONLINE in the running GR group. Such a peer can
    # successfully serve as the entry point for dba.getCluster(). Then for any peer
    # whose metadata uuid is stale, remove + re-add via clone.
    #
    # NOTE: requiring MEMBER_STATE = ONLINE on the good_host is important — picking
    # a metadata-matching peer that's GR-OFFLINE (e.g. the joining pod itself) would
    # make dba.getCluster() raise the same "unmanaged replication group" error,
    # leaving the cluster stuck in a loop.
    log "INFO" "Checking for stale server_uuid in InnoDB Cluster metadata..."

    local good_host=""
    for host in "${peers[@]}"; do
        actual_uuid=$(mysql -u${MYSQL_ROOT_USERNAME} -h${host} -p${MYSQL_ROOT_PASSWORD} --port=3306 -N -e "SELECT @@server_uuid;" 2>/dev/null)
        if [[ -z "$actual_uuid" ]]; then
            continue
        fi
        stored_uuid=$(mysql -u${MYSQL_ROOT_USERNAME} -h${host} -p${MYSQL_ROOT_PASSWORD} --port=3306 -N -e \
            "SELECT mysql_server_uuid FROM mysql_innodb_cluster_metadata.instances WHERE address='${host}:3306';" 2>/dev/null)
        if [[ -z "$stored_uuid" || "$stored_uuid" != "$actual_uuid" ]]; then
            continue
        fi
        # Verify this host is also ONLINE in the running GR group — otherwise
        # dba.getCluster() against it would fail with "unmanaged replication group".
        local member_state
        member_state=$(mysql -u${MYSQL_ROOT_USERNAME} -h${host} -p${MYSQL_ROOT_PASSWORD} --port=3306 -N -e \
            "SELECT MEMBER_STATE FROM performance_schema.replication_group_members WHERE MEMBER_HOST='${host}';" 2>/dev/null)
        if [[ "$member_state" == "ONLINE" ]]; then
            good_host="$host"
            log "INFO" "fix_metadata_uuids: using $host as entry point (uuid matches metadata, MEMBER_STATE=ONLINE)"
            break
        fi
    done

    if [[ -z "$good_host" ]]; then
        log "WARNING" "No peer is BOTH metadata-matched AND ONLINE in GR. Cannot fix metadata — may need full cluster reboot."
        return
    fi

    # For each peer with mismatched UUID, remove the stale entry and re-add via clone
    for host in "${peers[@]}"; do
        actual_uuid=$(mysql -u${MYSQL_ROOT_USERNAME} -h${host} -p${MYSQL_ROOT_PASSWORD} --port=3306 -N -e "SELECT @@server_uuid;" 2>/dev/null)
        if [[ -z "$actual_uuid" ]]; then
            continue
        fi
        stored_uuid=$(mysql -u${MYSQL_ROOT_USERNAME} -h${host} -p${MYSQL_ROOT_PASSWORD} --port=3306 -N -e \
            "SELECT mysql_server_uuid FROM mysql_innodb_cluster_metadata.instances WHERE address='${host}:3306';" 2>/dev/null)

        if [[ -n "$stored_uuid" && "$stored_uuid" != "$actual_uuid" ]]; then
            log "INFO" "UUID mismatch for $host: metadata=$stored_uuid actual=$actual_uuid"
            log "INFO" "Removing stale instance from cluster and re-adding with fresh data..."
            local mysqlsh_good="mysqlsh --js -u${MYSQL_ROOT_USERNAME} -p${MYSQL_ROOT_PASSWORD} -h${good_host}"
            # Remove the stale metadata entry
            clear_stale_cluster_lock "${good_host}"
            ${mysqlsh_good} -e "cluster = dba.getCluster(); cluster.removeInstance('${host}:3306',{force:true});" 2>/dev/null
            # Re-add the instance — it will get a full data copy via recovery
            if [[ "$host" != "$report_host" ]]; then
                # Only re-add remote peers here; the current host will be added by join_in_cluster
                clear_stale_cluster_lock "${good_host}"
                ${mysqlsh_good} -e "cluster = dba.getCluster(); cluster.addInstance('${replication_user}:${MYSQL_ROOT_PASSWORD}@${host}:3306',{recoveryMethod:'clone'});" 2>/dev/null
            fi
        fi
    done
}

export primary=""
function select_primary() {
    for i in {900..0}; do
        for host in "${peers[@]}"; do
            local mysqlsh_peer="mysqlsh --js -u${MYSQL_ROOT_USERNAME} -h${host} -p${MYSQL_ROOT_PASSWORD}"
            selected_primary=($(${mysqlsh_peer} --sql -e "SELECT member_host FROM performance_schema.replication_group_members where member_role = 'PRIMARY' ;" 2>/dev/null))
            if [[ "${#selected_primary[@]}" -ge "2" ]]; then
                primary=${selected_primary[1]}
                log "INFO" "Primary found $primary."
                return
            fi
        done
        sleep 1
    done
    log "INFO" "Primary not found."
}

already_in_cluster=0

function is_already_in_cluster() {
    local mysqlsh_primary="mysqlsh --js -u${replication_user} -p${MYSQL_ROOT_PASSWORD} -h${primary}"
    # Fix stale UUIDs in metadata before calling dba.getCluster()
    fix_metadata_uuids
    # Use rescan() without options — addInstances and interactive were removed in MySQL Shell 9.6+
    clear_stale_cluster_lock "${primary}"
    ${mysqlsh_primary} -e "cluster = dba.getCluster(); cluster.rescan()"
    out=($(${mysqlsh_primary} --sql -e "SELECT member_host FROM performance_schema.replication_group_members where member_state='ONLINE';"))

    for host in ${out[@]}; do
        if [[ "$host" == "$report_host" ]]; then
            echo "$report_host is already in cluster"
            already_in_cluster=1
            return
        fi
    done
}

function join_in_cluster() {
    log "INFO" "$report_host joining in cluster"
    local mysqlsh_primary="mysqlsh --js -u${replication_user} -p${MYSQL_ROOT_PASSWORD} -h${primary}"
    # Refresh stale server_uuid entries in metadata before dba.getCluster().
    # If a peer was rebuilt (PVC delete, restore from another cluster, etc.)
    # its actual @@server_uuid no longer matches the metadata entry — without
    # this, dba.getCluster() raises "unmanaged replication group" and addInstance
    # loops forever.
    fix_metadata_uuids
    # After a clone the instance restarts and rejoins the group on its own; it is
    # then a member AdminAPI does not know about and addInstance would reject it.
    leave_group_if_unmanaged
    # Temporarily disable read-only for join operations (match run.sh)
    ${mysql_local} -N -e "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;" 2>/dev/null
    clear_stale_cluster_lock "${primary}"
    retry 10 ${mysqlsh_primary} -e "cluster = dba.getCluster(); cluster.addInstance('${replication_user}:${MYSQL_ROOT_PASSWORD}@${report_host}:3306',{recoveryMethod:'incremental'});"
}

function join_by_clone() {
    log "INFO" "$report_host joining in cluster by clone"
    local mysqlsh_primary="mysqlsh --js -u${replication_user} -p${MYSQL_ROOT_PASSWORD} -h${primary}"
    # Same rationale as join_in_cluster — heal stale metadata uuids before
    # dba.getCluster() is consulted.
    fix_metadata_uuids
    # Temporarily disable read-only for clone operations (match run.sh)
    ${mysql_local} -N -e "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;" 2>/dev/null
    clear_stale_cluster_lock "${primary}"
    retry 10 ${mysqlsh_primary} -e "cluster = dba.getCluster(); cluster.removeInstance('${report_host}:3306',{force:true});"
    clear_stale_cluster_lock "${primary}"
    # Report clone progress while addInstance blocks, and give the post-clone
    # restart room to finish instead of the 60s default.
    log_clone_progress &
    local progress_pid=$!
    retry 10 ${mysqlsh_primary} -e "
        shell.options['dba.restartWaitTimeout'] = ${dba_restart_wait_timeout};
        cluster = dba.getCluster();
        cluster.addInstance('${replication_user}:${MYSQL_ROOT_PASSWORD}@${report_host}:3306',{recoveryMethod:'clone'});"
    kill "$progress_pid" 2>/dev/null
    wait "$progress_pid" 2>/dev/null
    # Clone restarts mysqld — wait for the old process to finish
    wait $pid
}

# metadata_schema_exists is true once mysql_innodb_cluster_metadata has been
# replicated to this instance, i.e. the group this member sits in is an
# AdminAPI-managed InnoDB cluster rather than a plain Group Replication group.
function metadata_schema_exists() {
    local count
    count=$(${mysql_local} -N -B -e "
        SELECT COUNT(*) FROM information_schema.schemata
         WHERE schema_name = 'mysql_innodb_cluster_metadata';" 2>/dev/null)
    [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -gt 0 ]]
}

# is_registered_in_metadata is true when this instance's own address is recorded
# in the cluster metadata. A member can be ONLINE in the group and still be
# absent here — see the signal loop for how that happens and why it is fatal.
function is_registered_in_metadata() {
    local count
    count=$(${mysql_local} -N -B -e "
        SELECT COUNT(*) FROM mysql_innodb_cluster_metadata.instances
         WHERE address = '${report_host}:3306';" 2>/dev/null)
    [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -gt 0 ]]
}

# leave_group_if_unmanaged stops Group Replication when this instance is a group
# member the cluster metadata does not know about. mysqld rejoins the group on
# boot by itself, so after the post-clone restart the instance is back in the
# group before AdminAPI ever recorded it — and addInstance then refuses it
# ("already part of a Replication Group") while dba.getCluster() against it
# fails ("unmanaged replication group"). Leaving the group first turns the
# instance back into a plain joiner that addInstance can accept.
function leave_group_if_unmanaged() {
    local state
    state=$(${mysql_local} -N -e "
        SELECT MEMBER_STATE FROM performance_schema.replication_group_members
         WHERE MEMBER_HOST='${report_host}' LIMIT 1;" 2>/dev/null)
    if [[ -z "$state" || "$state" == "OFFLINE" ]]; then
        return
    fi
    if metadata_schema_exists && ! is_registered_in_metadata; then
        log "WARNING" "in the group ($state) but absent from the InnoDB Cluster metadata — leaving the group so the AdminAPI join can register it"
        ${mysql_local} -N -e "STOP GROUP_REPLICATION;" 2>/dev/null
    fi
}

joined_in_cluster=0
function check_instance_joined_in_cluster() {
    local mysqlsh_primary="mysqlsh --js -u${replication_user} -p${MYSQL_ROOT_PASSWORD} -h${primary}"
    out=($(${mysqlsh_primary} --sql -e "SELECT member_host FROM performance_schema.replication_group_members;"))

    for host in "${out[@]}"; do
        if [[ "$host" == "$report_host" ]]; then
            joined_in_cluster=1
            echo "$report_host successfully joined_in_cluster"
        fi
    done
}

function make_sure_instance_join_in_cluster() {
    local mysqlsh_primary="mysqlsh --js -u${replication_user} -p${MYSQL_ROOT_PASSWORD} -h${primary}"
    # Use rescan() without options — addInstances and interactive were removed in MySQL Shell 9.6+
    clear_stale_cluster_lock "${primary}"
    retry 10 ${mysqlsh_primary} -e "cluster = dba.getCluster(); cluster.rescan()"
}

function rejoin_in_cluster() {
    local mysqlsh_primary="mysqlsh --js -u${replication_user} -p${MYSQL_ROOT_PASSWORD} -h${primary}"
    # Fix stale UUIDs in metadata before calling dba.getCluster()
    fix_metadata_uuids
    # Temporarily disable read-only for rejoin (match run.sh)
    ${mysql_local} -N -e "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;" 2>/dev/null
    clear_stale_cluster_lock "${primary}"
    ${mysqlsh_primary} -e "cluster = dba.getCluster(); cluster.rejoinInstance('${replication_user}:${MYSQL_ROOT_PASSWORD}@${report_host}:3306')"
    out=($(${mysqlsh_primary} --sql -e "SELECT member_host FROM performance_schema.replication_group_members;"))

    for host in "${out[@]}"; do
        if [[ "$host" == "$report_host" ]]; then
            echo "$report_host successfully joined_in_cluster"
        fi
    done
    check_instance_joined_in_cluster
    if [[ "$joined_in_cluster" == "0" ]]; then
        make_sure_instance_join_in_cluster
    fi
    check_instance_joined_in_cluster
    if [[ "$joined_in_cluster" == "0" ]]; then
        clear_stale_cluster_lock "${primary}"
        retry 1 ${mysqlsh_primary} -e "cluster = dba.getCluster(); cluster.removeInstance('${report_host}:3306',{force:true});"
        join_in_cluster
    fi
}

export pid
function reboot_from_completeOutage() {
    local mysqlsh_self="mysqlsh --js -u${MYSQL_ROOT_USERNAME} -h${report_host} -p${MYSQL_ROOT_PASSWORD}"
    clusterName=$(echo -n $BASE_NAME | sed 's/-/_/g')

    # Before rebooting, stop GR on any peer stuck in ERROR state. Match
    # innodb-support's behaviour: dba.rebootClusterFromCompleteOutage()
    # refuses to proceed if any peer has GR in ERROR state ("belongs to a
    # GR group that is not managed as an InnoDB Cluster"); all peers must
    # be in OFFLINE state for the reboot to work.
    for host in "${peers[@]}"; do
        peer_state=$(mysql -u${MYSQL_ROOT_USERNAME} -h${host} -p${MYSQL_ROOT_PASSWORD} --port=3306 -N -e \
            "SELECT MEMBER_STATE FROM performance_schema.replication_group_members LIMIT 1;" 2>/dev/null)
        if [[ "$peer_state" == "ERROR" ]]; then
            log "INFO" "Stopping GR on $host (stuck in ERROR state) before cluster reboot..."
            mysql -u${MYSQL_ROOT_USERNAME} -h${host} -p${MYSQL_ROOT_PASSWORD} --port=3306 -N -e "STOP GROUP_REPLICATION;" 2>/dev/null
        fi
    done

    # Refresh any stale server_uuid rows in mysql_innodb_cluster_metadata.instances.
    # Handles the common PVC-deleted / pod-rebuilt case where the metadata
    # still references the previous server_uuid for the same address.
    fix_metadata_uuids

    # Temporarily disable read-only for reboot / createCluster (match run.sh)
    ${mysql_local} -N -e "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;" 2>/dev/null

    # Determine whether the InnoDB Cluster metadata schema exists AND
    # recognises this instance's server_uuid. dba.rebootClusterFromCompleteOutage()
    # requires both — without them mysqlsh fails with MYSQLSH 51300 ("function
    # not available through a session to a standalone instance"), and the
    # coordinator ends up looping the reboot signal forever. This happens after:
    #   - the metadata schema was dropped (manually or by an upstream cleanup);
    #   - a logical restore where the source's metadata referenced a different
    #     cluster's pod hostnames / server_uuids (so this server_uuid is unknown
    #     to the metadata that came along with the restore);
    #   - any cluster recreation where IDC metadata was wiped.
    # MySQL 9.x note: schema name and column layout for
    # mysql_innodb_cluster_metadata are unchanged from 8.x, so the same
    # introspection works.
    local has_metadata known_instance my_uuid
    has_metadata=$(${mysql_local} -N -e \
        "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='mysql_innodb_cluster_metadata';" \
        2>/dev/null || echo 0)
    my_uuid=$(${mysql_local} -N -e "SELECT @@server_uuid;" 2>/dev/null)
    known_instance=0
    if [[ "$has_metadata" == "1" && -n "$my_uuid" ]]; then
        known_instance=$(${mysql_local} -N -e \
            "SELECT COUNT(*) FROM mysql_innodb_cluster_metadata.instances WHERE mysql_server_uuid='$my_uuid';" \
            2>/dev/null || echo 0)
    fi

    if [[ "$has_metadata" == "1" && "$known_instance" == "1" ]]; then
        # Normal path — metadata is present and recognises this instance.
        log "INFO" "InnoDB Cluster metadata present; running rebootClusterFromCompleteOutage"
        yes | $mysqlsh_self -e "dba.rebootClusterFromCompleteOutage('$clusterName',{force:true})"
    else
        # Fallback path — metadata is missing or stale. Recreate it so this
        # node is recognised and the cluster can come back ONLINE without
        # operator intervention.
        log "WARN" "InnoDB Cluster metadata missing or does not recognise this server_uuid (has_metadata=$has_metadata, known_instance=$known_instance); falling back to createCluster"

        # Drop any stale metadata schemas so createCluster starts clean.
        # SQL_LOG_BIN=0 keeps these DDLs out of the binlog so peers don't
        # replay them during the next round of recovery.
        ${mysql_local} -N -e "
            SET SQL_LOG_BIN=0;
            DROP DATABASE IF EXISTS mysql_innodb_cluster_metadata;
            DROP DATABASE IF EXISTS mysql_innodb_cluster_metadata_bkp;
            DROP DATABASE IF EXISTS mysql_innodb_cluster_metadata_previous;
            SET SQL_LOG_BIN=1;
        " 2>/dev/null

        # If GR is already running on at least one member, adopt the live
        # group instead of bootstrapping a new one (preserves any post-outage
        # writes already in flight). Otherwise plain createCluster will
        # configure + bootstrap GR locally and seed metadata.
        local gr_online
        gr_online=$(${mysql_local} -N -e \
            "SELECT COUNT(*) FROM performance_schema.replication_group_members WHERE MEMBER_STATE='ONLINE';" \
            2>/dev/null || echo 0)

        local create_opts="multiPrimary:false,force:true"
        if [[ "$PRIMARY_TYPE" == "Multi-Primary" ]]; then
            create_opts="multiPrimary:true,force:true"
        fi

        if [[ "${gr_online}" -ge "1" ]]; then
            log "INFO" "GR already ONLINE on some member; createCluster with adoptFromGR:true"
            yes | $mysqlsh_self -e "dba.createCluster('$clusterName',{adoptFromGR:true,${create_opts}});"
        else
            log "INFO" "GR is OFFLINE everywhere; createCluster will bootstrap GR locally"
            yes | $mysqlsh_self -e "dba.createCluster('$clusterName',{${create_opts}});"
        fi
    fi

    clear_stale_cluster_lock "${report_host}"
    yes | $mysqlsh_self -e "cluster = dba.getCluster(); cluster.rescan()"
    wait $pid
}

function start_mysqld_in_background() {
    log "INFO" "Starting mysql server with 'docker-entrypoint.sh mysqld $args'..."
    # Use docker-entrypoint.sh (in PATH at /usr/local/bin/) — works on both
    # Oracle mysql-server images and appscode images.
    docker-entrypoint.sh mysqld --user=root --report-host=$report_host --bind-address=* $args &
    pid=$!
    log "INFO" "The process id of mysqld is '$pid'"
}

# ── Main flow ────────────────────────────────────────────────────────────────

start_mysqld_in_background
wait_for_host_online "${MYSQL_ROOT_USERNAME}" "localhost" "$MYSQL_ROOT_PASSWORD"
create_replication_user
configure_instance

if [[ "$restart_required" == "1" ]]; then
    start_mysqld_in_background
    wait_for_host_online "${MYSQL_ROOT_USERNAME}" "$report_host" "$MYSQL_ROOT_PASSWORD"
fi

mysqld_alive=0
function check_mysqld_alive() {
    kill -0 $pid
    exit="$?"
    if [[ "$exit" == "0" ]]; then
        mysqld_alive=1
    else
        mysqld_alive=0
    fi
}

# ── Signal loop ──────────────────────────────────────────────────────────────

while true; do
    echo "running">/scripts/setup.txt
    log "INFO" "creating setup.txt file"
    check_mysqld_alive
    if [[ "$mysqld_alive" == "1" ]]; then
        echo "mysqld process is running"
    else
        echo "need start mysqld and wait_for_mysqld_running"
        start_mysqld_in_background
        wait_for_host_online "${MYSQL_ROOT_USERNAME}" "$report_host" "$MYSQL_ROOT_PASSWORD"
    fi

    # wait for the signal file from coordinator
    # Also check if this node is already ONLINE in GR — this happens when
    # another pod's coordinator called rebootClusterFromCompleteOutage() which
    # rejoins all members remotely via mysqlsh AdminAPI, bypassing this script.
    while [ ! -f "/scripts/signal.txt" ]; do
        member_state=$(mysql -u${MYSQL_ROOT_USERNAME} -hlocalhost -p${MYSQL_ROOT_PASSWORD} -N -e \
            "SELECT MEMBER_STATE FROM performance_schema.replication_group_members WHERE MEMBER_HOST='${report_host}' LIMIT 1;" 2>/dev/null)
        if [[ "$member_state" == "ONLINE" ]]; then
            # Being ONLINE in the group is NOT the same as being known to the
            # AdminAPI. cluster.addInstance(recoveryMethod:'clone') restarts the
            # joining instance once the clone finishes, and mysqld rejoins the
            # group by itself on boot (group_replication_start_on_boot) — often
            # before the coordinator has written the join signal, and always
            # before addInstance got the chance to record the instance in
            # mysql_innodb_cluster_metadata. Breaking out here would leave a
            # group member the cluster metadata does not contain, and from then
            # on dba.getCluster() against this member fails with "unmanaged
            # replication group", so no further pod can ever join.
            #
            # Stop GR instead and fall through to the signal-driven join, which
            # goes through addInstance and does register the instance. The
            # datadir is kept, so that join is incremental, not another clone.
            if metadata_schema_exists && ! is_registered_in_metadata; then
                leave_group_if_unmanaged
            else
                log "INFO" "Already ONLINE in GR group (joined by another node's reboot) — skipping signal wait"
                break
            fi
        fi
        log "WARNING" "signal is not present yet!"
        sleep 1
    done

    # If we broke out because GR is already ONLINE (no signal file), skip to wait.
    if [ ! -f "/scripts/signal.txt" ]; then
        log "INFO" "No signal to execute — node already joined via external reboot"
    else
        desired_func=$(cat /scripts/signal.txt)
        rm -rf /scripts/signal.txt
        log "INFO" "going to execute $desired_func"

        if [[ $desired_func == "create_cluster" ]]; then
            create_cluster
        fi

        if [[ $desired_func == "join_in_cluster" ]]; then
            select_primary
            join_in_cluster
            check_instance_joined_in_cluster
            if [[ "$joined_in_cluster" == "0" ]]; then
                make_sure_instance_join_in_cluster
            fi
        fi

        if [[ $desired_func == "rejoin_in_cluster" ]]; then
            select_primary
            rejoin_in_cluster
        fi

        if [[ $desired_func == "join_by_clone" ]]; then
            select_primary
            join_by_clone
            start_mysqld_in_background
            wait_for_host_online "${MYSQL_ROOT_USERNAME}" "$report_host" "$MYSQL_ROOT_PASSWORD"
            join_in_cluster
        fi

        if [[ $desired_func == "reboot_from_complete_outage" ]]; then
            reboot_from_completeOutage
        fi
    fi

    log "INFO" "removing setup.txt file"
    rm -rf /scripts/signal.txt
    rm -rf /scripts/setup.txt

    # A join that exhausted its retries must not be terminal. The coordinator
    # keeps re-issuing the signal, but blocking on the mysqld pid below means
    # this loop never reads it again — the pod stays Running and out of the
    # group until someone deletes it by hand. If we are still not a group
    # member, re-arm and wait for the next signal instead.
    member_state=$(${mysql_local} -N -e \
        "SELECT MEMBER_STATE FROM performance_schema.replication_group_members WHERE MEMBER_HOST='${report_host}' LIMIT 1;" 2>/dev/null)
    if [[ "$member_state" != "ONLINE" ]]; then
        log "WARNING" "not ONLINE in the group after handling the signal — waiting for the coordinator to signal again"
        sleep 10
        continue
    fi

    log "INFO" "waiting for mysql process id = $pid"
    wait $pid
done
