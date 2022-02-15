#!/usr/bin/env bash

#   BASE_NAME           = name of the StatefulSet (same as the name of CRD)
#   HOSTNAME            = name of the host | name of the pod (set by k8s)
#   primaryHost         = primary dns of the source
#   hostToConnect       = source dns

env | sort | grep "POD\|HOST\|NAME"

args=$@
echo "-----------------------$args-------------------------"
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

log "INFO" "Storing default mysqld config into /etc/mysql/my.cnf"

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
EOL

export pid

function start_mysqld_in_background() {
    log "INFO" "Starting mysql server with 'docker-entrypoint.sh mysqld ${args[@]}'..."
    docker-entrypoint.sh mysqld  $args &
    pid=$!
    log "INFO" "The process id of mysqld is '$pid'"
}

reading_first_time=0
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

# create mysql client with user exported in mysql_header and export password
# this is to bypass the warning message for using password
start_mysqld_in_background

export mysql_header="mysql -u ${USER} --port=3306"
export MYSQL_PWD=${PASSWORD}


wait_for_mysqld_running

install_clone_plugin "localhost"

install_clone_plugin "$primaryHost"

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

    if [[ "$reading_first_time" == "1" ]];then

      out=$($mysql_header -e "SET GLOBAL clone_valid_donor_list='$primaryHost:3306';")
      echo "------------$out-----------"


       error_message=$(${mysql_header}  -e "CLONE INSTANCE FROM 'root'@'$primaryHost':3306 IDENTIFIED BY '$PASSWORD' $require_SSL;" 2>&1)

       # https://dev.mysql.com/doc/refman/8.0/en/clone-plugin-remote.html#:~:text=ERROR%203707%20(HY000)%3A%20Restart,not%20managed%20by%20supervisor%20process).&text=It%20means%20that%20the%20recipient,after%20the%20data%20is%20cloned.
      log "INFO" "Clone error message: $error_message"


    fi
    start_read_replica
    log "INFO" "waiting for mysql process id  = $pid"
    reading_first_time=0
    wait $pid
done