#!/usr/bin/env bash

#set -eoux pipefail

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

env | sort | grep "POD\|HOST\|NAME"
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

if [ "$POD_IP_TYPE" = "IPv6" ]; then
    log "ERROR" "MySQL 5.7 is not supported on an IPv6 cluster."
    log "ERROR" "See here for details: https://dev.mysql.com/doc/refman/5.7/en/group-replication-ip-address-permissions.html"
    exit 1
fi

args=$@
script_name=${0##*/}
NAMESPACE="$POD_NAMESPACE"
USER="$MYSQL_ROOT_USERNAME"
PASSWORD="$MYSQL_ROOT_PASSWORD"
localhost=127.0.0.1

function timestamp() {
    date +"%Y/%m/%d %T"
}

function log() {
    local type="$1"
    local msg="$2"
    echo "$(timestamp) [$script_name] [$type] $msg"
}

# retry a command up to a specific number of times until it exits successfully,
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

# Get ip_whitelist
# https://dev.mysql.com/doc/refman/5.7/en/group-replication-options.html#sysvar_group_replication_ip_whitelist
# https://dev.mysql.com/doc/refman/5.7/en/group-replication-ip-address-whitelisting.html
# Now use this IP with CIDR notation
whitelist="$MYSQL_GROUP_REPLICATION_IP_WHITELIST"
if [ -z "$whitelist" ]; then
    whitelist="$POD_IP"/16
fi

# the mysqld configurations have take by following
# 01. official doc: https://dev.mysql.com/doc/refman/5.7/en/group-replication-configuring-instances.html
# 02. digitalocean doc: https://www.digitalocean.com/community/tutorials/how-to-configure-mysql-group-replication-on-ubuntu-16-04
log "INFO" "Storing default mysqld config into /etc/mysql/my.cnf"
mkdir -p /etc/mysql/group-replication.conf.d/
echo "!includedir /etc/mysql/group-replication.conf.d/" >>/etc/mysql/my.cnf
echo "!includedir /etc/mysql/conf.d/" >>/etc/mysql/my.cnf

cat >>/etc/mysql/group-replication.conf.d/group.cnf <<EOL
[mysqld]
disabled_storage_engines="MyISAM,BLACKHOLE,FEDERATED,ARCHIVE,MEMORY"

# General replication settings
gtid_mode = ON
enforce_gtid_consistency = ON
master_info_repository = TABLE
relay_log_info_repository = TABLE
binlog_checksum = NONE
log_slave_updates = ON
log_bin = binlog
binlog_format = ROW
transaction_write_set_extraction = XXHASH64
loose-group_replication_bootstrap_group = OFF
loose-group_replication_start_on_boot = OFF
loose_group_replication_unreachable_majority_timeout = 20

# default tls configuration for the group
# group_replication_recovery_use_ssl will be overwritten from DB arguments
loose-group_replication_ssl_mode = REQUIRED
loose-group_replication_recovery_use_ssl = 1

# recommended config
innodb_buffer_pool_size = "$INNODB_BUFFER_POOL_SIZE"
expire_logs_days = "$EXPIRE_LOGS_DAYS"

# Shared replication group configuration
loose-group_replication_group_name = "${GROUP_NAME}"
#loose-group_replication_ip_whitelist = "AUTOMATIC"
loose-group_replication_ip_whitelist = "${whitelist}"
loose-group_replication_group_seeds = "${seeds}"

# Single or Multi-primary mode? Uncomment these two lines
# for multi-primary mode, where any host can accept writes
#loose-group_replication_single_primary_mode = OFF
#loose-group_replication_enforce_update_everywhere_checks = ON

# Host specific replication configuration
server_id = ${svr_id}
#bind-address = "${report_host}"
bind-address = "0.0.0.0"
report_host = "${report_host}"
loose-group_replication_local_address = "${report_host}:33061"
EOL

# wait for mysql daemon be running (alive)
function wait_for_mysqld_running() {
    local mysql="$mysql_header --host=$localhost"

    for i in {900..0}; do
        out=$(${mysql} -N -e "select 1;" 2>/dev/null)
        log "INFO" "Attempt $i: Pinging '$report_host' has returned: '$out'...................................."
        if [[ "$out" == "1" ]]; then
            break
        fi

        echo -n .
        sleep 1
    done

    if [[ "$i" == "0" ]]; then
        echo ""
        log "ERROR" "Server ${report_host} failed to start in 900 seconds............."
        exit 1
    fi
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
    if [[ "$out" -eq "0" ]]; then
        log "INFO" "Replication user not found. Creating new replication user........"
        retry 60 ${mysql} -N -e "
            SET SQL_LOG_BIN=0;
            SET GLOBAL super_read_only=OFF;
            SET GLOBAL read_only=OFF;
            CREATE USER 'repl'@'%' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD' REQUIRE SSL;
            GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
            FLUSH PRIVILEGES;
            CHANGE MASTER TO MASTER_USER='repl', MASTER_PASSWORD='$MYSQL_ROOT_PASSWORD' FOR CHANNEL 'group_replication_recovery';
            RESET MASTER;
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
            CHANGE MASTER TO MASTER_USER='repl', MASTER_PASSWORD='$MYSQL_ROOT_PASSWORD' FOR CHANNEL 'group_replication_recovery';
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
        retry 60 ${mysql} -e "SET SQL_LOG_BIN=0; SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF; INSTALL PLUGIN group_replication SONAME 'group_replication.so'; SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON; SET SQL_LOG_BIN=1;"
        log "INFO" "Group replication plugin successfully installed"
    else
        log "INFO" "Already group replication plugin is installed"
    fi
}

function check_existing_cluster() {
    log "INFO" "Checking whether there exists any replication group or not..."
    cluster_exists=0
    for host in $@; do
        if [[ "$report_host" == "$host" ]]; then
            continue
        fi
        local mysql="$mysql_header --host=${host}"

        members_id=($(${mysql} -N -e "SELECT MEMBER_ID FROM performance_schema.replication_group_members WHERE MEMBER_STATE = 'ONLINE';"))
        cluster_size=${#members_id[@]}
        log "INFO" "Number of online members: $cluster_size"
        if [[ "$cluster_size" -ge "1" ]]; then
            cluster_exists=1
            break
        fi
    done
}

function check_member_list_updated() {
    for host in $@; do
        local mysql="$mysql_header --host=$host"
        if [[ "$report_host" == "$host" ]]; then
            continue
        fi
        for i in {120..0}; do
            kill -0 $pid
            exit="$?"
            if [[ "$exit" != "0" ]]; then
              break
            fi
            alive_cluster_size=$(${mysql} -N -e "SELECT COUNT(*) FROM performance_schema.replication_group_members WHERE MEMBER_STATE = 'ONLINE';" 2>/dev/null || echo "0")
            cluster_size=$(${mysql} -N -e "SELECT COUNT(*) FROM performance_schema.replication_group_members;" 2>/dev/null || echo "0")

            log "INFO" "Attempt $i: Checking member list on $host. Total: $cluster_size, Online: $alive_cluster_size"

            # Node still joining (sees only itself as OFFLINE)
            if [[ "$cluster_size" -le "1" ]]; then
                log "INFO" "Node $host still joining (sees $cluster_size member). Waiting..."
                break
            fi

            # Success: all members ONLINE and at least 1 member
            if [[ "$alive_cluster_size" -gt "0" && "$alive_cluster_size" -eq "$cluster_size" ]]; then
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
                primary_member_id=$(${mysql} -N -e "SHOW STATUS WHERE Variable_name = 'group_replication_primary_member';" | awk '{print $2}')
                log "INFO" "Attempt $i: Trying to find primary member........................"
                if [[ -n "$primary_member_id" ]]; then
                    is_primary_found=1
                    primary_host=$(${mysql} -N -e "SELECT MEMBER_HOST FROM performance_schema.replication_group_members WHERE MEMBER_ID = '${primary_member_id}';" | awk '{print $1}')
                    log "INFO" "In existing group replication, found primary: $primary_host"
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
    retry 120 ${mysql} -N -e "SET GLOBAL group_replication_bootstrap_group=ON;"
    retry 120 ${mysql} -N -e "START GROUP_REPLICATION;"
    retry 120 ${mysql} -N -e "SET GLOBAL group_replication_bootstrap_group=OFF;"
}

function join_into_cluster() {
    # member try to join into the existing group
    log "INFO" "The replica, ${report_host} is joining into the existing group..."
    local mysql="$mysql_header --host=$report_host"

    # run `START GROUP_REPLICATION` until the the member successfully join into the group
    retry 120 ${mysql} -N -e "START GROUP_REPLICATION;"
    log "INFO" "Group replication on (${report_host}) has been taken place..."
}

export pid
function start_mysqld_in_background() {
    log "INFO" "Starting mysql server with 'docker-entrypoint.sh mysqld ${args[@]}'..."
    docker-entrypoint.sh mysqld $args &
    pid=$!
    log "INFO" "The process id of mysqld is '$pid'"
}

start_mysqld_in_background

# create mysql client with user exported in mysql_header and export password
# this is to bypass the warning message for using password
export mysql_header="mysql -u ${USER} --port=3306"
export MYSQL_PWD=${PASSWORD}
export member_hosts=$(echo -n ${hosts} | sed -e "s/,/ /g")
log "INFO" "Host lists: ${member_hosts[@]}"

# wait for mysqld to be ready
wait_for_mysqld_running

# ensure replication user
create_replication_user

# ensure replication plugin
install_group_replication_plugin

while true; do
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
        # check_member_list_updated "${member_hosts[*]}"
        wait_for_primary "${member_hosts[*]}"
        join_into_cluster
    fi
    echo $pid
    wait $pid
done
