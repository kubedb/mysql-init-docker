#!/usr/bin/env bash
#set -x

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
report_host="$HOSTNAME.$GOV_SVC.$POD_NAMESPACE.svc"
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
cat >>/etc/mysql/my.cnf <<EOL
!includedir /etc/mysql/conf.d/
[mysqld]
default_authentication_plugin=mysql_native_password
#loose-group_replication_ip_whitelist = "${whitelist}"
loose-group_replication_ip_allowlist = "${whitelist}"
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
    done
    return 0
}

function wait_for_host_online() {
    #function called with parameter user,host,password
    log "INFO" "checking for host $2 to come online"

    local mysqlshell="mysql -u$1 -h$2 -p$3" # "mysql -uroot -ppass -hmysql-server-0.mysql-server.default.svc"
    retry 900 ${mysqlshell} -e "select 1;" | awk '{print$1}'
    out=$(${mysqlshell} -e "select 1;" | head -n1 | awk '{print$1}')
    if [[ "$out" == "1" ]]; then
        log "INFO" "host $2 is online"
    else
        log "INFO" "server failed to comes online within 900 seconds"
    fi

}

function create_replication_user() {
    # MySql server's need a replication user to communicate with each other
    # 01. official doc (section from 17.2.1.3 to 17.2.1.5): https://dev.mysql.com/doc/refman/5.7/en/group-replication-user-credentials.html
    # 02. https://dev.mysql.com/doc/refman/8.0/en/group-replication-secure-user.html
    # 03. repl user permissions: https://www.sqlshack.com/deploy-mysql-innodb-clusters-for-high-availability/
    # 04. digitalocean doc: https://www.digitalocean.com/community/tutorials/how-to-configure-mysql-group-replication-on-ubuntu-16-04
    log "INFO" "Checking whether replication user exist or not..."
    local mysql="mysql -u ${MYSQL_ROOT_USERNAME} -hlocalhost -p${MYSQL_ROOT_PASSWORD} --port=3306"

    # At first, ensure that the command executes without any error. Then, run the command again and extract the output.
    retry 120 ${mysql} -N -e "select count(host) from mysql.user where mysql.user.user='repl';"
    out=$(${mysql} -N -e "select count(host) from mysql.user where mysql.user.user='repl';" | awk '{print$1}')
    # if the user doesn't exist, crete new one.
    if [[ "$out" -eq "0" ]]; then
        log "INFO" "Replication user not found. Creating new replication user..."
        retry 120 ${mysql} -N -e "SET SQL_LOG_BIN=0;"
        retry 120 ${mysql} -N -e "CREATE USER 'repl'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' REQUIRE SSL;"
        retry 120 ${mysql} -N -e "GRANT CREATE USER, FILE, PROCESS, RELOAD, REPLICATION CLIENT, REPLICATION SLAVE, SELECT, SHUTDOWN, SUPER ON *.* TO 'repl'@'%' WITH GRANT OPTION;"
        retry 120 ${mysql} -N -e "GRANT DELETE, INSERT, UPDATE ON mysql.* TO 'repl'@'%' WITH GRANT OPTION;"
        retry 120 ${mysql} -N -e "GRANT ALTER, ALTER ROUTINE, CREATE, CREATE ROUTINE, CREATE TEMPORARY TABLES, CREATE VIEW, DELETE, DROP, EVENT, EXECUTE, INDEX, INSERT, LOCK TABLES, REFERENCES, SHOW VIEW, TRIGGER, UPDATE ON mysql_innodb_cluster_metadata.* TO 'repl'@'%' WITH GRANT OPTION;"
        retry 120 ${mysql} -N -e "GRANT ALTER, ALTER ROUTINE, CREATE, CREATE ROUTINE, CREATE TEMPORARY TABLES, CREATE VIEW, DELETE, DROP, EVENT, EXECUTE, INDEX, INSERT, LOCK TABLES, REFERENCES, SHOW VIEW, TRIGGER, UPDATE ON mysql_innodb_cluster_metadata_bkp.* TO 'repl'@'%' WITH GRANT OPTION;"
        retry 120 ${mysql} -N -e "GRANT ALTER, ALTER ROUTINE, CREATE, CREATE ROUTINE, CREATE TEMPORARY TABLES, CREATE VIEW, DELETE, DROP, EVENT, EXECUTE, INDEX, INSERT, LOCK TABLES, REFERENCES, SHOW VIEW, TRIGGER, UPDATE ON mysql_innodb_cluster_metadata_previous.* TO 'repl'@'%' WITH GRANT OPTION;"
        retry 120 ${mysql} -N -e "GRANT CLONE_ADMIN, BACKUP_ADMIN, CONNECTION_ADMIN, EXECUTE, GROUP_REPLICATION_ADMIN, PERSIST_RO_VARIABLES_ADMIN, REPLICATION_APPLIER, REPLICATION_SLAVE_ADMIN, ROLE_ADMIN, SYSTEM_VARIABLES_ADMIN ON *.* TO 'repl'@'%' WITH GRANT OPTION;"
        #mysql-server docker image doesn't has the user root that can connect from any host
        retry 120 ${mysql} -N -e "CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';"
        retry 120 ${mysql} -N -e "GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION;"
        retry 120 ${mysql} -N -e "FLUSH PRIVILEGES;"
        retry 120 ${mysql} -N -e "SET SQL_LOG_BIN=1;"
    fi
    #    retry 120 ${mysql} -N -e "CHANGE MASTER TO MASTER_USER='repl', MASTER_PASSWORD='$MYSQL_ROOT_PASSWORD' FOR CHANNEL 'group_replication_recovery';"
}

restart_required=0
already_configured=0

function configure_instance() {
    log "INFO" "configuring instance $report_host."
    local mysqlshell="mysqlsh -u${replication_user} -p${MYSQL_ROOT_PASSWORD}"

    retry 120 ${mysqlshell} --sql -e "select @@gtid_mode;"
    gtid=($($mysqlshell --sql -e "select @@gtid_mode;"))
    if [[ "${gtid[1]}" == "ON" ]]; then
        log "INFO" "$report_host is already_configured."
        already_configured=1
        return
    fi

    retry 30 ${mysqlshell} -e "dba.configureInstance('${replication_user}@${report_host}',{password:'${MYSQL_ROOT_PASSWORD}',interactive:false,restart:true});"
    #instance need to restart after configuration
    # Prevent creation of new process until this one is finished
    #https://serverfault.com/questions/477448/mysql-keeps-crashing-innodb-unable-to-lock-ibdata1-error-11
    #The most common cause of this problem is trying to start MySQL when it is already running.
    wait $pid
    restart_required=1
}

function create_cluster() {
    local mysqlshell="mysqlsh -u${replication_user} -p${MYSQL_ROOT_PASSWORD} -h${report_host}"
    clusterName=$(echo -n $BASE_NAME | sed 's/-/_/g')
    retry 5 $mysqlshell -e "cluster=dba.createCluster('$clusterName',{consistency:'BEFORE_ON_PRIMARY_FAILOVER',manualStartOnBoot:'true'});"
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
    ${mysqlshell} -e "cluster = dba.getCluster();  cluster.rescan({addInstances:['${report_host}:3306'],interactive:false})"
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
    retry 10 ${mysqlshell} -e "cluster = dba.getCluster();cluster.addInstance('${replication_user}@${report_host}',{recoveryMethod:'incremental'});"
}

function join_by_clone() {
    log "INFO " "$report_host joining in cluster"
    local mysqlshell="mysqlsh -u${replication_user} -p${MYSQL_ROOT_PASSWORD} -h${primary}"
    retry 10 ${mysqlshell} -e "cluster = dba.getCluster();cluster.removeInstance('$report_host',{force:'true'});"
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
    retry 10 ${mysqlshell} -e "cluster = dba.getCluster();  cluster.rescan({addInstances:['${report_host}:3306'],interactive:false})"
}

function rejoin_in_cluster() {
    local mysqlshell="mysqlsh -u${replication_user} -p${MYSQL_ROOT_PASSWORD} -h${primary}"
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
        retry 1 ${mysqlshell} -e "cluster = dba.getCluster();cluster.removeInstance('$report_host',{force:'true'});"
        join_in_cluster
    fi

}

export pid
function reboot_from_completeOutage() {
    local mysqlshell="mysqlsh -u${replication_user} -h${report_host} -p${MYSQL_ROOT_PASSWORD}"
    #https://dev.mysql.com/doc/dev/mysqlsh-api-javascript/8.0/classmysqlsh_1_1dba_1_1_dba.html#ac68556e9a8e909423baa47dc3b42aadb
    #mysql wait for user interaction to remove the unavailable seed from the cluster..
    clusterName=$(echo -n $BASE_NAME | sed 's/-/_/g')
    yes | $mysqlshell -e "dba.rebootClusterFromCompleteOutage('$clusterName',{force:'true'})"
    yes | $mysqlshell -e "cluster = dba.getCluster();  cluster.rescan()"
    wait $pid
}

function start_mysqld_in_background() {
    log "INFO" "Starting mysql server with 'docker-entrypoint.sh mysqld $args'..."
    /entrypoint.sh mysqld --user=root --report-host=$report_host --bind-address=* $args &
    pid=$!
    log "INFO" "The process id of mysqld is '$pid'"
}

replication_user=repl

start_mysqld_in_background
wait_for_host_online "root" "localhost" "$MYSQL_ROOT_PASSWORD"
create_replication_user
configure_instance

if [[ "$restart_required" == "1" ]]; then
    start_mysqld_in_background
    wait_for_host_online "repl" "$report_host" "$MYSQL_ROOT_PASSWORD"
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
        wait_for_host_online "repl" "$report_host" "$MYSQL_ROOT_PASSWORD"
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
        wait_for_host_online "repl" "$report_host" "$MYSQL_ROOT_PASSWORD"
        join_in_cluster
    fi

    if [[ $desired_func == "reboot_from_complete_outage" ]]; then
        reboot_from_completeOutage
    fi
    log "INFO" "waiting for mysql process id  = $pid"
    wait $pid
    rm -rf /scripts/signal.txt

done
