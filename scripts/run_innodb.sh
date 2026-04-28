#!/usr/bin/env bash
#set -x
# run_innodb.sh — MySQL InnoDB Cluster init script
# Compatibility: MySQL 8.0.x

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

#stores all the arguments that are passed from statefulSet
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

whitelist="$MYSQL_GROUP_REPLICATION_IP_WHITELIST"
if [ -z "$whitelist" ]; then
    if [[ "$POD_IP_TYPE" == "IPv6" ]]; then
        whitelist="$POD_IP"/64
    else
        whitelist="$POD_IP"/16
    fi
fi
mkdir -p /etc/mysql/conf.d/
mkdir -p /etc/mysql/default.d/
cat >>/etc/mysql/my.cnf <<EOL
!includedir /etc/mysql/default.d/
!includedir /etc/mysql/conf.d/
EOL

cat >>/etc/mysql/default.d/my.cnf <<EOL
[mysqld]
default_authentication_plugin=mysql_native_password
#loose-group_replication_ip_whitelist = "${whitelist}"
loose-group_replication_ip_allowlist = "${whitelist}"
log_error_suppression_list = 'MY-013360'

# recommended config
innodb_buffer_pool_size = "$INNODB_BUFFER_POOL_SIZE"
loose-group-replication-message-cache-size = "$GROUP_REPLICATION_MESSAGE_CACHE_SIZE"
binlog_expire_logs_seconds = "$BINLOG_EXPIRE_LOGS_SECONDS"
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
        # Allow coordinator to stop retries
        retryfile="/scripts/retry-stop"
        if [ -e "$retryfile" ]; then
            return 0
        fi
    done
    return 0
}

function wait_for_host_online() {
    #function called with parameter user,host,password
    log "INFO" "checking for host $2 to come online"

    local mysqlshell="mysql -u$1 -h$2 -p$3" # "mysql -uroot -ppass -hmysql-server-0.mysql-server.default.svc"
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
    # process from writing local GTIDs before the node joins the cluster.
    local mysql_ro="mysql -u${MYSQL_ROOT_USERNAME} -hlocalhost -p${MYSQL_ROOT_PASSWORD} --port=3306"
    ${mysql_ro} -N -e "SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;" 2>/dev/null
    log "INFO" "Set super_read_only=ON to prevent errant GTIDs"
}

# mysql client shorthand — always use root for local operations
mysql_local="mysql -u${MYSQL_ROOT_USERNAME} -hlocalhost -p${MYSQL_ROOT_PASSWORD} --port=3306"
replication_user=repl

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
    local mysql="mysql -u ${MYSQL_ROOT_USERNAME} -hlocalhost -p${MYSQL_ROOT_PASSWORD} --port=3306"

    # At first, ensure that the command executes without any error. Then, run the command again and extract the output.
    retry 120 ${mysql} -N -e "select count(host) from mysql.user where mysql.user.user='repl';"
    out=$(${mysql} -N -e "select count(host) from mysql.user where mysql.user.user='repl';" | awk '{print$1}')
    # if the user doesn't exist, crete new one.
    if [[ "$out" -eq "0" ]]; then
        log "INFO" "Replication user not found. Creating new replication user..."
        retry 120 ${mysql} -N -e "
            SET SQL_LOG_BIN=0;
            SET GLOBAL super_read_only=OFF;
            SET GLOBAL read_only=OFF;
            CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' REQUIRE SSL;
            GRANT CREATE USER, FILE, PROCESS, RELOAD, REPLICATION CLIENT, REPLICATION SLAVE, SELECT, SHUTDOWN, SUPER ON *.* TO 'repl'@'%' WITH GRANT OPTION;
            GRANT DELETE, INSERT, UPDATE ON mysql.* TO 'repl'@'%' WITH GRANT OPTION;
            GRANT ALTER, ALTER ROUTINE, CREATE, CREATE ROUTINE, CREATE TEMPORARY TABLES, CREATE VIEW, DELETE, DROP, EVENT, EXECUTE, INDEX, INSERT, LOCK TABLES, REFERENCES, SHOW VIEW, TRIGGER, UPDATE ON mysql_innodb_cluster_metadata.* TO 'repl'@'%' WITH GRANT OPTION;
            GRANT ALTER, ALTER ROUTINE, CREATE, CREATE ROUTINE, CREATE TEMPORARY TABLES, CREATE VIEW, DELETE, DROP, EVENT, EXECUTE, INDEX, INSERT, LOCK TABLES, REFERENCES, SHOW VIEW, TRIGGER, UPDATE ON mysql_innodb_cluster_metadata_bkp.* TO 'repl'@'%' WITH GRANT OPTION;
            GRANT ALTER, ALTER ROUTINE, CREATE, CREATE ROUTINE, CREATE TEMPORARY TABLES, CREATE VIEW, DELETE, DROP, EVENT, EXECUTE, INDEX, INSERT, LOCK TABLES, REFERENCES, SHOW VIEW, TRIGGER, UPDATE ON mysql_innodb_cluster_metadata_previous.* TO 'repl'@'%' WITH GRANT OPTION;
            GRANT CLONE_ADMIN, BACKUP_ADMIN, CONNECTION_ADMIN, EXECUTE, GROUP_REPLICATION_ADMIN, PERSIST_RO_VARIABLES_ADMIN, REPLICATION_APPLIER, REPLICATION_SLAVE_ADMIN, ROLE_ADMIN, SYSTEM_VARIABLES_ADMIN ON *.* TO 'repl'@'%' WITH GRANT OPTION;
            CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
            GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION;
            FLUSH PRIVILEGES;
            SET SQL_LOG_BIN=1;
        "
    else
        log "INFO" "Replication user exists. Updating password if changed..."
        retry 120 ${mysql} -N -e "
            SET SQL_LOG_BIN=0;
            SET GLOBAL super_read_only=OFF;
            SET GLOBAL read_only=OFF;
            ALTER USER 'repl'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
            ALTER USER IF EXISTS 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
            FLUSH PRIVILEGES;
            SET SQL_LOG_BIN=1;
        "
    fi
    # Re-enable read_only after user creation
    ${mysql} -N -e "SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;" 2>/dev/null
    touch /scripts/ready.txt
}

restart_required=0
already_configured=0

function configure_instance() {
    log "INFO" "configuring instance $report_host."
    local mysqlshell="mysqlsh -u${MYSQL_ROOT_USERNAME} -p${MYSQL_ROOT_PASSWORD}"

    retry 120 ${mysqlshell} --sql -e "select @@gtid_mode;"
    gtid=($($mysqlshell --sql -e "select @@gtid_mode;"))
    if [[ "${gtid[1]}" == "ON" ]]; then
        log "INFO" "$report_host is already_configured."
        already_configured=1
        return
    fi

    yes | ${mysqlshell} -e "dba.configureInstance('${MYSQL_ROOT_USERNAME}:${MYSQL_ROOT_PASSWORD}@${report_host}:3306',{mycnfPath:'/etc/mysql/my.cnf',restart:false});"

    mysqladmin -u ${MYSQL_ROOT_USERNAME} -hlocalhost -p${MYSQL_ROOT_PASSWORD} --port=3306 shutdown
    wait $pid
    restart_required=1
}

function create_cluster() {
    local mysqlshell="mysqlsh -u${MYSQL_ROOT_USERNAME} -p${MYSQL_ROOT_PASSWORD} -h${report_host}"
    clusterName=$(echo -n $BASE_NAME | sed 's/-/_/g')
    retry 5 $mysqlshell -e "cluster=dba.createCluster('$clusterName',{communicationStack:'MYSQL',manualStartOnBoot:true});"
}

export primary=""
function select_primary() {
    for i in {900..0}; do
        for host in "${peers[@]}"; do
            local mysqlshell="mysqlsh -u${replication_user} -h${host} -p${MYSQL_ROOT_PASSWORD}"
            #result of the query output "member_host host_name" in this format
            #       $mysqlshell --sql -e "SELECT member_host FROM performance_schema.replication_group_members where member_role = 'PRIMARY' ;"
            selected_primary=($($mysqlshell --sql -e "SELECT member_host FROM performance_schema.replication_group_members where member_role = 'PRIMARY' ;"))
            if [[ "${#selected_primary[@]}" -ge "1" ]]; then
                primary=${selected_primary[1]}
                log "INFO" "Primary found $primary."
                return
            fi
        done
    done
    log "INFO" "Primary not found."
}

already_in_cluster=0

function is_already_in_cluster() {
    local mysqlshell="mysqlsh -u${replication_user} -p${MYSQL_ROOT_PASSWORD} -h${primary}"
    clear_stale_cluster_lock "${primary}"
    ${mysqlshell} -e "cluster = dba.getCluster();  cluster.rescan()"
    out=($(${mysqlshell} --sql -e "SELECT member_host FROM performance_schema.replication_group_members where member_state='ONLINE';"))

    for host in ${out[@]}; do
        if [[ "$host" == "$report_host" ]]; then
            echo "$report_host is already in cluster"
            already_in_cluster=1
            return
        fi
    done
}

function join_in_cluster() {
    log "INFO " "$report_host joining in cluster"
    local mysqlshell="mysqlsh -u${replication_user} -p${MYSQL_ROOT_PASSWORD} -h${primary}"
    clear_stale_cluster_lock "${primary}"
    retry 10 ${mysqlshell} -e "cluster = dba.getCluster();cluster.addInstance('${replication_user}@${report_host}',{recoveryMethod:'incremental'});"
}

function join_by_clone() {
    log "INFO " "$report_host joining in cluster"
    local mysqlshell="mysqlsh -u${replication_user} -p${MYSQL_ROOT_PASSWORD} -h${primary}"
    clear_stale_cluster_lock "${primary}"
    retry 10 ${mysqlshell} -e "cluster = dba.getCluster();cluster.removeInstance('$report_host',{force:'true'});"
    clear_stale_cluster_lock "${primary}"
    retry 10 ${mysqlshell} -e "cluster = dba.getCluster(); cluster.addInstance('${replication_user}@${report_host}',{recoveryMethod:'clone'});"

    #this is required for clone method
    # Prevent creation of new process until this one is finished
    #https://serverfault.com/questions/477448/mysql-keeps-crashing-innodb-unable-to-lock-ibdata1-error-11
    wait $pid
}
joined_in_cluster=0
check_instance_joined_in_cluster() {
    local mysqlshell="mysqlsh -u${replication_user} -p${MYSQL_ROOT_PASSWORD} -h${primary}"
    out=($(${mysqlshell} --sql -e "SELECT member_host FROM performance_schema.replication_group_members;"))

    for host in "${out[@]}"; do
        if [[ "$host" == "$report_host" ]]; then
            join_in_cluster=1
            echo "$report_host successfully join_in_cluster"
        fi
    done
}

function make_sure_instance_join_in_cluster() {
    local mysqlshell="mysqlsh -u${replication_user} -p${MYSQL_ROOT_PASSWORD} -h${primary}"
    clear_stale_cluster_lock "${primary}"
    retry 10 ${mysqlshell} -e "cluster = dba.getCluster();  cluster.rescan()"
}

function rejoin_in_cluster() {
    local mysqlshell="mysqlsh -u${replication_user} -p${MYSQL_ROOT_PASSWORD} -h${primary}"
    clear_stale_cluster_lock "${primary}"
    ${mysqlshell} -e "cluster=dba.getCluster(); cluster.rejoinInstance('${replication_user}@${report_host}')"
    out=($(${mysqlshell} --sql -e "SELECT member_host FROM performance_schema.replication_group_members;"))

    for host in "${out[@]}"; do
        if [[ "$host" == "$report_host" ]]; then
            echo "$report_host successfully join_in_cluster"
        fi
    done
    check_instance_joined_in_cluster
    if [[ "$joined_in_cluster" == "0" ]]; then
        make_sure_instance_join_in_cluster
    fi
    check_instance_joined_in_cluster
    if [[ "$joined_in_cluster" == "0" ]]; then
        clear_stale_cluster_lock "${primary}"
        retry 1 ${mysqlshell} -e "cluster = dba.getCluster();cluster.removeInstance('$report_host',{force:'true'});"
        join_in_cluster
    fi

}

export pid
function reboot_from_completeOutage() {
    local mysqlshell="mysqlsh -u${MYSQL_ROOT_USERNAME} -h${report_host} -p${MYSQL_ROOT_PASSWORD}"
    #https://dev.mysql.com/doc/dev/mysqlsh-api-javascript/8.0/classmysqlsh_1_1dba_1_1_dba.html#ac68556e9a8e909423baa47dc3b42aadb
    #mysql wait for user interaction to remove the unavailable seed from the cluster..
    clusterName=$(echo -n $BASE_NAME | sed 's/-/_/g')

    # Stop GR on any peer stuck in ERROR state before reboot.
    # dba.rebootClusterFromCompleteOutage() refuses to proceed if any peer has GR
    # in ERROR state ("belongs to a GR group that is not managed as an InnoDB Cluster").
    for host in "${peers[@]}"; do
        peer_state=$(mysql -u${MYSQL_ROOT_USERNAME} -h${host} -p${MYSQL_ROOT_PASSWORD} --port=3306 -N -e \
            "SELECT MEMBER_STATE FROM performance_schema.replication_group_members LIMIT 1;" 2>/dev/null)
        if [[ "$peer_state" == "ERROR" ]]; then
            log "INFO" "Stopping GR on $host (stuck in ERROR state) before cluster reboot..."
            mysql -u${MYSQL_ROOT_USERNAME} -h${host} -p${MYSQL_ROOT_PASSWORD} --port=3306 -N -e "STOP GROUP_REPLICATION;" 2>/dev/null
        fi
    done

    yes | $mysqlshell -e "dba.rebootClusterFromCompleteOutage('$clusterName',{force:'true'})"
    clear_stale_cluster_lock "${report_host}"
    yes | $mysqlshell -e "cluster = dba.getCluster();  cluster.rescan()"
    wait $pid
}

function start_mysqld_in_background() {
    log "INFO" "Starting mysql server with 'docker-entrypoint.sh mysqld $args'..."
    docker-entrypoint.sh mysqld --user=root --report-host=$report_host --bind-address=* $args &
    pid=$!
    log "INFO" "The process id of mysqld is '$pid'"
}

start_mysqld_in_background
wait_for_host_online "root" "localhost" "$MYSQL_ROOT_PASSWORD"
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
    # Also check if this node is already ONLINE in GR — this happens when
    # another pod's coordinator called rebootClusterFromCompleteOutage() which
    # rejoins all members remotely via mysqlsh AdminAPI, bypassing this script.
    while [ ! -f "/scripts/signal.txt" ]; do
        member_state=$(mysql -u${MYSQL_ROOT_USERNAME} -hlocalhost -p${MYSQL_ROOT_PASSWORD} -N -e \
            "SELECT MEMBER_STATE FROM performance_schema.replication_group_members WHERE MEMBER_HOST='${report_host}' LIMIT 1;" 2>/dev/null)
        if [[ "$member_state" == "ONLINE" ]]; then
            log "INFO" "Already ONLINE in GR group (joined by another node's reboot) — skipping signal wait"
            break
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

    log "INFO" "waiting for mysql process id = $pid"
    rm -rf /scripts/signal.txt
    rm -rf /scripts/setup.txt
    wait $pid
done
