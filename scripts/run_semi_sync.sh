#!/usr/bin/env bash
args=$@
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

# Version detection — same shape as run.sh / run_innodb.sh. Used to gate
# 8.4-vs-older SQL syntax (RESET BINARY LOGS AND GTIDS vs RESET MASTER)
# and the source/master semi-sync plugin name change in 8.4.
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
reset_binlog_and_gtids_sql() {
    if version_ge 8 4; then
        echo "RESET BINARY LOGS AND GTIDS;"
    else
        echo "RESET MASTER;"
    fi
}
detect_mysql_version

echo $BASE_NAME
svr_id=$(($(echo -n "${HOSTNAME}" | sed -e "s/${BASE_NAME}-//g") + 11))
log "INFO" "server_id =  $svr_id"

mkdir -p /etc/mysql/conf.d/
echo "!includedir /etc/mysql/conf.d/" >>/etc/mysql/my.cnf

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
socket="/var/run/mysqld/mysqld.sock"
EOL

export pid

function start_mysqld_in_background() {
    log "INFO" "Starting mysql server with 'docker-entrypoint.sh mysqld $args'..."
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
        retry 120 ${mysql} -e "$(reset_binlog_and_gtids_sql)"
        log "INFO" "Clone plugin successfully installed"
    else
        log "INFO" "Already clone plugin is installed"
    fi
}

function install_semiSync_plugin() {
    log "INFO" "Checking whether semi_sync plugin on host $1 is installed or not...."
    local mysql="$mysql_header --host=$1"

    # The semi-sync plugin was renamed in MySQL 8.4:
    #   <8.4 (innodb-support-80):  rpl_semi_sync_master / rpl_semi_sync_slave
    #                              shared objects: semisync_master.so / semisync_slave.so
    #   >=8.4 (innodb-support):    rpl_semi_sync_source / rpl_semi_sync_replica
    #                              shared objects: semisync_source.so / semisync_replica.so
    # The plugin files literally don't exist under the old names on 8.4+ (and
    # vice versa). Pick the right pair, and on 8.4+ also handle the upgrade
    # path where an old cluster's mysql.plugin table still references the old
    # plugin names: stop replica + uninstall old before installing new (this
    # block is what innodb-support shipped).
    if version_ge 8 4; then
        # 8.4+ path — try to clean up legacy plugin first if present, then
        # install the modern pair.
        retry 120 ${mysql} -N -e 'SHOW PLUGINS;' | grep 'semisync_master'
        out=$(${mysql} -N -e 'SHOW PLUGINS;' | grep 'semisync_master')
        replicaStop=0
        if [[ -n "$out" ]]; then
            log "INFO" "previous version plugin is installed. Uninstalling the plugin..."
            retry 120 ${mysql} -e "STOP REPLICA;"
            retry 120 ${mysql} -e "UNINSTALL PLUGIN rpl_semi_sync_master;"
            retry 120 ${mysql} -e "UNINSTALL PLUGIN rpl_semi_sync_slave;"
            replicaStop=1
        fi
        retry 120 ${mysql} -N -e 'SHOW PLUGINS;' | grep semisync_source
        out=$(${mysql} -N -e 'SHOW PLUGINS;' | grep semisync_source)
        if [[ -z "$out" ]]; then
            log "INFO" "semisync plugin is not installed. Installing the plugin..."
            retry 120 ${mysql} -e "INSTALL PLUGIN rpl_semi_sync_source SONAME 'semisync_source.so';"
            retry 120 ${mysql} -e "INSTALL PLUGIN rpl_semi_sync_replica SONAME 'semisync_replica.so';"
            reading_first_time=1
            log "INFO" "semi_sync plugin successfully installed"
            if [[ "$replicaStop" == 1 ]]; then
                retry 120 ${mysql} -e "START REPLICA;"
            fi
        else
            log "INFO" "Already semi_sync plugin is installed"
        fi
    else
        # 8.0.x path — match innodb-support-80 exactly.
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
    fi
}

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
}

# create mysql client with user exported in mysql_header and export password
# this is to bypass the warning message for using password

start_mysqld_in_background

export mysql_header="mysql -u ${USER} --port=3306"
export MYSQL_PWD=${PASSWORD}

wait_for_mysqld_running

install_clone_plugin "localhost"

install_semiSync_plugin "localhost"

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
    log "INFO" "waiting for mysql process $pid."
    wait $pid
done
