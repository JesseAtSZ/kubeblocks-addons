#!/usr/bin/env bash

#
# Copyright (c) 2023 OceanBase
# ob-operator is licensed under Mulan PSL v2.
# You can use this software according to the terms and conditions of the Mulan PSL v2.
# You may obtain a copy of Mulan PSL v2 at:
#          http://license.coscl.org.cn/MulanPSL2
# THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
# EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
# MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
# See the Mulan PSL v2 for more details.
#

source /scripts/sql.sh

ZONE_COUNT=${ZONE_COUNT:-3}
WAIT_SERVER_SLEEP_TIME="${WAIT_SERVER_SLEEP_TIME:-10}"
WAIT_K8S_DNS_READY_TIME="${WAIT_K8S_DNS_READY_TIME:-10}"
SVC_NAME="${KB_CLUSTER_COMP_NAME}-headless.${KB_NAMESPACE}.svc"
HOSTNAME=$(hostname)
REP_USER=${REP_USER:-rep_user}
REP_PASSWD=${REP_PASSWD:-rep_user}
OB_DEBUG=${OB_DEBUG:-true}
OB_HOME_DIR=${OB_HOME_DIR:-/home/admin/oceanbase}
OB_CLUSTERS_COUNT=${OB_CLUSTERS_COUNT:-1}

ORDINAL_INDEX=$(echo $KB_POD_NAME | awk -F '-' '{print $(NF)}')
COMPONENT_INDEX=$(echo $KB_POD_NAME | awk -F '-' '{print $(NF-1)}')
ZONE_NAME="zone$((${ORDINAL_INDEX}%${ZONE_COUNT}))"

echo "ORDINAL_INDEX: $ORDINAL_INDEX"
echo "COMPONENT_INDEX: $COMPONENT_INDEX"
echo "ZONE_NAME: $ZONE_NAME"
echo "COMP_MYSQL_PORT: $COMP_MYSQL_PORT"
echo "COMP_RPC_PORT: $COMP_RPC_PORT"

function init_port_list {
  MYSQL_PORTS=()
  RPC_PORTS=()
  for i in $(seq 0 $(($OB_CLUSTERS_COUNT-1))); do
    MYSQL_PORTS+=(2881)
    RPC_PORTS+=(2882)
  done

  {{- range $i, $e := $.dynamicCompInfos }}
    {{- $mysql_port_info := getPortByName ( index $e.containers 0 ) "sql" }}
    {{- $rpc_port_info := getPortByName ( index $e.containers 0 ) "rpc" }}
    {{- $mysql_port := 2881 }}
    {{- if $mysql_port_info }}
      {{- $mysql_port = $mysql_port_info.hostPort }}
    {{- end }}
    {{- $rpc_port := 2882 }}
    {{- if $rpc_port_info }}
      {{- $rpc_port = $rpc_port_info.hostPort }}
    {{- end }}
    MYSQL_PORTS[{{ $i }}]={{$mysql_port}}
    RPC_PORTS[{{ $i }}]={{$rpc_port}}
  {{- end }}

  COMP_MYSQL_PORT=${MYSQL_PORTS[$COMPONENT_INDEX]}
  COMP_RPC_PORT=${RPC_PORTS[$COMPONENT_INDEX]}
  # persisting the sql port for backup and restore
  echo $COMP_MYSQL_PORT > /home/admin/workdir/sql_port.ob
  echo "sql_port: $COMP_MYSQL_PORT"
  echo "rpc_port: $COMP_RPC_PORT"
}

function get_pod_ip_list {
  # Get the headless service name
  ZONE_SERVER_LIST=""
  RS_LIST=""
  IP_LIST=()

  # wait for up to 10 minutes for the server to be ready
  local wait_time=600
  # Get every replica's IP
  for i in $(seq 0 $(($KB_REPLICA_COUNT-1))); do
    local replica_hostname="${KB_CLUSTER_COMP_NAME}-${i}"
    local replica_ip=""
    if [ $i -ne $ORDINAL_INDEX ]; then
      echo "nslookup $replica_hostname.$SVC_NAME"
      local elapsed_time=0
      while [ $elapsed_time -lt $wait_time ]; do
        replica_ip=$(nslookup $replica_hostname.$SVC_NAME | tail -n 2 | grep -P "(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})" --only-matching)
        if [ $? -ne 0 ]; then
          echo "$replica_hostname.$SVC_NAME is not ready yet"
          sleep 10
          elapsed_time=$((elapsed_time + 10))
        else
          echo "$replica_hostname.$SVC_NAME is ready"
          echo "nslookup $replica_hostname.$SVC_NAME success, IP: $replica_ip"
          break
        fi
      done
      if [ $elapsed_time -ge $wait_time ]; then
        echo "Failed to get the IP of $replica_hostname.$SVC_NAME, exit..."
        exit 1
      fi
    else
      replica_ip=$KB_POD_IP
    fi

    IP_LIST+=("$replica_ip")

    # Construct the ZONE_SERVER_LIST and RS_LIST
    if [ $i -lt $ZONE_COUNT ]; then
      if [ $i -eq 0 ]; then
        ZONE_SERVER_LIST="ZONE 'zone${i}' SERVER '${replica_ip}:$COMP_RPC_PORT'"
        RS_LIST="${replica_ip}:$COMP_RPC_PORT:$COMP_MYSQL_PORT"
      else
        ZONE_SERVER_LIST="${ZONE_SERVER_LIST},ZONE 'zone${i}' SERVER '${replica_ip}:$COMP_RPC_PORT'"
        RS_LIST="${RS_LIST};${replica_ip}:$COMP_RPC_PORT:$COMP_MYSQL_PORT"
      fi
    fi
  done

  echo "get_pod_ip_list: ${IP_LIST[*]}"
  echo "rs_list: $RS_LIST"
}

function prepare_dirs {
  # log dir
  mkdir -p /home/admin/log/log
  ln -sf /home/admin/log/log ${OB_HOME_DIR}/log

  mkdir -p  ${OB_HOME_DIR}/store
  # data log dir
  mkdir -p /home/admin/data-log/clog

  ln -sf /home/admin/data-log/clog ${OB_HOME_DIR}/store/clog
  mkdir -p /home/admin/data-log/ilog
  ln -sf /home/admin/data-log/ilog ${OB_HOME_DIR}/store/ilog

  mkdir -p /home/admin/data-file/slog
  ln -sf /home/admin/data-file/slog ${OB_HOME_DIR}/store/slog
  mkdir -p /home/admin/data-file/etc
  ln -sf /home/admin/data-file/etc ${OB_HOME_DIR}/store/etc
  mkdir -p /home/admin/data-file/sort_dir
  ln -sf /home/admin/data-file/sort_dir ${OB_HOME_DIR}/store/sort_dir
  mkdir -p /home/admin/data-file/sstable
  ln -sf /home/admin/data-file/sstable ${OB_HOME_DIR}/store/sstable
  # chown -R root:root ${OB_HOME_DIR}
}

function clean_dirs {
  rm -rf ${OB_HOME_DIR}/etc
  rm -rf ${OB_HOME_DIR}/store/*
  rm -rf /home/admin/data-log/*
  rm -rf /home/admin/data-file/*
  rm -rf /home/admin/log/log
}

function start_observer {
  echo "Start observer process as normal server..."
  # if debug mode is enabled, set log level to debug
  local loglevel="INFO"
  if [ "$OB_DEBUG" = "true" ]; then
    loglevel="DEBUG"
  fi
  # parse the config file
  default_configs='cpu_count=4,memory_limit=8G,system_memory=1G,__min_full_resource_pool_memory=1073741824,datafile_size=40G,log_disk_size=40G,net_thread_count=2,stack_size=512K,cache_wash_threshold=1G,schema_history_expire_time=1d,enable_separate_sys_clog=false,enable_merge_by_turn=false,enable_syslog_recycle=true,enable_syslog_wf=false,max_syslog_file_count=4'

  # check if file exists
  if [ -f "/kb-config/oceanbase.conf" ]; then
    echo "observer.conf.bin exists, start observer with existing configs"
    customized_config=$(cat "/kb-config/oceanbase.conf" | sed 's/ \+/ /g' | tr '\n' ',')
    # remove all spaces and the last comma
    customized_config=$(echo "$customized_config"  | sed 's/,$//' | sed 's/^,//')
    echo "customized_config: $customized_config"
    default_configs=$customized_config
  fi

  /home/admin/oceanbase/bin/observer --appname ${KB_CLUSTER_COMP_NAME} \
    --cluster_id $((${COMPONENT_INDEX}+1)) --zone $ZONE_NAME \
    -I ${KB_POD_IP} \
    -d ${OB_HOME_DIR}/store/ \
    -l ${loglevel} -o config_additional_dir=${OB_HOME_DIR}/store/etc,${default_configs}
}

function start_observer_with_exsting_configs {
  # Start observer w/o any flags
  /home/admin/oceanbase/bin/observer
}

function is_recovering {
  # test whether the config folders and files are empty or not
  # if [ -z "$(ls -A /home/admin/data-file)" ]; then
  #   echo "False"
  # else
  #   echo "True"
  # fi
  if [ ! -d "/home/admin/workdir/etc" ]; then
    echo "False"
  else
    echo "True"
  fi
}

function others_running {
  local alive_count=0
  for i in $(seq 0 $(($KB_REPLICA_COUNT-1))); do
    if [ $i -eq $ORDINAL_INDEX ]; then
      continue
    fi
    nc -z ${IP_LIST[$i]} $COMP_MYSQL_PORT
    if [ $? -ne 0 ]; then
      continue
    fi
    # If at least one server is up, return True
    conn_remote_w_port ${IP_LIST[$i]} $COMP_MYSQL_PORT "show databases" &> /dev/null
    if [ $? -eq 0 ]; then
      alive_count=$(($alive_count+1))
    fi
  done
  # if more than half of the servers are up, return True
  if [ $(($alive_count*2)) -gt ${KB_REPLICA_COUNT} ]; then
    echo "True"
    return
  fi
  echo "False"
  return
}

function bootstrap_obcluster {
  for i in $(seq 0 $(($KB_REPLICA_COUNT-1))); do
    local replica_hostname="${KB_CLUSTER_COMP_NAME}-${i}"
    local replica_ip=""
    while true; do
      replica_ip=$(nslookup $replica_hostname.$SVC_NAME | tail -n 2 | grep -P "(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})" --only-matching)
      # check if the IP is empty
      if [ -z "$replica_ip" ]; then
        echo "nslookup $replica_hostname.$SVC_NAME failed, wait for a moment..."
        sleep $WAIT_K8S_DNS_READY_TIME
      else
        echo "nslookup $replica_hostname.$SVC_NAME success, IP: $replica_ip"
        break
      fi
    done
    echo "hostname.svc:" $replica_hostname.$SVC_NAME "ip:" $replica_ip
    while true; do
      nc -z $replica_ip $COMP_MYSQL_PORT
      if [ $? -ne 0 ]; then
        echo "Replica $replica_hostname.$SVC_NAME is not up yet"
        sleep $WAIT_SERVER_SLEEP_TIME
      else
        echo "Replica $replica_hostname.$SVC_NAME is up"
        break
      fi
    done
  done

  echo "SET SESSION ob_query_timeout=1000000000;"
  conn_local_w_port $COMP_MYSQL_PORT "SET SESSION ob_query_timeout=1000000000;"
  echo "ALTER SYSTEM BOOTSTRAP ${ZONE_SERVER_LIST};"
  conn_local_w_port $COMP_MYSQL_PORT  "ALTER SYSTEM BOOTSTRAP ${ZONE_SERVER_LIST};"

  if [ $? -ne 0 ]; then
    # Bootstrap failed, clean the dirs and retry
    echo "Bootstrap failed, please check the store"
    exit 1
  fi

  # Wait for the server to be ready
  sleep $WAIT_SERVER_SLEEP_TIME

  conn_local_w_port $COMP_MYSQL_PORT "show databases"

  conn_local_obdb_w_port $COMP_MYSQL_PORT "SELECT * FROM DBA_OB_SERVERS\G"

  create_primary_secondry_tenants
}

function add_server {
  echo "add server"
  echo "IP_LIST: ${IP_LIST[*]}"
  # Choose a running server and send the add server request
  for i in $(seq 0 $(($KB_REPLICA_COUNT-1))); do
    if [ $i -eq $ORDINAL_INDEX ]; then
      continue
    fi
    until conn_remote_obdb_w_port ${IP_LIST[$i]} $COMP_MYSQL_PORT "SELECT * FROM DBA_OB_SERVERS\G"; do
      echo "the cluster has not been bootstrapped, wait for them..."
      sleep 10
    done

    local RETRY_MAX=5
    local retry_times=0
    until conn_remote_w_port ${IP_LIST[$i]} $COMP_MYSQL_PORT "ALTER SYSTEM ADD SERVER '${KB_POD_IP}:${COMP_RPC_PORT}' ZONE '${ZONE_NAME}'"; do
      echo "Failed to add server ${KB_POD_IP}:$COMP_RPC_PORT to the cluster, retry..."
      retry_times=$(($retry_times+1))
      sleep $((3*${retry_times}))
      if [ $retry_times -gt ${RETRY_MAX} ]; then
        echo "Failed to add server ${KB_POD_IP}:$COMP_RPC_PORT to the cluster finally, exit..."
        exit 1
      fi
    done

    until [ -n "$(conn_remote_obdb_w_port ${IP_LIST[$i]} $COMP_MYSQL_PORT "SELECT * FROM DBA_OB_SERVERS WHERE SVR_IP = '${KB_POD_IP}' and STATUS = 'ACTIVE' and START_SERVICE_TIME IS NOT NULL")" ]; do
      echo "Wait for the server to be ready..."
      sleep 10
    done

    echo "Add the server to zone successfully"
    break
  done
}

function check_if_ip_changed {
  if [ -z "$(cat /home/admin/data-file/etc/observer.conf.bin | grep ${KB_POD_IP})" ]; then
    echo "Changed"
  else
    echo "Not Changed"
  fi
}

function delete_inactive_servers {
  echo "delete inactive server"
  echo "IP_LIST: ${IP_LIST[*]}"
  echo "sleep for a while before fetch INACTIVE servers"
  ## default lease time is 10s, so sleep 20s to make sure the server is inactive
  sleep 20
  for i in $(seq 0 $(($KB_REPLICA_COUNT-1))); do
    if [ $i -eq $ORDINAL_INDEX ]; then
      continue
    fi
    inactive_ips=($(conn_remote_batch_w_port ${IP_LIST[$i]} $COMP_MYSQL_PORT  "SELECT SVR_IP FROM DBA_OB_SERVERS WHERE STATUS = 'INACTIVE'" | tail -n +2))
    if [ ${#inactive_ips[@]} -eq 0 ]; then
      echo "No inactive servers"
      continue
    fi
    echo "Inactive IPs: ${inactive_ips[*]}"
    for ip in ${inactive_ips[*]}; do
      svr="$ip:$COMP_RPC_PORT"
      echo "ALTER SYSTEM DELETE SERVER '$svr'"
      conn_remote_w_port ${IP_LIST[$i]} $COMP_MYSQL_PORT "ALTER SYSTEM DELETE SERVER '$svr'" || true
    done
    break
  done
  echo "Finish deleting inactive servers"
}


function create_ready_flag {
  touch /tmp/ready
}

function create_primary_secondry_tenants {
  # create tenants if env TENANT_NAME is set
  if [ -z "$TENANT_NAME" ]; then
    return
  fi

  # get ordinal of current pod, start from 0
  ordinal_index=$(echo $KB_POD_NAME | awk -F '-' '{print $(NF-1)}')
  # if not equal to 0, create secondary tenant
  if [ $ordinal_index -ne 0 ]; then
    return
  fi

  create_primary_tenant "$TENANT_NAME"
}

function create_primary_tenant {
  tenant_name=$1
  echo "create resource unit and pool for tenant ${tenant_name}"
  conn_local_w_port $COMP_MYSQL_PORT "CREATE RESOURCE UNIT IF NOT EXISTS unit_for_${tenant_name} MAX_CPU ${TENANT_CPU}, MEMORY_SIZE = '${TENANT_MEMORY}', LOG_DISK_SIZE = '${TENANT_DISK}';"
  conn_local_w_port $COMP_MYSQL_PORT  "CREATE RESOURCE POOL IF NOT EXISTS pool_for_${tenant_name} UNIT = 'unit_for_${tenant_name}', UNIT_NUM = 1;"

  echo "create tenant ${tenant_name}"
  conn_local_w_port $COMP_MYSQL_PORT "SET SESSION ob_query_timeout=1000000000; CREATE TENANT IF NOT EXISTS ${tenant_name} RESOURCE_POOL_LIST=('pool_for_${tenant_name}') SET ob_tcp_invited_nodes='%';"

  echo "alter system archive log"
  conn_local_w_port $COMP_MYSQL_PORT "ALTER SYSTEM ARCHIVELOG;"

  echo "check tenant ${tenant_name} exists"
  conn_local_w_port $COMP_MYSQL_PORT "SELECT count(*) FROM oceanbase.DBA_OB_TENANTS where tenant_name = '${tenant_name}';"
  conn_local_w_port $COMP_MYSQL_PORT "SELECT TENANT_NAME, TENANT_TYPE, TENANT_ROLE, SWITCHOVER_STATUS FROM oceanbase.DBA_OB_TENANTS\G"

  conn_local_w_port $COMP_MYSQL_PORT "SELECT SVR_IP, SVR_PORT FROM oceanbase.DBA_OB_TENANTS as t, oceanbase.DBA_OB_UNITS as u, oceanbase.DBA_OB_UNIT_CONFIGS as uc WHERE t.tenant_name = '${tenant_name}' and t.tenant_id = u.tenant_id and u.unit_id = uc.UNIT_CONFIG_ID and uc.name = 'unit_for_${tenant_name}' limit 1\G" > /tmp/tenant_info
  svr_ip_list=$(cat /tmp/tenant_info | awk '/SVR_IP/{print $NF}')

  echo "svr_ip_list: ${svr_ip_list[*]}"
  create_rep_user "$TENANT_NAME" ${svr_ip_list[0]}


  if [ $OB_CLUSTERS_COUNT -le 1 ]; then
    return
  fi
  create_secondary_tenant "$TENANT_NAME" "${TENANT_NAME}" ${svr_ip_list[0]}
}

function create_rep_user {
  local tenant_name=$1
  local ip=$2
  local user_name=${REP_USER}
  local user_passwd=${REP_PASSWD}

  echo "create user ${user_name} for tenant ${tenant_name}"
  conn_remote_as_tenant_w_port $ip $COMP_MYSQL_PORT $tenant_name "CREATE USER ${user_name} IDENTIFIED BY '${user_passwd}';"
  conn_remote_as_tenant_w_port $ip $COMP_MYSQL_PORT $tenant_name "GRANT SELECT ON oceanbase.* TO ${user_name};"
  conn_remote_as_tenant_w_port $ip $COMP_MYSQL_PORT $tenant_name "SET GLOBAL ob_tcp_invited_nodes='%';"
}

function create_secondary_tenant {
  echo "create secondary tenant"
  local primry_tenant_name=$1
  local secondary_tenant_name=$2
  local primary_tenant_rep_user=${REP_USER}
  local primary_tenant_rep_passwd=${REP_PASSWD}
  local tenant_ip=$3
  # get access points
  conn_remote_as_tenant_w_port $tenant_ip $COMP_MYSQL_PORT ${primry_tenant_name} "SELECT concat_ws(':', svr_ip, sql_port) as AP from oceanbase.DBA_OB_ACCESS_POINT\G" > /tmp/access_point
  svr_ip_list=$(cat /tmp/access_point | awk '/AP/{print $NF}')
  # echo "svr_ip_list: ${svr_ip_list[*]}"
  OLD_IFS=$IFS
  IFS=$' \t\n'
  svr_ip_array=($svr_ip_list)
  svr_ports_array=($svr_ports_list)
  IFS=$OLD_IFS

  echo "svr_ip_array: ${svr_ip_array[*]}"

  delim=';'
  printf -v joined_string "%s$delim" "${svr_ip_array[@]}"
  echo "joined_string: $joined_string"

    # get ip list of 0-th pod of other components
  local secondary_tenant_ip=()
  local secondary_tenant_port=()
  components_prefix=$(echo "${KB_CLUSTER_COMP_NAME}" | awk -F'-' '{NF--; print}' OFS='-')
  for i in $(seq 1 $(($OB_CLUSTERS_COUNT-1))); do
    next_comp_name="${components_prefix}-${i}"
    local replica_hostname="${next_comp_name}-0.${next_comp_name}-headless.${KB_NAMESPACE}.svc"
    local replica_ip=""
    while true; do
      replica_ip=$(nslookup $replica_hostname | tail -n 2 | grep -P "(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})" --only-matching)
      # check if the IP is empty
      if [ -z "$replica_ip" ]; then
        echo "nslookup $replica_hostname failed, wait for a moment..."
        sleep $WAIT_K8S_DNS_READY_TIME
      else
        echo "nslookup $replica_hostname success, IP: $replica_ip"
        break
      fi
    done
    secondary_tenant_ip+=("$replica_ip")
    secondary_tenant_port+=${MYSQL_PORTS[$i]}
  done
  echo "secondary ip list: ${secondary_tenant_ip[*]}"

  # for each ip in ip list, create secondary tenant
  for ((i=0; i<${#secondary_tenant_ip[@]}; i++)); do
    echo "create resource unit and pool for tenant ${secondary_tenant_name}"
    echo "remote ip: ${ip}"
    local ip=${secondary_tenant_ip[$i]}
    local port=${secondary_tenant_port[$i]}
    # wait until the server is up
    until conn_remote_w_port $ip $port "SELECT * FROM oceanbase.DBA_OB_SERVERS\G"; do
      echo "the cluster has not been bootstrapped, wait for them..."
      retry_times=$(($retry_times+1))
      sleep 10
    done

    echo $ip "CREATE RESOURCE UNIT IF NOT EXISTS unit_for_${secondary_tenant_name}"
    conn_remote_w_port $ip $port "CREATE RESOURCE UNIT IF NOT EXISTS unit_for_${secondary_tenant_name} MAX_CPU ${TENANT_CPU}, MEMORY_SIZE = '${TENANT_MEMORY}', LOG_DISK_SIZE = '${TENANT_DISK}';"
    echo $ip "CREATE RESOURCE POOL IF NOT EXISTS pool_for_${secondary_tenant_name} UNIT = 'unit_for_${secondary_tenant_name}', UNIT_NUM = 1;"
    conn_remote_w_port $ip $port "CREATE RESOURCE POOL IF NOT EXISTS pool_for_${secondary_tenant_name} UNIT = 'unit_for_${secondary_tenant_name}', UNIT_NUM = 1;"

    echo "create tenant ${secondary_tenant_name}"
    echo $ip "SET SESSION ob_query_timeout=1000000000; CREATE STANDBY TENANT IF NOT EXISTS ${secondary_tenant_name} LOG_RESTORE_SOURCE ='SERVICE=${joined_string} USER=${primary_tenant_rep_user}@${primry_tenant_name} PASSWORD=${primary_tenant_rep_passwd}' RESOURCE_POOL_LIST=('pool_for_${secondary_tenant_name}');"

    local RETRY_MAX=5
    local retry_times=0
    until conn_remote_w_port $ip $port "SET SESSION ob_query_timeout=1000000000; CREATE STANDBY TENANT IF NOT EXISTS ${secondary_tenant_name} LOG_RESTORE_SOURCE ='SERVICE=${joined_string} USER=${primary_tenant_rep_user}@${primry_tenant_name} PASSWORD=${primary_tenant_rep_passwd}' RESOURCE_POOL_LIST=('pool_for_${secondary_tenant_name}');"; do
      conn_remote_w_port $ip $port "DROP TENANT IF EXISTS ${secondary_tenant_name} FORCE;"
      echo "Failed to create standby tenant, retry..."
      retry_times=$(($retry_times+1))
      sleep $((3*${retry_times}))
      if [ $retry_times -gt ${RETRY_MAX} ]; then
        echo "Failed to create standby tenant ${secondary_tenant_name} on ${ip}, exit..."
        break
      fi
    done

    echo $ip "ALTER SYSTEM ARCHIVELOG;"
    conn_remote_w_port $ip $port "ALTER SYSTEM ARCHIVELOG;"

    echo "check tenant ${secondary_tenant_name} exists"
    conn_remote_w_port $ip $port "SELECT count(*) FROM oceanbase.DBA_OB_TENANTS where tenant_name = '${secondary_tenant_name}';"
    conn_remote_w_port $ip $port "SELECT TENANT_NAME, TENANT_TYPE, TENANT_ROLE, SWITCHOVER_STATUS FROM oceanbase.DBA_OB_TENANTS\G"
  done
}

function wait_for_observer_start {
  echo "check if the server has been initialized"
  wait_time=30  # wait up to 30 seconds
  elapsed_time=0
  filename=$OB_HOME_DIR/log/observer.log
  while [ $elapsed_time -lt $wait_time ]; do
    if grep -q 'success to start root service monitor' $filename; then
      echo "oceanbase has been initialized successfully"
      break
    else
      echo "oceanbase is not initialized yet, wait for it..."
      sleep 1
      elapsed_time=$((elapsed_time + 1))
    fi
  done

  if [ $elapsed_time -ge $wait_time ]; then
    echo "Failed to init server ${KB_POD_IP}:$COMP_RPC_PORT exit..."
    exit 1
  fi
}
