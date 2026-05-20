#!/usr/bin/env bash

#   BASE_NAME           = name of the StatefulSet (same as the name of CRD)
#   HOSTNAME            = name of the host | name of the pod (set by k8s)
#   SOURCE_HOST         = primary dns of the source
#   hostToConnect       = source dns

env | sort | grep "POD\|HOST\|NAME"

args=$@

USER="$MYSQL_ROOT_USERNAME"
PASSWORD="$MYSQL_ROOT_PASSWORD"

localhost=127.0.0.1
report_host="$HOSTNAME.$GOV_SVC.$POD_NAMESPACE.svc"
echo "report_host = $report_host "
function timestamp() {
    date +"%Y/%m/%d %T"
}

function log() {
    local type="$1"
    local msg="$2"
    echo "$(timestamp) [$script_name] [$type] $msg"
}

# Detect MySQL version. Pick the replication-DDL syntax to exactly match
# what each source branch shipped:
#   - innodb-support-80 (8.0.x):  STOP SLAVE / CHANGE MASTER TO / START SLAVE
#   - innodb-support (8.4.x):     STOP REPLICA / CHANGE REPLICATION SOURCE TO / START REPLICA
# Both syntaxes work on 8.0.22+ as aliases, but we use the per-branch original
# so behaviour and log output match each branch's deployments precisely.
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
version_ge() {
    local want_major=$1 want_minor=$2
    if [[ "$MYSQL_MAJOR" -gt "$want_major" ]]; then return 0; fi
    if [[ "$MYSQL_MAJOR" -eq "$want_major" && "$MYSQL_MINOR" -ge "$want_minor" ]]; then return 0; fi
    return 1
}
detect_mysql_version

# Pick the right replication-DDL syntax for this MySQL version family.
if version_ge 8 4; then
    SQL_STOP_REPLICA="stop replica;"
    SQL_START_REPLICA="start replica;"
    SQL_CHANGE_SRC_FMT="CHANGE REPLICATION SOURCE TO SOURCE_HOST = '%s',SOURCE_PORT = 3306,SOURCE_USER = '%s',SOURCE_PASSWORD = '%s',SOURCE_AUTO_POSITION = 1 %s;"
else
    SQL_STOP_REPLICA="stop slave;"
    SQL_START_REPLICA="start slave;"
    SQL_CHANGE_SRC_FMT="CHANGE MASTER TO MASTER_HOST = '%s',MASTER_PORT = 3306,MASTER_USER = '%s',MASTER_PASSWORD = '%s',MASTER_AUTO_POSITION = 1 %s;"
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
    done
    return 0
}

echo $BASE_NAME
svr_id=$(od -An -N3 -i /dev/urandom | awk '{print $1}')
svr_id=${svr_id#-}
log "INFO" "server_id =  $svr_id"

log "INFO" "Storing default mysqld config into /etc/mysql/my.cnf"

mkdir -p /etc/mysql/conf.d/
echo "!includedir /etc/mysql/conf.d/" >>/etc/mysql/my.cnf

mkdir -p /etc/mysql/read_only.conf.d/
echo "!includedir /etc/mysql/read_only.conf.d/" >>/etc/mysql/my.cnf

cat >>/etc/mysql/read_only.conf.d/read.cnf <<EOL
[mysqld]
#default-authentication-plugin=mysql_native_password
disabled_storage_engines="MyISAM,BLACKHOLE,FEDERATED,ARCHIVE,MEMORY"
# General replication settings
gtid_mode = ON
enforce_gtid_consistency = ON
# Host specific replication configuration
server_id = ${svr_id}
bind-address = "0.0.0.0"
socket="/var/run/mysqld/mysqld.sock"
report_host="$report_host"
EOL

mkdir -p /etc/mysql/conf.d/
echo "!includedir /etc/mysql/conf.d/" >>/etc/mysql/my.cnf

export pid

function start_mysqld_in_background() {
    log "INFO" "Starting mysql server with 'docker-entrypoint.sh mysqld ${args[@]}'..."
    docker-entrypoint.sh mysqld $args &
    pid=$!
    log "INFO" "The process id of mysqld is '$pid'"
}

reading_first_time=0
function install_clone_plugin() {
    log "INFO" "Checking whether clone plugin on host $1 is installed or not...."
    ssl_config=""
    if [[ "$1" == "$SOURCE_HOST" ]]; then
        if [[ "$source_ssl" == "true" ]]; then
            ssl_config="--ssl-ca=/etc/mysql/server/certs/ca.crt --ssl-cert=/etc/mysql/server/certs/tls.crt --ssl-key=/etc/mysql/server/certs/tls.key"
        fi
    fi
    local mysql="mysql  --host=$1 --user=$2 --password=$3 --port=3306 $ssl_config"

    # At first, ensure that the command executes without any error. Then, run the command again and extract the output.
    retry 120 ${mysql} -N -e 'SHOW PLUGINS;' | grep clone
    out=$(${mysql} -N -e 'SHOW PLUGINS;' | grep clone)
    if [[ -z "$out" ]]; then
        log "INFO" "Clone plugin is not installed. Installing the plugin..."
        retry 120 ${mysql} -e "INSTALL PLUGIN clone SONAME 'mysql_clone.so';"
        reading_first_time=1
        log "INFO" "Clone plugin successfully installed"
    else
        log "INFO" "Already clone plugin is installed"
    fi
}

# wait for mysql daemon be running (alive)
function wait_for_mysqld_running() {
    local mysql="mysql -u ${USER} --port=3306 --password=${PASSWORD} --host=$localhost"

    for i in {900..0}; do
        out=$(${mysql} -N -e "select 1;" 2>/dev/null)
        log "INFO" "Attempt $i: Pinging '$report_host' has returned: '$out'...................................."
        if [[ "$out" == "1" ]]; then
            break
        fi
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
    $mysql_header -e "$SQL_STOP_REPLICA"

    # SSL keyword names follow the same source-vs-master rename as the rest:
    # SOURCE_SSL* on 8.4+, MASTER_SSL* on 8.0.x (matches each source branch).
    if version_ge 8 4; then
        ssl_config=",SOURCE_SSL=0"
        if [[ "$source_ssl" == "true" ]]; then
            ssl_config=",SOURCE_SSL=1,SOURCE_SSL_CA = '/etc/mysql/server/certs/ca.crt',SOURCE_SSL_CERT = '/etc/mysql/server/certs/tls.crt',SOURCE_SSL_KEY = '/etc/mysql/server/certs/tls.key'"
            require_SSL="REQUIRE SSL"
        fi
    else
        ssl_config=",MASTER_SSL=0"
        if [[ "$source_ssl" == "true" ]]; then
            ssl_config=",MASTER_SSL=1,MASTER_SSL_CA = '/etc/mysql/server/certs/ca.crt',MASTER_SSL_CERT = '/etc/mysql/server/certs/tls.crt',MASTER_SSL_KEY = '/etc/mysql/server/certs/tls.key'"
            require_SSL="REQUIRE SSL"
        fi
    fi
    echo $ssl_config

    # Compose the CHANGE statement using the per-version keyword set
    local change_sql
    change_sql=$(printf "$SQL_CHANGE_SRC_FMT" "$SOURCE_HOST" "$SOURCE_USERNAME" "$SOURCE_PASSWORD" "$ssl_config")
    out=$($mysql_header -e "$change_sql")
    echo $out
    sleep 1
    out=$($mysql_header -e "$SQL_START_REPLICA")
    echo $out

    $mysql_header -e "set global super_read_only=ON"
}

# create mysql client with user exported in mysql_header and export password
# this is to bypass the warning message for using password
start_mysqld_in_background

export mysql_header="mysql -u ${USER} --port=3306 --password=${PASSWORD}"
#export MYSQL_PWD=${PASSWORD}

wait_for_mysqld_running

install_clone_plugin "localhost" "$USER" "$PASSWORD"

install_clone_plugin "$SOURCE_HOST" "$SOURCE_USERNAME" "$SOURCE_PASSWORD" $ssl_config

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

    if [[ "$reading_first_time" == "1" ]]; then
        $mysql_header -e "set global super_read_only=OFF"
        $mysql_header -e "SET GLOBAL clone_valid_donor_list='$SOURCE_HOST:3306';"
        reading_first_time=0
        error_message=$(${mysql_header} -e "CLONE INSTANCE FROM '$SOURCE_USERNAME'@'$SOURCE_HOST':3306 IDENTIFIED BY '$SOURCE_PASSWORD' $require_SSL;" 2>&1)
        # https://dev.mysql.com/doc/refman/8.0/en/clone-plugin-remote.html#:~:text=ERROR%203707%20(HY000)%3A%20Restart,not%20managed%20by%20supervisor%20process).&text=It%20means%20that%20the%20recipient,after%20the%20data%20is%20cloned.
    fi
    start_read_replica
    log "INFO" "waiting for mysql process id  = $pid"

    wait $pid
done
