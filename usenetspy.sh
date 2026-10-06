#!/usr/bin/env bash
# UsenetSpy — finds your Usenet containers automatically and shows, for each one,
# how many Usenet (NNTP) connections are open and which PUBLIC IP they leave from,
# so you can confirm Newshosting only ever sees one IP. Read-only.
set -uo pipefail

MATCH="${MATCH:-nzbdav|usenet|ultimate|sabnzbd|nzbget|gluetun|altmount|decypharr}" # auto-detect pattern
CONTAINERS="${CONTAINERS:-}"          # optional: exact names; overrides MATCH when set
PORTS="${NNTP_PORTS:-563 119}"        # NNTP ports (443 would also catch indexer web traffic)
INTERVAL="${INTERVAL:-2}"             # seconds between refreshes
IP_CHECK_EVERY="${IP_CHECK_EVERY:-60}" # seconds between public-IP checks
DISCOVER_EVERY="${DISCOVER_EVERY:-15}" # seconds between container re-scans
MODE="${MODE:-live}"                  # live = dashboard, log = change log
SELF="${SELF_NAME:-usenetspy}"
SELF_ID="$(hostname 2>/dev/null || true)"   # container id prefix, so it never lists itself
SOCK="${DOCKER_SOCK:-/var/run/docker.sock}"

HEXPORTS="$(for p in $PORTS; do printf '%04X ' "$p"; done)"

# Kernel hex address (from /proc/<pid>/net/tcp or tcp6) -> readable IP.
# IPv4-mapped IPv6 (::ffff:a.b.c.d, common with .NET apps like NZBDav) is shown as IPv4.
hex2ip() {
  local h=$1 out="" i w
  if [ ${#h} -eq 8 ]; then
    printf '%d.%d.%d.%d\n' 0x${h:6:2} 0x${h:4:2} 0x${h:2:2} 0x${h:0:2}; return
  fi
  if [ "${h:0:24}" = "0000000000000000FFFF0000" ]; then
    w=${h:24:8}; printf '%d.%d.%d.%d\n' 0x${w:6:2} 0x${w:4:2} 0x${w:2:2} 0x${w:0:2}; return
  fi
  for i in 0 8 16 24; do
    w=${h:i:8}; w="${w:6:2}${w:4:2}${w:2:2}${w:0:2}"; out+="${w:0:4}:${w:4:4}:"
  done
  echo "${out%:}" | tr 'A-F' 'a-f'
}

# Remote IPs of ESTABLISHED connections to the NNTP ports inside a process's network namespace.
peers_of() { # $1=pid
  local f h
  for f in "/proc/$1/net/tcp" "/proc/$1/net/tcp6"; do
    [ -r "$f" ] || continue
    awk -v ports=" $HEXPORTS" 'NR>1 && $4=="01" { split($3,a,":"); if (index(ports, " " a[2] " ")) print a[1] }' "$f"
  done | while read -r h; do hex2ip "$h"; done
}

# Everything is keyed by network namespace: containers sharing one (e.g. via
# network_mode: service:gluetun or network_mode: host) share one set of connections.
declare -A GPID GNAMES GMATCH COUNT PEERS EG4 EG6 WARNED
ORDER=()
ALERTS=()
LAST_IP_CHECK=0; LAST_DISCOVER=0; LAST_LOG=""

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
api() { curl -s --max-time 3 --unix-socket "$SOCK" "http://localhost$1"; }

alert() {
  local msg; msg="$(ts)  $*"
  ALERTS+=("$msg"); [ "${#ALERTS[@]}" -gt 8 ] && ALERTS=("${ALERTS[@]:1}")
  [ "$MODE" = "log" ] && echo "ALERT $msg"
}

wanted() { # $1=name $2=image
  if [ -n "$CONTAINERS" ]; then [[ " $CONTAINERS " == *" $1 "* ]]
  else printf '%s %s' "$1" "$2" | grep -Eiq "$MATCH"; fi
}

discover() {
  local id name image pid mode ns rows
  declare -A CPID=() CNAME=() CIMG=() CMODE=()
  GPID=(); GNAMES=(); GMATCH=()
  GPID[host]=1; GNAMES[host]="host"; GMATCH[host]=1
  # One API call per running container: id | name | image | pid | network mode
  rows=$(api /containers/json | jq -r '.[].Id' 2>/dev/null | while read -r id; do
           api "/containers/$id/json" | jq -r \
             '"\(.Id)|\(.Name|ltrimstr("/"))|\(.Config.Image)|\(.State.Pid // 0)|\(.HostConfig.NetworkMode)"' 2>/dev/null
         done)
  while IFS='|' read -r id name image pid mode; do
    [ -z "$id" ] || [ "$name" = "$SELF" ] || [[ -n "$SELF_ID" && "$id" == "$SELF_ID"* ]] || [ "${pid:-0}" -le 0 ] 2>/dev/null && continue
    CPID[$id]=$pid; CNAME[$id]=$name; CIMG[$id]=$image; CMODE[$id]=$mode
  done <<< "$rows"
  # Group containers that share a network: network_mode host -> "host",
  # network_mode container:X / service:X -> X's group, otherwise its own.
  for id in "${!CPID[@]}"; do
    mode=${CMODE[$id]}
    case "$mode" in
      host) ns=host ;;
      container:*) ns=${mode#container:}
                   for c in "${!CNAME[@]}"; do [ "${CNAME[$c]}" = "$ns" ] && ns=$c; done ;;
      *) ns=$id ;;
    esac
    if [ "$ns" != host ] && [ -n "${CPID[$ns]:-}" ] && [ -z "${GPID[$ns]:-}" ]; then
      GPID[$ns]=${CPID[$ns]}; GNAMES[$ns]=${CNAME[$ns]}
      wanted "${CNAME[$ns]}" "${CIMG[$ns]}" && GMATCH[$ns]=1
    fi
    [ -z "${GPID[$ns]:-}" ] && { GPID[$ns]=${CPID[$id]}; GNAMES[$ns]=${CNAME[$id]}; }
    [ "$ns" != "$id" ] && [[ "+${GNAMES[$ns]}+" != *"+${CNAME[$id]}+"* ]] && GNAMES[$ns]+="+${CNAME[$id]}"
    wanted "${CNAME[$id]}" "${CIMG[$id]}" && GMATCH[$ns]=1
  done
  # stable display order: matched first, alphabetical, host last
  mapfile -t ORDER < <(for ns in "${!GPID[@]}"; do
    [ "${GNAMES[$ns]}" = "host" ] || [[ "${GNAMES[$ns]}" == host+* ]] && k=2 || k=1
    printf '%s\t%s\t%s\n' "$k" "${GNAMES[$ns]}" "$ns"; done | sort | cut -f3)
}

# Public IP the internet sees from inside a namespace (by IP address, so no DNS needed).
egress() { # $1=pid $2=4|6
  local url='https://1.1.1.1/cdn-cgi/trace'
  [ "$2" = "6" ] && url='https://[2606:4700:4700::1111]/cdn-cgi/trace'
  nsenter -t "$1" -n curl -s --max-time 5 "$url" 2>/dev/null | sed -n 's/^ip=//p'
}

shown() { [ -n "${GMATCH[$1]:-}" ] || [ "${COUNT[$1]:-0}" -gt 0 ] 2>/dev/null; }

collect() {
  local ns list
  for ns in "${ORDER[@]}"; do
    list=$(peers_of "${GPID[$ns]}")
    COUNT[$ns]=$(printf '%s' "$list" | grep -c . || true)
    PEERS[$ns]=$(printf '%s\n' "$list" | grep . | sort | uniq -c | awk '{printf "%sx %s  ", $1, $2}')
    if [ "${COUNT[$ns]}" -gt 0 ] && [ -z "${GMATCH[$ns]:-}" ] && [ -z "${WARNED[$ns]:-}" ]; then
      alert "UNEXPECTED Usenet connections from '${GNAMES[$ns]}' (not a recognised Usenet app)"
      WARNED[$ns]=1
    fi
  done
}

check_ips() {
  local ns new4 new6
  for ns in "${ORDER[@]}"; do
    shown "$ns" || continue
    new4=$(egress "${GPID[$ns]}" 4); new4=${new4:--}
    new6=$(egress "${GPID[$ns]}" 6); new6=${new6:--}
    if [ -n "${EG4[$ns]:-}" ] && [ "${EG4[$ns]}" != "$new4" ]; then
      alert "${GNAMES[$ns]} public IPv4 changed: ${EG4[$ns]} -> $new4"
    fi
    EG4[$ns]=$new4; EG6[$ns]=$new6
  done
}

# What Newshosting sees right now: IPv4 peers -> that namespace's IPv4, IPv6 peers -> its IPv6.
verdict() {
  local ns seen="" all4="" n
  for ns in "${ORDER[@]}"; do
    shown "$ns" || continue
    [ "${EG4[$ns]:--}" != "-" ] && all4+="${EG4[$ns]}"$'\n'
    [ "${COUNT[$ns]:-0}" -gt 0 ] || continue
    printf '%s' "${PEERS[$ns]}" | grep -q ':' && seen+="${EG6[$ns]:-?} (IPv6)"$'\n'
    printf '%s' "${PEERS[$ns]}" | grep -Eq '([0-9]+\.){3}[0-9]+' && seen+="${EG4[$ns]:-?}"$'\n'
  done
  seen=$(printf '%s' "$seen" | grep . | sort -u)
  n=$(printf '%s' "$seen" | grep -c . || true)
  if printf '%s' "$seen" | grep -Eq '^(-|\?)'; then
    STATUS="?? Usenet connections are open but a public-IP check failed (retrying every ${IP_CHECK_EVERY}s)"
  elif [ "$n" -gt 1 ]; then STATUS="!! SPLIT: Newshosting is seeing $n IPs right now: $(echo $seen)"
  elif [ "$n" -eq 1 ]; then STATUS="OK: all Usenet traffic leaves from one IP: $seen"
  else STATUS="IDLE: no Usenet connections open"; fi
  if [ "$(printf '%s' "$all4" | grep . | sort -u | grep -c . || true)" -gt 1 ]; then
    STATUS+=$'\n'"!! WARNING: your Usenet containers leave the internet from DIFFERENT IPv4s (check VPN / network_mode)"
  fi
}

render_live() {
  local ns
  printf '\033[H\033[2J'
  echo "UsenetSpy   $(ts)   refresh ${INTERVAL}s · IP check ${IP_CHECK_EVERY}s · ports: $PORTS"
  echo "Ctrl-C to quit"; echo
  printf '%-28s %-6s %-17s %-24s %s\n' "CONTAINER(S)" "CONNS" "PUBLIC IPv4" "PUBLIC IPv6" "USENET SERVERS"
  printf '%-28s %-6s %-17s %-24s %s\n' "------------" "-----" "-----------" "-----------" "--------------"
  for ns in "${ORDER[@]}"; do
    shown "$ns" || continue
    printf '%-28s %-6s %-17s %-24s %s\n' "${GNAMES[$ns]}" "${COUNT[$ns]}" "${EG4[$ns]:-…}" "${EG6[$ns]:-…}" "${PEERS[$ns]}"
  done
  echo; echo "$STATUS"
  [ "${#ALERTS[@]}" -gt 0 ] && { echo; echo "Recent alerts:"; printf '  %s\n' "${ALERTS[@]}"; }
}

render_log() {
  local ns line=""
  for ns in "${ORDER[@]}"; do shown "$ns" && line+="${GNAMES[$ns]}=${COUNT[$ns]}@${EG4[$ns]:-?} "; done
  line+="| $(printf '%s' "$STATUS" | head -1)"
  [ "$line" != "$LAST_LOG" ] && echo "$(ts)  $line"
  LAST_LOG=$line
}

[ -S "$SOCK" ] || { echo "Docker socket not found at $SOCK — mount it (see docker-compose.yml)."; exit 1; }
trap 'echo; exit 0' INT TERM
discover
if [ "$MODE" = "log" ]; then
  echo "$(ts)  UsenetSpy started; found: $(for ns in "${ORDER[@]}"; do [ -n "${GMATCH[$ns]:-}" ] && printf '%s ' "${GNAMES[$ns]}"; done)"
fi

while true; do
  now=$(date +%s)
  if [ $((now - LAST_DISCOVER)) -ge "$DISCOVER_EVERY" ]; then discover; LAST_DISCOVER=$now; fi
  collect
  if [ $((now - LAST_IP_CHECK)) -ge "$IP_CHECK_EVERY" ]; then check_ips; LAST_IP_CHECK=$now; fi
  verdict
  if [ "$MODE" = "log" ]; then render_log; else render_live; fi
  sleep "$INTERVAL"
done
