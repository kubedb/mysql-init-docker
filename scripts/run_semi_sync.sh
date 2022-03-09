#!/usr/bin/env bash

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
svr_id=$(($(echo -n "${HOSTNAME}" | sed -e "s/${BASE_NAME}-//g") + 11))
log "INFO" "server_id =  $svr_id"

mkdir -p /etc/mysql/semi_sync.conf.d/
echo "!includedir /etc/mysql/semi_sync.conf.d/" >>/etc/mysql/my.cnf
cat >>/etc/mysql/semi_sync.conf.d/read.cnf <<EOL
[mysqld]
datadir=/var/lib/mysql/data
disabled_storage_engines="MyISAM,BLACKHOLE,FEDERATED,ARCHIVE,MEMORY"
# General replication settings
gtid_mode = ON
enforce_gtid_consistency = ON
bind-address = "0.0.0.0"
server_id = ${svr_id}
EOL

export pid

function start_mysqld_in_background() {
    log "INFO" "Starting mysql server with 'docker-entrypoint.sh mysqld ${args[@]}'..."
    docker-entrypoint.sh mysqld $args &
    pid=$!
    log "INFO" "The process id of mysqld is '$pid'"
}

function install_clone_plugin() {
    log "INFO" "Checking whether clone plugin on host $1 is installed or not...."
    local mysql="$mysql_header --host=$1"

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

function install_semiSync_plugin() {
    log "INFO" "Checking whether semi_sync plugin on host $1 is installed or not...."
    local mysql="$mysql_header --host=$1"

    # At first, ensure that the command executes without any error. Then, run the command again and extract the output.
    retry 120 ${mysql} -N -e 'SHOW PLUGINS;' | grep semisync
    out=$(${mysql} -N -e 'SHOW PLUGINS;' | grep semisync)
    if [[ -z "$out" ]]; then
        log "INFO" "semisync plugin is not installed. Installing the plugin..."
        retry 120 ${mysql} -e "INSTALL PLUGIN rpl_semi_sync_master SONAME 'semisync_master.so';"
        retry 120 ${mysql} -e "INSTALL PLUGIN rpl_semi_sync_slave SONAME 'semisync_slave.so';"
        reading_first_time=1
        log "INFO" "semi_sync plugin successfully installed"
    else
        log "INFO" "Already semi_sync plugin is installed"
    fi
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

# create mysql client with user exported in mysql_header and export password
# this is to bypass the warning message for using password
start_mysqld_in_background

export mysql_header="mysql -u ${USER} --port=3306"
export MYSQL_PWD=${PASSWORD}

wait_for_mysqld_running

install_clone_plugin "localhost"

install_semiSync_plugin "localhost"
log "INFO" "waiting for mysql process $pid."
wait $pid
