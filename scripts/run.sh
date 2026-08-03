#!/usr/bin/env bash

# Environment variables passed from Pod env are as follows:
#
#   GROUP_NAME          = a uuid treated as the name of the replication group
#   DB_NAME             = name of the database CR
#   BASE_NAME           = name of the StatefulSet (same as the name of CRD)
#   GOV_SVC             = the name of the governing service
#   POD_NAMESPACE       = the Pods' namespace
#   MYSQL_ROOT_USERNAME = root user name
#   MYSQL_ROOT_PASSWORD = root password
#   HOST_ADDRESS        = Address used to communicate among the peers. This can be fully qualified host name or IPv4 or IPv6
#   HOST_ADDRESS_TYPE   = Address type of HOST_ADDRESS (one of DNS, IPV4, IPv6)
#   POD_IP              = IP address used to create whitelist CIDR. For HOST_ADDRESS_TYPE=DNS, it will be status.PodIP.
#   POD_IP_TYPE         = Address type of POD_IP (one of IPV4, IPv6)
#   PRIMARY_TYPE        = defines single/multi primary

env | sort | grep "POD\|HOST\|NAME"
echo "running">/scripts/setup.txt

# How long a joining member waits for a busy donor before giving up on it.
#
# MySQL serves only one clone per donor, so members seeded at the same time queue
# here and each one waits for however long the clones ahead of it take. That is a
# function of the database size, the disk and the replica count — none of which
# this script can know — so there is deliberately NO default ceiling: a wall-clock
# limit sized for one database silently abandons the clone on a larger one, which
# is the failure this retry exists to prevent.
#
# The bound belongs to the operation, not to this loop: MySQLOpsRequest
# spec.timeout already fails the request if it takes too long. Set
# CLONE_BUSY_MAX_WAIT to a number of seconds only if you specifically want a
# per-donor cap; 0 (the default) waits as long as the donor stays busy.
clone_busy_retry_interval=${CLONE_BUSY_RETRY_INTERVAL:-15}
clone_busy_max_wait=${CLONE_BUSY_MAX_WAIT:-0}

# How often the progress of a running clone is written to the pod log.
clone_progress_interval=${CLONE_PROGRESS_INTERVAL:-15}
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

args=$@
script_name=${0##*/}
NAMESPACE="$POD_NAMESPACE"
USER="$MYSQL_ROOT_USERNAME"
PASSWORD="$MYSQL_ROOT_PASSWORD"

# detect_mysql_version parses `mysqld --version` and exports MYSQL_MAJOR /
# MYSQL_MINOR / MYSQL_PATCH. Falls back to "8.4.0" if parsing fails.
detect_mysql_version() {
    local raw
    raw=$(mysqld --version 2>/dev/null | grep -oE 'Ver [0-9]+\.[0-9]+\.[0-9]+' | head -1 | awk '{print $2}')
    if [[ -z "$raw" ]]; then
        raw="8.4.0"
    fi
    MYSQL_MAJOR=${raw%%.*}
    local rest=${raw#*.}
    MYSQL_MINOR=${rest%%.*}
    MYSQL_PATCH=${rest#*.}
}

# version_ge MAJ MIN — returns 0 if detected version >= MAJ.MIN, else 1.
version_ge() {
    local want_major=$1 want_minor=$2
    if [[ "$MYSQL_MAJOR" -gt "$want_major" ]]; then return 0; fi
    if [[ "$MYSQL_MAJOR" -eq "$want_major" && "$MYSQL_MINOR" -ge "$want_minor" ]]; then return 0; fi
    return 1
}

# reset_binlog_and_gtids_sql echoes the version-correct SQL to clear the
# binary log and reset gtid_executed. Syntax changed in 8.4: older servers
# only know `RESET MASTER`, 8.4+ needs `RESET BINARY LOGS AND GTIDS`. Use
# this everywhere the script wipes binlog / GTID state (first-boot
# bootstrap, clone prep, etc.).
reset_binlog_and_gtids_sql() {
    if version_ge 8 4; then
        echo "RESET BINARY LOGS AND GTIDS;"
    else
        echo "RESET MASTER;"
    fi
}

detect_mysql_version

function timestamp() {
    date +"%Y/%m/%d %T"
}

function log() {
    local type="$1"
    local msg="$2"
    echo "$(timestamp) [$script_name] [$type] $msg"
}

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
        retryfile="/scripts/retry-stop"
        if [ -e "$retryfile" ]; then
            return 0
        fi
    done
    return 0
}

# wait for the peer-list file created by coordinator
while [ ! -f "/scripts/peer-list" ]; do
    log "WARNING" "peer-list is not created yet"
    sleep 1
done

hosts=$(cat "/scripts/peer-list")
IFS=', ' read -r -a peers <<<"$hosts"
echo "${peers[@]}"
log "INFO" "hosts are ${peers[@]}"

report_host="$HOSTNAME.$GOV_SVC.$POD_NAMESPACE"
echo "report_host = $report_host"

# comma separated host names
export hosts=$(echo -n ${peers[*]} | sed -e "s/ /,/g")

# comma separated seed addresses of the hosts (host1:port1,host2:port2,...)
export seeds=$(echo -n ${hosts} | sed -e "s/,/:33061,/g" && echo -n ":33061")

# In a replication topology, we must specify a unique server ID for each replication server, in the range from 1 to 2^32 − 1.
# “Unique” means that each ID must be different from every other ID in use by any other source or replica in the replication topology
# https://dev.mysql.com/doc/refman/8.0/en/replication-options.html#sysvar_server_id
svr_id=$(($(echo -n "${HOSTNAME}" | sed -e "s/${BASE_NAME}-//g") + 1))
echo "server_id =  $svr_id"

localhost="127.0.0.1"
if [[ "$POD_IP_TYPE" == "IPv6" ]]; then
    localhost="::1"
fi

# Get ip_whitelist
# https://dev.mysql.com/doc/refman/5.7/en/group-replication-options.html#sysvar_group_replication_ip_whitelist
# https://dev.mysql.com/doc/refman/5.7/en/group-replication-ip-address-whitelisting.html
# Now use this IP with CIDR notation
whitelist="$MYSQL_GROUP_REPLICATION_IP_WHITELIST"
if [ -z "$whitelist" ]; then
    if [[ "$POD_IP_TYPE" == "IPv6" ]]; then
        whitelist="$POD_IP"/32
    else
        whitelist="$POD_IP"/8
    fi
fi

# the mysqld configurations have take by following
# 01. official doc: https://dev.mysql.com/doc/refman/5.7/en/group-replication-configuring-instances.html
# 02. digitalocean doc: https://www.digitalocean.com/community/tutorials/how-to-configure-mysql-group-replication-on-ubuntu-16-04
log "INFO" "Storing default mysqld config into /etc/mysql/my.cnf"
mkdir -p /etc/mysql/group-replication.conf.d/
echo "!includedir /etc/mysql/group-replication.conf.d/" >>/etc/mysql/my.cnf
mkdir -p /etc/mysql/conf.d/
echo "!includedir /etc/mysql/conf.d/" >>/etc/mysql/my.cnf
# Compose the full [mysqld] section once so the resulting group.cnf has a
# single contiguous [mysqld] block. mysqld accepts multiple [mysqld]
# sections (it merges them) but it's cleaner and easier to debug with one.
{
    echo "[mysqld]"
    echo "disabled_storage_engines=\"MyISAM,BLACKHOLE,FEDERATED,ARCHIVE,MEMORY\""

    # 8.0-only options — REMOVED in 8.4 / 9.x. mysqld aborts on unknown
    # variable if these are set against 8.4+, so gate strictly to <8.4.
    if ! version_ge 8 4; then
        # default-authentication-plugin (alias default_authentication_plugin):
        # deprecated in 8.0.27, REMOVED in 8.4.0. Forced to mysql_native_password
        # on 8.0 so legacy clients (and the operator's own mysql probes) can
        # authenticate without re-keying. On 8.4 the equivalent toggle is the
        # mysql_native_password=ON server variable, emitted further below.
        echo "default-authentication-plugin=mysql_native_password"
        # master_info_repository / relay_log_info_repository: required for GR
        # pre-8.0.23 (defaulted to FILE; GR needs TABLE). Implicit since
        # 8.0.23, removed in 8.4 — no longer settable.
        echo "master_info_repository = TABLE"
        echo "relay_log_info_repository = TABLE"
        # transaction_write_set_extraction: required by GR; default became
        # XXHASH64 in 8.0.26, removed as a settable option in 8.4.
        echo "transaction_write_set_extraction = XXHASH64"
    fi

    # log_error_suppression_list silences the "mysql_native_password is
    # deprecated" warning (MY-013360). Variable is valid on 8.0+/8.4+/9.x
    # but the warning only fires on 8.0/8.4 where the plugin still exists,
    # so emit only there to keep the config surface minimal on 9.x.
    if ! version_ge 9 0; then
        echo "log_error_suppression_list = 'MY-013360'"
    fi

    echo ""
    echo "# General replication settings"
    echo "gtid_mode = ON"
    echo "enforce_gtid_consistency = ON"
    echo "binlog_checksum = NONE"
    echo "log_bin = binlog"
    echo "loose-group_replication_bootstrap_group = OFF"
    echo "loose-group_replication_start_on_boot = OFF"
    echo "loose_group_replication_unreachable_majority_timeout = 20"
    echo "loose_group_replication_exit_state_action = OFFLINE_MODE"
    echo ""
    echo "# default tls configuration for the group"
    echo "# group_replication_recovery_use_ssl will be overwritten from DB arguments"
    echo "loose-group_replication_ssl_mode = REQUIRED"
    echo "loose-group_replication_recovery_use_ssl = 1"
    echo ""
    echo "# recommended config"
    echo "innodb_buffer_pool_size = \"$INNODB_BUFFER_POOL_SIZE\""
    echo "loose-group-replication-message-cache-size = \"$GROUP_REPLICATION_MESSAGE_CACHE_SIZE\""
    echo "binlog_expire_logs_seconds = \"$BINLOG_EXPIRE_LOGS_SECONDS\""
    echo ""
    echo "# Shared replication group configuration"
    echo "loose-group_replication_group_name = \"${GROUP_NAME}\""
    echo "loose-group_replication_ip_whitelist = \"${whitelist}\""
    echo "loose-group_replication_ip_allowlist = \"${whitelist}\""
    echo "loose-group_replication_group_seeds = \"${seeds}\""
    echo ""
    echo "# Host specific replication configuration"
    echo "server_id = ${svr_id}"
    echo "bind-address = *"
    echo "report_host = \"${report_host}\""
    echo "loose-group_replication_local_address = \"${report_host}:33061\""
    echo "socket=\"/var/run/mysqld/mysqld.sock\""

    # Multi-Primary mode: allow all nodes to accept writes
    if [[ "$PRIMARY_TYPE" == "Multi-Primary" ]]; then
        echo ""
        echo "# Multi-Primary: any host can accept writes"
        echo "loose-group_replication_single_primary_mode = OFF"
        echo "loose-group_replication_enforce_update_everywhere_checks = ON"
    fi

    # mysql_native_password=ON is a 8.4-only option:
    #   - 8.0.x: option does not exist; mysqld aborts on "unknown variable".
    #   - 8.4.x: caching_sha2_password is the default; setting =ON re-enables
    #            the legacy plugin for backwards compatibility.
    #   - 9.x:   the plugin was removed entirely; mysqld aborts.
    if version_ge 8 4 && ! version_ge 9 0; then
        echo ""
        echo "# Re-enable legacy auth plugin (8.4-only option)"
        echo "mysql_native_password=ON"
    fi
} >>/etc/mysql/group-replication.conf.d/group.cnf

# wait for mysql daemon be running (alive)
function wait_for_mysqld_running() {
    local mysql="$mysql_header --host=$localhost"
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
        out=$(${mysql} -N -e "select 1;" 2>/dev/null)
        log "INFO" "Attempt $i: Pinging '$report_host' has returned: '$out'...................................."
        if [[ "$out" == "1" ]]; then
            log "INFO" "mysqld is ready (pid=$pid, restarts=$restarts)"
            break
        fi
        log "INFO" "Pinging '$report_host' has returned: '$out' (pid=$pid alive, restarts=$restarts)"
        echo -n .
        sleep 1
    done

    log "INFO" "mysql daemon is ready to use......."
    # Set read-only immediately after MySQL starts to prevent any external
    # process (e.g. KubeDB health checker) from writing local GTIDs before
    # the node joins GR. Cannot be set in my.cnf because it blocks --initialize.
    ${mysql} -N -e "SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;" 2>/dev/null
    log "INFO" "Set super_read_only=ON to prevent errant GTIDs"
}

function create_replication_user() {
    # now we need to configure a replication user for each server.
    # the procedures for this have been taken by following
    # 01. official doc (section from 17.2.1.3 to 17.2.1.5): https://dev.mysql.com/doc/refman/5.7/en/group-replication-user-credentials.html
    # 02. https://dev.mysql.com/doc/refman/8.0/en/group-replication-secure-user.html
    # 03. digitalocean doc: https://www.digitalocean.com/community/tutorials/how-to-configure-mysql-group-replication-on-ubuntu-16-04
    log "INFO" "Checking whether replication user exist or not......"
    local mysql="$mysql_header --host=$localhost"

    # At first, ensure that the command executes without any error. Then, run the command again and extract the output.
    retry 60 ${mysql} -N -e "select count(host) from mysql.user where mysql.user.user='repl';" | awk '{print$1}'
    out=$(${mysql} -N -e "select count(host) from mysql.user where mysql.user.user='repl';" | awk '{print$1}')
    # if the user doesn't exist, create new one.
    # All operations run in a SINGLE session with SQL_LOG_BIN=0 to prevent
    # writing local GTIDs that would create errant transactions on rejoin.
    # CHANGE REPLICATION SOURCE TO / SOURCE_USER / SOURCE_PASSWORD were added
    # in 8.0.23 as aliases for CHANGE MASTER TO / MASTER_USER / MASTER_PASSWORD.
    # On 8.0.0–8.0.22 they don't exist yet; the OLD syntax still works on
    # 8.4+ and 9.x as a deprecated alias (warnings suppressed via
    # log_error_suppression_list emitted in group.cnf above). Pick per version
    # to match what each source branch shipped:
    #   - innodb-support-80 (8.0):  CHANGE MASTER TO ...; RESET MASTER;
    #   - innodb-support (8.4):     CHANGE REPLICATION SOURCE TO ...; RESET REPLICA;
    # The two RESET variants do different things (RESET MASTER wipes binlog +
    # gtid_executed, RESET REPLICA wipes replica connection state), but each
    # matches the behaviour the corresponding source branch was shipped with.
    local change_src reset_post_change
    if version_ge 8 4; then
        change_src="CHANGE REPLICATION SOURCE TO SOURCE_USER='repl', SOURCE_PASSWORD='$MYSQL_ROOT_PASSWORD' FOR CHANNEL 'group_replication_recovery';"
        reset_post_change="RESET REPLICA;"
    else
        change_src="CHANGE MASTER TO MASTER_USER='repl', MASTER_PASSWORD='$MYSQL_ROOT_PASSWORD' FOR CHANNEL 'group_replication_recovery';"
        reset_post_change="RESET MASTER;"
    fi

    if [[ "$out" -eq "0" ]]; then
        log "INFO" "Replication user not found. Creating new replication user........"
        retry 60 ${mysql} -N -e "
            SET SQL_LOG_BIN=0;
            SET GLOBAL super_read_only=OFF;
            SET GLOBAL read_only=OFF;
            CREATE USER 'repl'@'%' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD' REQUIRE SSL;
            GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
            GRANT BACKUP_ADMIN ON *.* TO 'repl'@'%';
            GRANT CLONE_ADMIN ON *.* TO 'repl'@'%';
            FLUSH PRIVILEGES;
            ${change_src}
            ${reset_post_change}
            SET GLOBAL read_only=ON;
            SET GLOBAL super_read_only=ON;
            SET SQL_LOG_BIN=1;
        "
    else
        log "INFO" "Replication user exists. Skipping creating new one......."
        # Update replication channel password if it has been changed via RotateAuth
        retry 60 ${mysql} -N -e "
            SET SQL_LOG_BIN=0;
            SET GLOBAL super_read_only=OFF;
            SET GLOBAL read_only=OFF;
            ${change_src}
            SET GLOBAL read_only=ON;
            SET GLOBAL super_read_only=ON;
            SET SQL_LOG_BIN=1;
        "
    fi
    touch /scripts/ready.txt
}

function install_group_replication_plugin() {
    log "INFO" "Checking whether replication plugin is installed or not....."
    local mysql="$mysql_header --host=$localhost"

    # At first, ensure that the command executes without any error. Then, run the command again and extract the output.
    retry 60 ${mysql} -N -e 'SHOW PLUGINS;' | grep group_replication
    out=$(${mysql} -N -e 'SHOW PLUGINS;' | grep group_replication)
    if [[ -z "$out" ]]; then
        log "INFO" "Group replication plugin is not installed. Installing the plugin...."
        # replication plugin will be installed when the member getting bootstrapped or joined into the group first time.
        # that's why assign `joining_for_first_time` variable to 1 for making further reset process.
        joining_for_first_time=1
        retry 60 ${mysql} -e "SET SQL_LOG_BIN=0; SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF; INSTALL PLUGIN group_replication SONAME 'group_replication.so'; SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON; SET SQL_LOG_BIN=1;"
        log "INFO" "Group replication plugin successfully installed"
    else
        log "INFO" "Already group replication plugin is installed"
    fi
}

function install_clone_plugin() {
    log "INFO" "Checking whether clone plugin is installed or not...."
    local mysql="$mysql_header --host=$localhost"

    # At first, ensure that the command executes without any error. Then, run the command again and extract the output.
    retry 60 ${mysql} -N -e 'SHOW PLUGINS;' | grep clone
    out=$(${mysql} -N -e 'SHOW PLUGINS;' | grep clone)
    if [[ -z "$out" ]]; then
        log "INFO" "Clone plugin is not installed. Installing the plugin..."
        retry 60 ${mysql} -e "SET SQL_LOG_BIN=0; SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF; INSTALL PLUGIN clone SONAME 'mysql_clone.so'; SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON; SET SQL_LOG_BIN=1;"
        log "INFO" "Clone plugin successfully installed"
    else
        log "INFO" "Already clone plugin is installed"
    fi
}

function check_member_list_updated() {
    for host in $@; do
        local mysql="$mysql_header --host=$host"
        if [[ "$report_host" == "$host" ]]; then
            continue
        fi
        for i in {60..0}; do
            kill -0 $pid
            exit="$?"
            if [[ "$exit" != "0" ]]; then
              break
            fi
            alive_members_id=($(${mysql} -N -e "SELECT MEMBER_ID FROM performance_schema.replication_group_members WHERE MEMBER_STATE = 'ONLINE';"))
            alive_cluster_size=${#alive_members_id[@]}
            listed_members_id=($(${mysql} -N -e "SELECT MEMBER_ID FROM performance_schema.replication_group_members;"))
            cluster_size=${#listed_members_id[@]}
            log "INFO" "Attempt $i: Checking member list has been updated inside host: $host. Expected online member: $cluster_size. Found: $alive_cluster_size"
            if [[ "$cluster_size" -le "1" ]]; then
                break
            fi

            if [[ "$alive_cluster_size" -eq "$cluster_size" ]]; then
                break
            fi
            sleep 1
        done
    done
}

function wait_for_primary() {
    log "INFO" "Waiting for group primary......"
    for host in $@; do
        if [[ "$report_host" == "$host" ]]; then
            continue
        fi
        local mysql="$mysql_header --host=${host}"

        members_id=$(${mysql} -N -e "SELECT MEMBER_ID FROM performance_schema.replication_group_members WHERE MEMBER_STATE = 'ONLINE';")
        cluster_size=${#members_id[@]}

        local is_primary_found=0
        for member_id in ${members_id[*]}; do
            for i in {60..0}; do
                kill -0 $pid
                exit="$?"
                if [[ "$exit" != "0" ]]; then
                  break
                fi
                primary_member_id=$(${mysql} -N -e "SELECT MEMBER_ID FROM performance_schema.replication_group_members WHERE MEMBER_STATE = 'ONLINE' and MEMBER_ROLE = 'PRIMARY';" | awk '{print $1}')
                log "INFO" "Attempt $i: Trying to find primary member, from ${host}........................"
                if [[ -n "$primary_member_id" ]]; then
                    is_primary_found=1
                    primary_host=$(${mysql} -N -e "SELECT MEMBER_HOST FROM performance_schema.replication_group_members WHERE MEMBER_ID = '${primary_member_id}';" | awk '{print $1}')
                    # calculate data size of the primary node.
                    # https://forums.mysql.com/read.php?108,201578,201578
                    primary_db_size=$(${mysql_header} --host=$primary_host -N -e 'select round(sum( data_length + index_length) / 1024 /  1024) "size in mb" from information_schema.tables;')
                    log "INFO" "Primary found. Primary host: $primary_host, database size: $primary_db_size"
                    break
                fi
                echo -n .
                sleep 1
            done

            if [[ "$is_primary_found" == "1" ]]; then
                break
            fi

        done

        if [[ "$is_primary_found" == "1" ]]; then
            break
        fi
    done
}

# declare donors array for further use
declare -a donors
function set_valid_donors() {
    kill -0 $pid
    exit="$?"
    if [[ "$exit" != "0" ]]; then
      return
    fi
    log "INFO" "Checking whether valid donor is found or not. If found, set this to 'clone_valid_donor_list'"
    local mysql="$mysql_header --host=$localhost"
    # clone process run when the donor and recipient must have the same MySQL server version and
    # https://dev.mysql.com/doc/refman/8.0/en/clone-plugin-remote.html#:~:text=The%20clone%20plugin%20is%20supported,17%20and%20higher.&text=The%20donor%20and%20recipient%20MySQL%20server%20instances%20must%20run,same%20operating%20system%20and%20platform.
    report_host_version=$(${mysql} -N -e "SHOW VARIABLES LIKE 'version';" | awk '{print $2}')

    # At first, ensure that the command executes without any error. Then, run the command again and extract the output.
    retry 60 ${mysql_header} --host=$primary_host -N -e "SELECT * FROM performance_schema.replication_group_members;"

    donor_list=$(${mysql_header} --host=$primary_host -N -e "SELECT MEMBER_HOST FROM performance_schema.replication_group_members WHERE MEMBER_STATE = 'ONLINE';")

    valid_donor_found=0
    for donor in ${donor_list[*]}; do
        donor_version=$(${mysql_header} --host=$primary_host -N -e "SELECT MEMBER_VERSION FROM performance_schema.replication_group_members WHERE MEMBER_HOST = '${donor}';" | awk '{print $1}')
        if [[ "$report_host_version" == "$donor_version" ]]; then
            local alias_found=0
            # ref: https://linuxize.com/post/how-to-read-a-file-line-by-line-in-bash/#using-file-descriptor
            while read -r -u9 line; do
                local ip=$(echo $line | cut -d' ' -f 1)
                if [[ "$donor" == "$ip" ]]; then
                    local alias=$(echo $line | cut -d' ' -f 2)
                    donors=("${donors[@]}" "$alias")
                    alias_found=1
                    break
                fi
            done 9<'/etc/hosts'
            if [[ "$alias_found" == "0" ]]; then
                donors=("${donors[@]}" "$donor")
            fi
            valid_donor_found=1
        fi
    done

    if [[ $valid_donor_found == 1 ]]; then
        valid_donors=$(echo -n ${donors[*]} | sed -e "s/ /:3306,/g" && echo -n ":3306")
        log "INFO" "Valid donors found. The list of valid donor are: ${valid_donors}"
        # https://dev.mysql.com/doc/refman/8.0/en/clone-plugin-options-variables.html#sysvar_clone_valid_donor_list
        retry 60 ${mysql} -N -e "SET GLOBAL clone_valid_donor_list='${valid_donors}';"
    fi
}

function bootstrap_cluster() {
    # for bootstrap group replication, the following steps have been taken:
    # - initially reset the member to cleanup all data configuration/set the binlog and gtid's initial position.
    #   ref: https://dev.mysql.com/doc/refman/8.0/en/reset-master.html
    # - set global variable group_replication_bootstrap_group to `ON`
    # - start group replication
    # - set global variable group_replication_bootstrap_group to `OFF`
    #   ref:  https://dev.mysql.com/doc/refman/8.0/en/group-replication-bootstrap.html
    local mysql="$mysql_header --host=$localhost"
    log "INFO" "bootstrapping cluster with host $report_host..."
    # Temporarily disable read-only for bootstrap operations.
    # GR will manage read-only after START GROUP_REPLICATION.
    retry 60 ${mysql} -N -e "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;"
    if [[ "$joining_for_first_time" == "1" ]]; then
        retry 60 ${mysql} -N -e "$(reset_binlog_and_gtids_sql)"
    fi
    retry 60 ${mysql} -N -e "SET GLOBAL group_replication_bootstrap_group=ON;"
    retry 60 ${mysql} -N -e "START GROUP_REPLICATION;"
    retry 60 ${mysql} -N -e "SET GLOBAL group_replication_bootstrap_group=OFF;"
}

function join_into_cluster() {
    # member try to join into the existing group
    log "INFO" "The replica, ${report_host} is joining into the existing group..."
    local mysql="$mysql_header --host=$localhost"

    # Temporarily disable read-only for join operations.
    # GR will manage read-only after START GROUP_REPLICATION.
    retry 60 ${mysql} -N -e "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;"

    # for 1st time joining, there need to run `RESET MASTER` to set the binlog and gtid's initial position.
    # then run clone process to copy data directly from valid donor. That's why pod will be restart for 1st time joining into the group replication.
    # https://dev.mysql.com/doc/refman/8.0/en/clone-plugin-remote.html
    export mysqld_alive=1
    if [[ "$joining_for_first_time" == "1" ]]; then
        log "INFO" "Resetting binlog & gtid to initial state as $report_host is joining for first time.."
        retry 60 ${mysql} -N -e "$(reset_binlog_and_gtids_sql)"
        # clone process will run when the joiner get valid donor and the primary member's data will be be gather than or equal  128MB
        if [[ $valid_donor_found == 1 ]] && [[ $primary_db_size -ge 128 ]]; then
            for donor in ${donors[*]}; do
                log "INFO" "Cloning data from $donor to $report_host....."
                error_message=$(${mysql} -N -e "CLONE INSTANCE FROM 'repl'@'$donor':3306 IDENTIFIED BY '$MYSQL_ROOT_PASSWORD' REQUIRE SSL;" 2>&1)
                # we may get an error when the cloning process has finished like:
                # ".ERROR 3707 (HY000) at line 1: Restart server failed (mysqld is not managed by supervisor process)"
                # This error does not indicate a cloning failure.
                # It means that the recipient MySQL server instance must be started again manually after the data is cloned
                # https://dev.mysql.com/doc/refman/8.0/en/clone-plugin-remote.html#:~:text=ERROR%203707%20(HY000)%3A%20Restart,not%20managed%20by%20supervisor%20process).&text=It%20means%20that%20the%20recipient,after%20the%20data%20is%20cloned.
                log "INFO" "Clone error message: $error_message"
                if [[ "$error_message" != *"mysqld is not managed by supervisor process"* ]]; then
                    # retry cloning process for next valid donor
                    continue
                fi

                # wait for background process `mysqld` have been killed
                for i in {60..0}; do
                    kill -0 $pid
                    exit="$?"
                    log "INFO" "Attempt $i: Checking mysqld(process id=$pid) is alive or not, exit code: $exit"
                    if [[ "$exit" != "0" ]]; then
                        mysqld_alive=0
                        break
                    fi
                    echo -n .
                    sleep 1
                done

                if [[ "$mysqld_alive" == "0" ]]; then
                    break
                fi

            done
        fi
    fi
    # If the host is still alive, it will join the cluster directly.
    if [[ $mysqld_alive == 1 ]]; then
        retry 60 ${mysql} -N -e "START GROUP_REPLICATION;"
        log "INFO" "Host (${report_host}) has joined to the group......."
    else
        #run mysqld in background since mysqld can't restart after a clone process
        start_mysqld_in_background
        wait_for_mysqld_running
        retry 60 ${mysql} -N -e "START GROUP_REPLICATION;"
        log "INFO" "Host (${report_host}) has joined to the group......."
        #
    fi

    echo "end join in cluster"
}

# log_clone_progress polls performance_schema.clone_progress and logs how far the
# running CLONE INSTANCE has got. Seeding a large database takes many minutes
# during which the pod looks idle, so without this there is no way to tell a
# healthy long clone apart from a stuck one.
#
# CLONE INSTANCE blocks the connection that issued it, so this runs as a
# background poller and is stopped once the clone returns.
function log_clone_progress() {
    local mysql="$mysql_header --host=$localhost"
    while true; do
        # FILE COPY is the stage that moves the data; the others are negligible.
        progress=$(${mysql} -N -B -e "
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

# clone_from_donor runs CLONE INSTANCE against a single donor and returns 0 only
# when the clone actually succeeded.
#
# MySQL permits exactly ONE concurrent clone operation per donor
# (error 3634: "Too many concurrent clone operations. Maximum allowed - 1.").
# When several fresh members are seeded at the same time they race for the same
# donor and every loser is rejected within milliseconds. That is a transient
# "donor is busy" condition, not a real failure, so wait for the donor to become
# free and try again instead of giving up.
function clone_from_donor() {
    local donor=$1
    local mysql="$mysql_header --host=$localhost"
    local waited=0

    while true; do
        log_clone_progress &
        local progress_pid=$!

        error_message=$(${mysql} -N -e "CLONE INSTANCE FROM 'repl'@'$donor':3306 IDENTIFIED BY '$MYSQL_ROOT_PASSWORD' REQUIRE SSL;" 2>&1)

        kill "$progress_pid" 2>/dev/null
        wait "$progress_pid" 2>/dev/null

        # A successful clone ends with:
        #   "ERROR 3707 (HY000): Restart server failed (mysqld is not managed by supervisor process)"
        # which means the data was copied and mysqld must be started again manually.
        # https://dev.mysql.com/doc/refman/8.0/en/clone-plugin-remote.html
        log "INFO" "Clone error message: $error_message"
        if [[ "$error_message" == *"mysqld is not managed by supervisor process"* ]]; then
            return 0
        fi

        if [[ "$error_message" == *"Too many concurrent clone operations"* ]]; then
            # 0 = wait indefinitely; the ops request timeout is the real bound.
            if [[ $clone_busy_max_wait -gt 0 && $waited -ge $clone_busy_max_wait ]]; then
                log "ERROR" "Donor $donor still busy after ${waited}s (CLONE_BUSY_MAX_WAIT), giving up on this donor"
                return 1
            fi
            log "INFO" "Donor $donor is busy serving another clone, retrying in ${clone_busy_retry_interval}s (waited ${waited}s so far)"
            sleep "$clone_busy_retry_interval"
            waited=$((waited + clone_busy_retry_interval))
            continue
        fi

        # any other error: this donor cannot serve us
        return 1
    done
}

function join_by_clone() {
    # member try to join into the existing group
    log "INFO" "The replica, ${report_host} is joining into the existing group..."
    local mysql="$mysql_header --host=$localhost"
    local clone_done=0

    # Temporarily disable read-only for clone operations.
    # GR will manage read-only after START GROUP_REPLICATION.
    retry 60 ${mysql} -N -e "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;"

    # for 1st time joining, there need to run `RESET MASTER` to set the binlog and gtid's initial position.
    # then run clone process to copy data directly from valid donor. That's why pod will be restart for 1st time joining into the group replication.
    # https://dev.mysql.com/doc/refman/8.0/en/clone-plugin-remote.html
    export mysqld_alive=1
    log "INFO" "Resetting binlog & gtid to initial state as $report_host is joining for first time.."
    retry 60 ${mysql} -N -e "$(reset_binlog_and_gtids_sql)"
    if [[ $valid_donor_found == 1 ]]; then
        for donor in ${donors[*]}; do
            log "INFO" "Cloning data from $donor to $report_host....."
            if ! clone_from_donor "$donor"; then
                # retry cloning process for next valid donor
                continue
            fi
            clone_done=1

            # wait for background process `mysqld` have been killed
            for i in {60..0}; do
                kill -0 $pid
                exit="$?"
                log "INFO" "Attempt $i: Checking mysqld(process id=$pid) is alive or not, exit code: $exit"
                if [[ "$exit" != "0" ]]; then
                    mysqld_alive=0
                    break
                fi
                echo -n .
                sleep 1
            done

            if [[ "$mysqld_alive" == "0" ]]; then
                break
            fi

        done
    fi

    # join_by_clone is only signalled when this member must be seeded from a donor
    # (the donor holds data this member does not have, or this member holds
    # transactions the group does not). If no donor could serve the clone, joining
    # the group anyway would put an EMPTY member ONLINE, where it is indistinguishable
    # from a healthy secondary and silently serves empty reads. Refuse to join and
    # let the coordinator re-issue the clone instead.
    if [[ $clone_done == 0 ]]; then
        log "ERROR" "Clone failed from every donor; refusing to join the group with an empty dataset. The coordinator will retry."
        return 1
    fi

    # If the host is still alive, it will join the cluster directly.
    if [[ $mysqld_alive == 1 ]]; then
        retry 60 ${mysql} -N -e "START GROUP_REPLICATION;"
        log "INFO" "Host (${report_host}) has joined to the group......."
    else
        #run mysqld in background since mysqld can't restart after a clone process
        start_mysqld_in_background
        wait_for_mysqld_running
        retry 60 ${mysql} -N -e "START GROUP_REPLICATION;"
        log "INFO" "Host (${report_host}) has joined to the group......."
        #
    fi

    echo "end join in cluster"
}

export pid
function start_mysqld_in_background() {
    log "INFO" "Starting mysql server with 'docker-entrypoint.sh mysqld $args'..."
    docker-entrypoint.sh mysqld $args &
    pid=$!
    log "INFO" "The process id of mysqld is '$pid'"
}

start_mysqld_in_background

# create mysql client with user exported in mysql_header and export password
# this is to bypass the warning message for using password
export mysql_header="mysql -u ${USER} --port=3306"
export MYSQL_PWD=${PASSWORD}
export member_hosts=($(echo -n ${peers[*]} | tr -d '[]'))
export joining_for_first_time=0
log "INFO" "Host lists: ${member_hosts[@]}"

# wait for mysqld to be ready
wait_for_mysqld_running

# ensure replication user
create_replication_user

# ensure replication plugin
install_group_replication_plugin

# ensure clone plugin
install_clone_plugin

while true; do
    echo "running">/scripts/setup.txt
    log "INFO" "creating setup.txt file"
    kill -0 $pid
    exit="$?"
    if [[ "$exit" == "0" ]]; then
        echo "mysqld process is running"
    else
        echo "need start mysqld and wait_for_mysqld_running"
        start_mysqld_in_background
        wait_for_mysqld_running
    fi

    # wait for the script copied by coordinator
    while [ ! -f "/scripts/signal.txt" ]; do
        log "WARNING" "signal is not present yet!"
        sleep 1
    done
    desired_func=$(cat /scripts/signal.txt)
    rm -rf /scripts/signal.txt
    log "INFO" "going to execute $desired_func"
    if [[ $desired_func == "create_cluster" ]]; then
        bootstrap_cluster
    fi

    if [[ $desired_func == "join_in_cluster" ]]; then
        check_member_list_updated "${member_hosts[*]}"
        wait_for_primary "${member_hosts[*]}"
        set_valid_donors
        join_into_cluster
    fi
    if [[ $desired_func == "join_by_clone" ]]; then
        check_member_list_updated "${member_hosts[*]}"
        wait_for_primary "${member_hosts[*]}"
        set_valid_donors
        join_by_clone
    fi
    joining_for_first_time=0
    log "INFO" "removing setup.txt file"
    rm -rf /scripts/setup.txt

    # A join that did not take must not be terminal. `wait $pid` below only
    # returns when mysqld exits, so a healthy mysqld parks this loop forever and
    # every later signal the coordinator writes — including the create_cluster
    # signal that re-bootstraps the group after a full outage — is never read.
    # Observed: all members down, the coordinator decided on a bootstrap after
    # ~16 minutes, wrote the signal, and it sat unread while the members went on
    # failing to *join* a group that no longer existed; recovery needed a manual
    # bootstrap.
    #
    # If this member is not ONLINE in the group, re-arm and wait for the next
    # signal instead of blocking. Mirrors the same guard in run_innodb.sh.
    member_state=$(${mysql_header} --host=$localhost -N -e \
        "SELECT MEMBER_STATE FROM performance_schema.replication_group_members WHERE MEMBER_HOST='${report_host}' LIMIT 1;" 2>/dev/null)
    if [[ "$member_state" != "ONLINE" ]]; then
        log "WARNING" "not ONLINE in the group after handling the signal (state='${member_state:-unknown}') — waiting for the coordinator to signal again"
        sleep 10
        continue
    fi

    log "INFO" "waiting for mysql process id  = $pid"
    wait $pid
done
