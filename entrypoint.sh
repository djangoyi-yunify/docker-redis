#!/bin/sh
set -a
#DATA_DIR=${DATA_DIR:-"/data"}
DATA_DIR=${DATA_DIR:-"/data/redis"}
REDIS_CONF_FILE="${DATA_DIR}/redis.conf"
SENTINEL_CONF_FILE="${DATA_DIR}/sentinel.conf"

common_operation() {
    mkdir -p "${DATA_DIR}/logs"
    mkdir -p "${DATA_DIR}/tls"
    chown -R redis.redis "$DATA_DIR"
    chmod -R 700 "${DATA_DIR}"
    find "${DATA_DIR}" -type f -exec chmod 600 {} +
}


execGosuRedis() {
  if [ "$(id -u)" = '0' ]; then
    exec su-exec redis "$@" --protected-mode no
  else
    exec "$@" --protected-mode no
  fi
}

start_redis() {
    REDIS_PASSWORD="$(getPassword)"
    if  [ -n "${REDIS_PASSWORD}" ] ;then
      authOpt="--masterauth \"${REDIS_PASSWORD}\" --requirepass \"${REDIS_PASSWORD}\""
    fi
    if [[ "${SETUP_MODE}" == "cluster" ]]; then
        echo "Starting redis service in cluster mode....."
        execGosuRedis redis-server "$REDIS_CONF_FILE" $authOpt
    elif [[ "${SETUP_MODE}" == "sentinel" ]]; then
        echo "Starting redis service in sentinel mode....."
        execGosuRedis redis-sentinel "$SENTINEL_CONF_FILE" $authOpt
    elif [[ "${SETUP_MODE}" == "benchmark" ]]; then
      echo "Starting redis benchmark ....."
      redis-benchmark "$@"
    else
        echo "Starting redis service in standalone mode....."
        execGosuRedis redis-server "$REDIS_CONF_FILE" $authOpt
    fi
}

main_function() {
    while [[ "$(appctl getRunMode)" == "rescue" ]]; do
        sleep 2
    done
    appctl retry 120 1 0 appctl checkMyIp || {
      echo "------- ERROR: Get My IP FALT -------"
      return 1
    }
    sleep 10
    common_operation
    appctl buildRedisConfig
    appctl startCron
    start_redis "$@"
}

main_function "$@"
