#!/usr/bin/env bash

#   BASE_NAME           = name of the StatefulSet (same as the name of CRD)
#   HOSTNAME            = name of the host | name of the pod (set by k8s)

env | sort | grep "POD\|HOST\|NAME"

args=$@
USER="$MYSQL_ROOT_USERNAME"
PASSWORD="$MYSQL_ROOT_PASSWORD"
read_user="$read_only_user"
read_password="$read_only_password"
localhost=127.0.0.1
function timestamp() {
    date +"%Y/%m/%d %T"
}

function log() {
    local type="$1"
    local msg="$2"
    echo "$(timestamp) [$script_name] [$type] $msg"
}

svr_id=$(($(echo -n "${HOSTNAME}" | sed -e "s/${BASE_NAME}-//g") + 11))
echo "server_id =  $svr_id"

log "INFO" "Storing default mysqld config into /etc/mysql/my.cnf"
mkdir -p /etc/mysql/read_only.conf.d/
echo "!includedir /etc/mysql/read_only.conf.d/" >>/etc/mysql/my.cnf

cat >>/etc/mysql/read_only.conf.d/read.cnf <<EOL
[mysqld]
#disabled_storage_engines="MyISAM,BLACKHOLE,FEDERATED,ARCHIVE,MEMORY"
# General replication settings
gtid_mode = ON
enforce_gtid_consistency = ON
# Host specific replication configuration
server_id = ${svr_id}
bind-address = "0.0.0.0"
#report_host = "${report_host}"
EOL

export pid

function start_mysqld_in_background() {
    log "INFO" "Starting mysql server with 'docker-entrypoint.sh mysqld ${args[@]}'..."
    docker-entrypoint.sh mysqld $args &
    pid=$!
    log "INFO" "The process id of mysqld is '$pid'"
}

# wait for mysql daemon be running (alive)
function wait_for_mysqld_running() {
    local mysql="$mysql_header --host=$localhost"

    for i in {900..0}; do
        out=$(mysql -N -e "select 1;" 2>/dev/null)
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
}

function start_read_replica() {
    #stop_slave
    local mysql="$mysql_header --host=$localhost"

    if [[ "$source_ssl" == "true" ]]; then
        ssl_config=",SOURCE_SSL=1,SOURCE_SSL_CA = '/etc/mysql/server/certs/ca.crt'"
        require_SSL="REQUIRE SSL"
    fi
    echo $ssl_config
    out=$($mysql_header -e "CHANGE MASTER TO MASTER_HOST = '$hostToConnect',MASTER_PORT = 3306,MASTER_USER = '$USER',MASTER_PASSWORD = '$PASSWORD',MASTER_AUTO_POSITION = 1 $ssl_config;")
    echo $out
    sleep 1
    out=$($mysql_header -e "start slave;")
    echo $out
}

start_mysqld_in_background

export mysql_header="mysql -u ${USER} --port=3306"
export MYSQL_PWD=${PASSWORD}

wait_for_mysqld_running

while true; do
    kill -0 $pid
    exit="$?"

    if [[ "$exit" == "0" ]]; then
        echo "mysqld process is running"
    else
        echo "need to start mysqld and wait_for_mysqld_running"
        start_mysqld_in_background
        wait_for_mysqld_running
    fi

    start_read_replica
    log "INFO" "waiting for mysql process id  = $pid"

    reading_first_time=0
    wait $pid
done
