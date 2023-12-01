#!/bin/sh
TIMEOUT=600
check_redis_health() {
  local runMode role roleResponse
  runMode=$(appctl getRunMode)
  [[ "$runMode" == "nocheck" ]] && return
  [[ "$runMode" == "rescue" ]] && return

  if [[ "$SETUP_MODE" == "sentinel" ]]; then
    [[ "$(pgrep redis-sentinel)" != "1" ]] && return
  else
    [[ "$(pgrep redis-server)" != "1" ]] && return
    if ! appctl getLoadStatus ; then
      uptime_in_seconds="$(appctl runRedisCmd $authOpt info server | sed -n  's/uptime_in_seconds:\([0-9]*\)\r/\1/p')"
      if [[ 86400 -lt $uptime_in_seconds ]]; then
        return 1
      fi
      return 0
    fi
  fi

  appctl runRedisCmd ping
  if [[ "$SETUP_MODE" == "replica" ]] ; then
    roleResponse="$(appctl runRedisCmd role)"
    [[ "$(echo "$roleResponse"| sed -n 1p)" != "slave" ]] && return
    if [[ "$(echo "$roleResponse"| sed -n '$p')" == "-1" ]]; then
      if [[ -n "$(appctl findMaster| sed 's/^\s*\|\s*$//g')" ]]; then
        echo "replicaof error: $(echo $roleResponse | xargs)"
        return 1
      fi
    else
      redisIP="$(echo "$roleResponse"| sed -n 2p)"
      redisPort="$(echo "$roleResponse"| sed -n 3p)"
      if [[ "$(appctl runRedisCmd --ip "$redisIP" --port "$redisPort" role | sed -n 1p)" != "master" ]]; then
        echo "replicaof error:  $redisIP:$redisPort not master"
        return 1
      fi
    fi
  fi
}

set -eo pipefail
check_redis_health

