#!/usr/bin/env bash
set -euo pipefail

API_URL=${TOXIPROXY_API:-http://127.0.0.1:8474}
PROXY=${TOXIPROXY_PROXY:-edge-a-to-b-mqtt}

usage() {
  cat <<'EOF'
Usage: toxiproxy-toxics.sh <command> [scenario]

Commands:
  list                       List toxics currently configured on the proxy.
  apply <scenario>           Create or refresh the toxic for the scenario.
  temporary <scenario> <seconds>
                            Toggle the toxic on/off every <seconds> until interrupted.
  remove <scenario>          Remove the toxic entirely.
  help                       Show this message.

Scenarios:
  latency        Adds 500 ms latency with ±200 ms jitter on the upstream path.
  bandwidth      Caps upstream bandwidth at 128 KB/s to force backpressure.
  timeout        Drops 15% of upstream packets by introducing timeouts.
  reset          Immediately resets upstream connections to test retry logic.
  down           Stop proxy forwarding (simulating a down connection)
  slow-close     Delays downstream socket close by 3 seconds.
  limit  Cuts upstream payload to 128 bytes to truncate TLS handshakes.
  slicer         Fragments downstream packets into tiny chunks with delay.

Override defaults with:
  TOXIPROXY_API    - API endpoint (default http://127.0.0.1:8474)
  TOXIPROXY_PROXY  - Proxy name (default edge-a-to-b-mqtt)
EOF
}

scenario_name() {
  case "$1" in
    latency) echo "latency-up" ;;
    bandwidth) echo "bandwidth-up" ;;
    timeout) echo "timeout-up" ;;
    reset) echo "reset-up" ;;
    down) echo "proxy shutdown" ;;
    slow-close) echo "slow-close-down" ;;
    limit) echo "limit-up" ;;
    slicer) echo "slicer-down" ;;
    *) return 1 ;;
  esac
}

scenario_payload() {
  case "$1" in
    latency)
      cat <<'JSON'
{
  "name": "latency-up",
  "type": "latency",
  "stream": "upstream",
  "attributes": {
    "latency": 3000,
    "jitter": 1000
  }
}
JSON
      ;;
    limit)
      cat <<'JSON'
{
  "name": "limit-up",
  "type": "limit_data",
  "stream": "upstream",
  "attributes": {
    "bytes": 50
  }
}
JSON
      ;;
    slicer)
      cat <<'JSON'
{
  "name": "slicer-down",
  "type": "slicer",
  "stream": "downstream",
  "attributes": {
    "average_size": 20,
    "size_variation": 10,
    "delay": 5
  }
}
JSON
      ;;
    bandwidth)
      cat <<'JSON'
{
  "name": "bandwidth-up",
  "type": "bandwidth",
  "stream": "upstream",
  "attributes": {
    "rate": 1
  }
}
JSON
      ;;
    timeout)
      cat <<'JSON'
{
  "name": "timeout-up",
  "type": "timeout",
  "stream": "upstream",
  "attributes": {
    "timeout": 10000
  }
}
JSON
      ;;
    reset)
      cat <<'JSON'
{
  "name": "reset-up",
  "type": "reset_peer",
  "stream": "upstream",
  "attributes": {
    "timeout": 5000
  }
}
JSON
      ;;
      down)
      cat <<'JSON'
{
  "name": "edge-a-to-b-mqtt",
  "enabled": false
}
JSON
    ;;
      remove-down)
      cat <<'JSON'
{
  "name": "edge-a-to-b-mqtt",
  "enabled": true
}
JSON
    ;;    
    slow-close)
      cat <<'JSON'
{
  "name": "slow-close-down",
  "type": "slow_close",
  "stream": "downstream",
  "attributes": {
    "delay": 3000
  }
}
JSON
      ;;
    *)
      echo "Unknown scenario: $1" >&2
      exit 1
      ;;
  esac
}

require_scenario() {
  local scenario=${1:-}
  if [[ -z "$scenario" ]]; then
    echo "Missing scenario. See --help for options." >&2
    exit 1
  fi
}

require_duration() {
  local duration=${1:-}
  if [[ -z "$duration" ]]; then
    echo "Missing duration (seconds) for temporary toxic." >&2
    exit 1
  fi

  if ! [[ "$duration" =~ ^[0-9]+$ ]]; then
    echo "Duration must be a positive integer of seconds." >&2
    exit 1
  fi
}

api() {
  curl -sS "$@"
}

list_toxics() {
  api "${API_URL}/proxies/${PROXY}/toxics"
}

list_proxies() {
  api "${API_URL}/proxies"
}

create_or_replace() {
  local scenario=$1
  local name
  name=$(scenario_name "$scenario")

  if [ ${scenario} == "down" ]; then
    echo "Bringing down proxy..."
    scenario_payload "$scenario" | api -H 'Content-Type: application/json' \
      -X POST -d @- "${API_URL}/proxies/${PROXY}" >/dev/null
  else
    # Delete if it already exists to ensure a clean re-apply.
    api -X DELETE "${API_URL}/proxies/${PROXY}/toxics/${name}" >/dev/null || true

    scenario_payload "$scenario" | api -H 'Content-Type: application/json' \
      -X POST -d @- "${API_URL}/proxies/${PROXY}/toxics" >/dev/null
    echo "Applied ${scenario} toxic (${name})."
  fi

  
}

remove_toxic() {
  local scenario=$1
  local name
  name=$(scenario_name "$scenario")

  if [ ${scenario} == "down" ]; then
    echo "Bringing up proxy..."
    scenario_payload "remove-${scenario}" | api -H 'Content-Type: application/json' \
      -X POST -d @- "${API_URL}/proxies/${PROXY}" >/dev/null
  else
    api -X DELETE "${API_URL}/proxies/${PROXY}/toxics/${name}" >/dev/null
    echo "Removed ${scenario} toxic (${name})."
  fi
  
}

temporary_toxic() {
  local scenario=$1
  local duration=$2

  local cleanup_cmd="remove_toxic \"$scenario\""

  trap "${cleanup_cmd}" EXIT
  trap "trap - EXIT INT TERM; ${cleanup_cmd}; exit 130" INT TERM

  while true; do
    create_or_replace "$scenario"
    echo "Enabled ${scenario} toxic for ${duration} seconds."
    sleep "$duration"

    remove_toxic "$scenario"
    echo "Disabled ${scenario} toxic for ${duration} seconds."
    sleep "$duration"
  done
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

command=$1
shift || true

case "$command" in
  list-proxies)
    list_proxies
    ;;
  list-toxics)
    list_toxics
    ;;
  apply)
    require_scenario "$1"
    create_or_replace "$1"
    ;;
  temporary)
    require_scenario "$1"
    require_duration "$2"
    temporary_toxic "$1" "$2"
    ;;
  remove)
    require_scenario "$1"
    remove_toxic "$1"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    echo "Unknown command: $command" >&2
    usage
    exit 1
    ;;
esac
