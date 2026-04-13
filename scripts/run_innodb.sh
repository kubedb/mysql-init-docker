#!/usr/bin/env bash
#set -x
# run_innodb.sh — MySQL InnoDB Cluster init script
#
# Compatibility: MySQL 9.0.x with appscode images (ghcr.io/appscode-images/mysql)
#
# Key differences from MySQL 8.0 (mysql-server Oracle image):
#   1. Entrypoint is at /usr/local/bin/docker-entrypoint.sh (not /entrypoint.sh)
#   2. docker-entrypoint.sh already creates root@% (CREATE USER fails without IF NOT EXISTS)
#   3. mysqlsh 8.4+ defaults to SQL mode (need --js for JavaScript API calls)
#   4. dba.configureInstance() removed 'password' and 'interactive' options
#   5. REQUIRE SSL is strictly enforced on socket connections (repl can't connect locally)
#   6. mysql_native_password plugin removed entirely in MySQL 9.x

function timestamp() {
    date +"%Y/%m/%d %T"
}

function log() {
    local type="$1"
    local msg="$2"
    echo "$(timestamp) [$script_name] [$type] $msg"
}

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

# Unique server_id per pod (same logic as run.sh for Group Replication).
# Required by dba.createCluster() — MySQL 9.6+ no longer auto-assigns unique IDs.
svr_id=$(($(echo -n "${HOSTNAME}" | sed -e "s/${BASE_NAME}-//g") + 1))
log "INFO" "server_id = $svr_id"

mkdir -p /etc/mysql/conf.d/
cat >>/etc/mysql/my.cnf <<EOL
!includedir /etc/mysql/conf.d/
[mysqld]
server_id = ${svr_id}
# Use MySQL communication stack instead of XCom (8.0.27+).
# Benefits: no extra port 33061, no IP allowlist needed, uses MySQL auth + SSL.
loose-group_replication_communication_stack = MYSQL
# Faster failover on network partition (match run.sh)
loose_group_replication_unreachable_majority_timeout = 20
EOL

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
    local mysqlclient="mysql -u$1 -h$2 -p$3"
    retry 900 ${mysqlclient} -e "select 1;" | awk '{print$1}'
    out=$(${mysqlclient} -e "select 1;" | head -n1 | awk '{print$1}')
    if [[ "$out" == "1" ]]; then
        log "INFO" "host $2 is online"
    else
        log "INFO" "server failed to comes online within 900 seconds"
    fi

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
    fi
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
    retry 5 $mysqlsh_remote -e "cluster=dba.createCluster('$clusterName',{communicationStack:'MYSQL',manualStartOnBoot:true});"
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
    ${mysqlsh_primary} -e "cluster = dba.getCluster(); cluster.rescan({addInstances:['${report_host}:3306'],interactive:false})"
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
    # Temporarily disable read-only for join operations (match run.sh)
    ${mysql_local} -N -e "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;" 2>/dev/null
    retry 10 ${mysqlsh_primary} -e "cluster = dba.getCluster(); cluster.addInstance('${replication_user}:${MYSQL_ROOT_PASSWORD}@${report_host}:3306',{recoveryMethod:'incremental'});"
}

function join_by_clone() {
    log "INFO" "$report_host joining in cluster by clone"
    local mysqlsh_primary="mysqlsh --js -u${replication_user} -p${MYSQL_ROOT_PASSWORD} -h${primary}"
    # Temporarily disable read-only for clone operations (match run.sh)
    ${mysql_local} -N -e "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;" 2>/dev/null
    retry 10 ${mysqlsh_primary} -e "cluster = dba.getCluster(); cluster.removeInstance('${report_host}:3306',{force:true});"
    retry 10 ${mysqlsh_primary} -e "cluster = dba.getCluster(); cluster.addInstance('${replication_user}:${MYSQL_ROOT_PASSWORD}@${report_host}:3306',{recoveryMethod:'clone'});"
    # Clone restarts mysqld — wait for the old process to finish
    wait $pid
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
    retry 10 ${mysqlsh_primary} -e "cluster = dba.getCluster(); cluster.rescan({addInstances:['${report_host}:3306'],interactive:false})"
}

function rejoin_in_cluster() {
    local mysqlsh_primary="mysqlsh --js -u${replication_user} -p${MYSQL_ROOT_PASSWORD} -h${primary}"
    # Temporarily disable read-only for rejoin (match run.sh)
    ${mysql_local} -N -e "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;" 2>/dev/null
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
        retry 1 ${mysqlsh_primary} -e "cluster = dba.getCluster(); cluster.removeInstance('${report_host}:3306',{force:true});"
        join_in_cluster
    fi
}

export pid
function reboot_from_completeOutage() {
    local mysqlsh_self="mysqlsh --js -u${MYSQL_ROOT_USERNAME} -h${report_host} -p${MYSQL_ROOT_PASSWORD}"
    clusterName=$(echo -n $BASE_NAME | sed 's/-/_/g')
    # Temporarily disable read-only for reboot (match run.sh)
    ${mysql_local} -N -e "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;" 2>/dev/null
    yes | $mysqlsh_self -e "dba.rebootClusterFromCompleteOutage('$clusterName',{force:true})"
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
    check_mysqld_alive
    if [[ "$mysqld_alive" == "1" ]]; then
        echo "mysqld process is running"
    else
        echo "need start mysqld and wait_for_mysqld_running"
        start_mysqld_in_background
        wait_for_host_online "${MYSQL_ROOT_USERNAME}" "$report_host" "$MYSQL_ROOT_PASSWORD"
    fi

    # wait for the signal file from coordinator
    while [ ! -f "/scripts/signal.txt" ]; do
        log "WARNING" "signal is not present yet!"
        sleep 1
    done

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

    log "INFO" "waiting for mysql process id = $pid"
    wait $pid
    rm -rf /scripts/signal.txt
done
