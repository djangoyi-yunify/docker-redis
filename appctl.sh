#!/bin/sh
PORT=${PORT:-"6379"}
TLS_PORT=${TLS_PORT:-"0"}
TLS_CLUSTER=${TLS_CLUSTER:-"no"}
REDIS_CONF_DIR="/etc/redis"
DATA_DIR="/data/redis"
REDIS_TLS_DIR=${DATA_DIR}/tls
EXTERNAL_CONFIG_FILE="${REDIS_CONF_DIR}/external.conf.d/redis-external.conf"
MODE_FILE="${REDIS_CONF_DIR}/external.conf.d/mode"
ACL_FILE_CONF=${DATA_DIR}/aclfile.conf
EXTERNAL_ACL_FILE=${REDIS_CONF_DIR}/acl.conf.d/aclfile.conf
EXTERNAL_TLS_DIR=${REDIS_CONF_DIR}/tls
REDIS_CONF_FILE=${DATA_DIR}/redis.conf
REDIS_EXTERNAL_CONFIG_FILE="${DATA_DIR}/redis-external.conf"
REDIS_LOGS_FILE="${DATA_DIR}/logs/redis-server.log"
REDIS_NODES_CONF_FILE=${DATA_DIR}/nodes.conf
SENTINEL_CONF_FILE=${DATA_DIR}/sentinel.conf
DISABLE_CMDS=$(echo "$DISABLE_CMDS" | tr 'a-z' 'A-Z')
ENDPOINT_LIST=${ENDPOINT_LIST:-""}
ENDPOINT_INFO="$(echo "$ENDPOINT_LIST" | xargs -n1 | grep -E "^$HOSTNAME[.:]")"
DYNAMIC_PORT="$(echo $ENDPOINT_INFO | cut -f 2 -d ":")"
DYNAMIC_TLS_PORT="$(echo $ENDPOINT_INFO | cut -f 3 -d ":")"
PORT=${DYNAMIC_PORT:-"$PORT"}
TLS_PORT=${DYNAMIC_TLS_PORT:-"$TLS_PORT"}
REDIS_PASSWORD="$(getPassword)"


retry() {
  local tried=0
  local maxAttempts=$1
  local interval=$2
  local stopCode=$3
  shift 3
  local cmd="${@}"
  local retCode=0
  while [ $tried -lt $maxAttempts ]; do
    $cmd && return 0 || {
      retCode=$?
      if [ "$retCode" = "$stopCode" ]; then
        log "'$cmd' returned with stop code $stopCode. Stopping ..."
        return $retCode
      fi
    }
    sleep "$interval"
    tried=$((tried+1))
  done
  echo "'$cmd' still returned errors after $tried attempts. Stopping ..."
  return $retCode
}

rotate() {
  local maxFilesCount=5
  for path in "$@"; do
    for i in $(seq 1 $maxFilesCount | tac); do
      if [ -f "${path}.$i" ]; then mv ${path}.$i ${path}.$(($i+1)); fi
    done
    if [ -f "$path" ]; then cp $path ${path}.1; fi
  done
}

flush() {
  local targetFile mode=600
  if [[ "$1" == "--mode" || "$1" == "-m" ]]; then
    mode=$2 && shift 2
  fi
  targetFile=$1
  if [ -n "$targetFile" ]; then
    rotate "$targetFile"
    cat > "$targetFile" -
  else
    cat -
  fi
  chown redis.redis "$targetFile"
  chmod "$mode" "$targetFile"
}

buildLogFile() {
  local externalLogFile
  if [[ ! -e "$EXTERNAL_CONFIG_FILE" ]];then
    echo "$REDIS_LOGS_FILE"
    return
  fi

  externalLogFile=$(sed -n 's/^\s*logfile\s\+//p' "$EXTERNAL_CONFIG_FILE")
  if [[ -z "$externalLogFile" ]];then
    echo "$REDIS_LOGS_FILE"
    return
  fi

  externalLogFile=$(echo "$externalLogFile" | sed 's/"\(.*\)"/\1/g;s/'\(.*\)'/\1/g' | tail -1)
  if [[ "$externalLogFile" != "stdout" ]] && [[ -n "$externalLogFile" ]]; then
    echo "$REDIS_LOGS_FILE"
    return
  fi
}

getLoadStatus() {
  runRedisCmd Info Persistence | grep "^loading:0" > /dev/null
}

getRunMode(){
  if [[ -e "$MODE_FILE" ]]; then
    cat "$MODE_FILE"
  fi
}

checkMyIp(){
  [[ -n "$(hostname -i)" ]]
}

buildDisableCommand() {
  if [ "${SETUP_MODE}" != "sentinel" ] && [ " $DISABLE_CMDS " == *" $1 "* ]; then
      echo -n "${1}.${CLUSTER_NAME}.${NAME_SPACE}" | sha1sum | sed "s/-\s*$//g"
  else
      echo -n "${1}"
  fi
}

updateRedisTls() {
  local tls_files=""
  for filename in redis.crt redis.key ca.crt redis.dh tls.key tls.crt; do
    [ -f "${EXTERNAL_TLS_DIR}/${filename}" ] && rm "$REDIS_TLS_DIR/${filename}" -f
    if [ -f "${EXTERNAL_TLS_DIR}/${filename}" ]; then
      cp "${EXTERNAL_TLS_DIR}/${filename}" "$REDIS_TLS_DIR/${filename}"
      tls_files="${tls_files} $REDIS_TLS_DIR/${filename}"
    fi
  done
  chown -R redis.redis "$REDIS_TLS_DIR"
  chmod 700 "$REDIS_TLS_DIR"
  for f in $tls_files; do
    chmod 600 "$f"
  done
}

buildRedisConfig() {
  if  [ -n "${REDIS_PASSWORD}" ] ;then
    echo "user default on >${REDIS_PASSWORD} ~* &* +@all" | flush "$ACL_FILE_CONF"
  else
    echo "user default on nopass ~* &* +@all" | flush "$ACL_FILE_CONF"
  fi
  if [ "${SETUP_MODE}" == "sentinel" ]; then
    if [[ -f "$SENTINEL_CONF_FILE" ]] &&  grep -qE '^sentinel monitor' "$SENTINEL_CONF_FILE" ; then
      rotate "$SENTINEL_CONF_FILE"
      sed -i "/^sentinel \(monitor\|known-replica\|known-sentinel\)\|^$/d" "$SENTINEL_CONF_FILE"
      echo "sentinel monitor $CLUSTER_NAME $(getReplicaMaster) 2" >> "$SENTINEL_CONF_FILE"
    else
      echo "Setting up redis in sentinel mode"
      {
        echo 'port 26379'
        echo "bind 0.0.0.0"
        echo 'daemonize no'
        echo "logfile \"\""
        echo "dir \"${DATA_DIR}\""
        echo 'acllog-max-len 128'
        echo 'SENTINEL deny-scripts-reconfig yes'
        echo 'SENTINEL resolve-hostnames no'
        echo 'SENTINEL announce-hostnames no'
        #echo "masterauth \"${REDIS_PASSWORD}\""
        #echo "requirepass \"${REDIS_PASSWORD}\""
        echo "aclfile $ACL_FILE_CONF"
        [[ "$(uname -m)" == aarch64  ]] && echo "ignore-warnings ARM64-COW-BUG"
      } | flush "$SENTINEL_CONF_FILE"
    fi
  else
    local replica
    if [[ "${SETUP_MODE}" == "replica" ]] && [[ -e "$REDIS_CONF_FILE" ]];then
      replica=$(createReplicaof)
    fi
    updateRedisTls
    [[ -f "$EXTERNAL_ACL_FILE" ]] && sed '/^user default /d' "$EXTERNAL_ACL_FILE" >> "$ACL_FILE_CONF"
    {
      if [[ -f "${EXTERNAL_CONFIG_FILE}"  ]]; then
        sed '/^logfile /d' "${EXTERNAL_CONFIG_FILE}" | flush "${REDIS_EXTERNAL_CONFIG_FILE}"
        echo "include ${REDIS_EXTERNAL_CONFIG_FILE}"
      fi
      echo "bind 0.0.0.0"
      echo "port ${PORT}"
      echo "tls-port ${TLS_PORT}"
      echo "aof-rewrite-incremental-fsync yes"
      echo "appendfilename \"appendonly.aof\""
      echo "appendonly yes"
      echo "auto-aof-rewrite-min-size 64mb"
      echo "auto-aof-rewrite-percentage 60"
      echo "daemonize no"
      echo "dir \"${DATA_DIR}\""
      echo "save \"\""
      echo "logfile \"$(buildLogFile)\""
      #echo "masterauth \"${REDIS_PASSWORD}\""
      #echo "requirepass \"${REDIS_PASSWORD}\""
      [[ -f "$ACL_FILE_CONF" ]] && echo "aclfile $ACL_FILE_CONF"
      [[ -f "${REDIS_TLS_DIR}/tls.crt" ]] && echo "tls-cert-file \"${REDIS_TLS_DIR}/tls.crt\""
      [[ -f "${REDIS_TLS_DIR}/redis.crt" ]] && echo "tls-cert-file \"${REDIS_TLS_DIR}/redis.crt\""
      [[ -f "${REDIS_TLS_DIR}/tls.key" ]] && echo "tls-key-file \"${REDIS_TLS_DIR}/tls.key\""
      [[ -f "${REDIS_TLS_DIR}/redis.key" ]] && echo "tls-key-file \"${REDIS_TLS_DIR}/redis.key\""
      [[ -f "${REDIS_TLS_DIR}/ca.crt" ]] && echo "tls-ca-cert-file \"${REDIS_TLS_DIR}/ca.crt\""
      [[ -f "${REDIS_TLS_DIR}/redis.dh" ]] && echo "tls-dh-params-file \"${REDIS_TLS_DIR}/redis.dh\""
      updateDisableCmds
      [[ "$(uname -m)" == aarch64  ]] && echo "ignore-warnings ARM64-COW-BUG"
    } | flush "$REDIS_CONF_FILE"
    if [[ "${SETUP_MODE}" == "cluster" ]]; then
      {
        echo "cluster-enabled yes"
        echo "tls-cluster ${TLS_CLUSTER}"
        echo "cluster-require-full-coverage no"
        echo "cluster-migration-barrier 5000"
        echo "cluster-allow-replica-migration no"
        echo "cluster-config-file \"$REDIS_NODES_CONF_FILE\""
      } >> "$REDIS_CONF_FILE"

      if [ ! -e "$REDIS_NODES_CONF_FILE" ];then
        createNodesConf
      fi
    elif [[ "${SETUP_MODE}" == "replica" ]];then
      echo "$replica" >> $REDIS_CONF_FILE
    fi
  fi
}

startCron() {
  if [ "${SETUP_MODE}" != "sentinel" ] && [ "$LOG_OUTPUT" == "logfile" ]; then
    crond -b
    echo
  fi
}

confPasswdUpdate(){
  local configFile=$REDIS_CONF_FILE
  [[ "${SETUP_MODE}" == "sentinel" ]] && configFile="$SENTINEL_CONF_FILE"
  #sed -i '/^\(requirepass\|masterauth\) /d' "$configFile"
  #if [[ -n "${REDIS_PASSWORD}" ]] ;then
    #{
      #echo "requirepass \"${REDIS_PASSWORD}\""
      #echo "masterauth \"${REDIS_PASSWORD}\""
    #} >> $configFile
  #fi
}

getConfPassword() {
  if [[ "${SETUP_MODE}" == "sentinel" ]] ;then
    sed -n 's/^requirepass\s\+"\(.*\)"/\1/p' "$SENTINEL_CONF_FILE" | tail -1
  else
    sed -n 's/^requirepass\s\+"\(.*\)"/\1/p' "$REDIS_CONF_FILE" | tail -1
  fi
}

createReplicaof(){
    masterHost=$(getReplicaMaster| sed 's/^\s*\|\s*$//g')
    if [[ -n "$masterHost" ]];then
      echo "replicaof $masterHost"
    fi
}

getReplicaMaster() {
  if [[ "${SETUP_MODE}" != "sentinel" ]] && [[ "${SETUP_MODE}" != "replica" ]]; then
    return
  fi
  local redisHostname redisPort role
  local masterList=""
  for endpoint in ${ENDPOINT_LIST}; do 
    [[ "${endpoint}" == "${HOSTNAME}."* ]] && continue
    redisPort="${PORT}"
    redisHostname="${endpoint%%:*}"
    redisPort="$(echo "$endpoint" | cut -d: -f2)"
    role=$(runRedisCmd --timeout 1 --ip $redisHostname --port $redisPort role | head -1)
    if [[ "$role" == "master" ]]; then
      masterList="$masterList $endpoint"
    fi
  done
  local masterCount="$(echo $masterList | xargs -n1 | wc -l)" 
  if [[ "$masterCount" == "1" ]]; then
    redisIP=$(resolveA ${masterList%%:*})
    echo "$redisIP $(echo "$masterList" | cut -d: -f2)"
    break
  fi
}


runRedisCmd() {
  local timeoutOpt redisIp redisPort=${PORT} retCode=0 authOpt="" result passwd
  redisIp="127.0.0.1"
  #passwd=$(getConfPassword)
  passwd=$(getPassword)
  [[ "${SETUP_MODE}" == "sentinel" ]] && redisPort=26379
  while :
    do
    if [[ "$1" == "--ip" || "$1" == "-h" ]]; then
      redisIp=$2 && shift 2
    elif [[ "$1" == "--port" || "$1" == "-p" ]]; then
      redisPort=$2 && shift 2
    elif [[ "$1" == "--timeout" ]]; then
      timeoutOpt="timeout ${2}s" && shift 2
    elif [[ "$1" == "--password" || "$1" == "-a" ]]; then
      passwd=$2 && shift 2
    else
      break
    fi
  done
  [ -n "$passwd" ] && authOpt="--no-auth-warning -a $passwd"
  result="$($timeoutOpt redis-cli $authOpt -h $redisIp -p $redisPort "$@" 2>&1 )" || retCode=$?
  if [ "$retCode" != 0 ] || [[ "$result" == *ERR* ]]; then
    echo "ERROR failed to run redis command \"$*\" ($retCode): $result." && retCode=$REDIS_COMMAND_EXECUTE_FAIL_ERR
  else
    echo "$result"
  fi
  return "$retCode"
}


aclLoad() {
  local redispasswd aclContent aclCmd=ACL
  redispasswd=$(getConfPassword)
  while :
    do
    if [[ "$1" == "--requirepass" ]] ; then
      REDIS_PASSWORD=$2
      shift 2
    elif [[ "$1" == "--acl-content" ]] ; then
      aclContent="$(echo "$2" | base64 -d)"
      shift 2
    else
      break
    fi
  done

  if  [[ -n "${REDIS_PASSWORD}" ]] ;then
    echo "user default on >${REDIS_PASSWORD} ~* &* +@all" | flush "$ACL_FILE_CONF"
  else
    echo "user default on nopass ~* &* +@all" | flush "$ACL_FILE_CONF"
  fi

  if [[ "${SETUP_MODE}" != "sentinel" ]] ;then
    if [[ -n "${aclContent}" ]] ; then
      echo "${aclContent}" | sed '/^user default /d' >> "$ACL_FILE_CONF"
    else [[ -f "$EXTERNAL_ACL_FILE" ]]
      sed '/^user default /d' "$EXTERNAL_ACL_FILE" >> "$ACL_FILE_CONF"
    fi
  fi
  aclCmd=$(buildDisableCommand "ACL")
  runRedisCmd -a "$redispasswd" "$aclCmd" load
  if [[ "${SETUP_MODE}" != "sentinel" ]] ; then
    local config=CONFIG
    config=$(buildDisableCommand "CONFIG")
    {
      echo "$config set masterauth \"${REDIS_PASSWORD}\""
      echo "$config set requirepass \"${REDIS_PASSWORD}\""
    } | runRedisCmd -a "${REDIS_PASSWORD}"
  fi
  confPasswdUpdate
}

getRunId() {
  local host="$1"
  if [[ -z "$host" ]];then
    host="$(hostname -f | sed "s/^\(.*\.svc\)\(\..*\)$/\1/g")"
  fi
  echo -n "$host" |sha1sum|cut -f 1 -d " "
}

createNodesConf() {
  local runId clusterPort redisPort=${PORT} redisHostname=""
  if [[ "$TLS_CLUSTER" == "yes" ]] ;then
    redisPort="$TLS_PORT"
  fi
  clusterPort=$((redisPort+10000))
  runId="$(getRunId)"
  {
    if [[ "$CLUSTER_HOSTNAME" == "hostname" ]] ;then
      redisHostname="$(hostname -f | sed 's/\.svc\..*$/.svc/g')"
      echo "$runId $(hostname -i):$redisPort@$clusterPort,$redisHostname myself,master - 0 0 0 connected"
    else
      echo "$runId $(hostname -i):$redisPort@$clusterPort myself,master - 0 0 0 connected"
    fi
    echo "vars currentEpoch 0 lastVoteEpoch 0"
  } | flush "$REDIS_NODES_CONF_FILE"
}


updateDisableCmds() {
  local disableCmd
  [ -z "$DISABLE_CMDS" ] && return
  for disableCmd in $DISABLE_CMDS; do
    echo "rename-command ${disableCmd} $(buildDisableCommand $disableCmd)"
  done
}

resolveA() {
  if [[ "$1" == "$HOSTNAME."*  ]];then
    hostname -i
  else
    ping "${1}" -c 1 -w 1 | sed '1{s/[^(]*(//;s/).*//;q}'
  fi
}

if [[ "-x" == "$1" ]] ;then
  set -x
  shift 1
fi

cmd=$1
shift 1
$cmd "$@"
