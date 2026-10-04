#!/usr/bin/env bash
# docker-diag.sh - read-only Docker host/container diagnostic collector
#
# Usage:        sudo ./docker-diag.sh [-o FILE] [--since 24h] [--tail N] [CONTAINER]
# Requirements: bash 4+, Docker CLI with access to the Docker daemon.

set -uo pipefail
umask 077

VERSION="1.0.0"
OUTPUT=""
TAIL=200
SINCE="24h"
INCLUDE_LOGS=1
INCLUDE_EVENTS=1
WARNINGS=0

usage() {
  cat <<'EOF'
Usage: docker-diag.sh [OPTIONS] [CONTAINER]

Collect Docker daemon and container diagnostics without changing Docker state.
Environment variable names are shown, but values are always redacted. Log
redaction is best-effort; inspect the report before sharing it.

Options:
  -o, --output FILE      Output file (default: ./docker-diag-HOST-TIME.txt)
      --tail LINES       Log lines per container (default: 200)
      --since DURATION   Docker log/event duration (default: 24h)
      --no-logs          Do not collect application logs
      --no-events        Do not collect recent Docker events
  -h, --help             Show help
      --version          Show version

Exit codes: 0 completed; 1 completed with container/daemon warnings;
            2 invalid usage; 3 Docker unavailable or report creation failed.
EOF
}

have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n==== %s ====\n' "$1"; }
run() { printf '\n$'; printf ' %q' "$@"; printf '\n'; "$@" 2>&1 || printf '[command exited %s]\n' "$?"; }
redact_logs() {
  sed -E \
    -e 's/([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn])([[:space:]]*[:=][[:space:]]*)[^[:space:],;]+/\1\2[REDACTED]/g' \
    -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._~+\/-]+/\1[REDACTED]/g'
}

while (($#)); do
  case "$1" in
    -o|--output) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; OUTPUT=$2; shift 2 ;;
    --tail) [[ $# -ge 2 && $2 =~ ^[0-9]+$ ]] || { echo "Invalid --tail" >&2; exit 2; }; TAIL=$2; shift 2 ;;
    --since) [[ $# -ge 2 && -n $2 ]] || { usage >&2; exit 2; }; SINCE=$2; shift 2 ;;
    --no-logs) INCLUDE_LOGS=0; shift ;;
    --no-events) INCLUDE_EVENTS=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "docker-diag.sh $VERSION"; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) [[ -z ${CONTAINER:-} ]] || { echo "Only one container may be supplied" >&2; exit 2; }; CONTAINER=$1; shift ;;
  esac
done

have docker || { echo "docker CLI is not installed" >&2; exit 3; }
if ! docker info >/dev/null 2>&1; then
  echo "Cannot communicate with the Docker daemon. Check daemon status and socket permissions." >&2
  exit 3
fi
if [[ -n ${CONTAINER:-} ]] && ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "Container not found or not accessible: $CONTAINER" >&2
  exit 3
fi

host=$(hostname -s 2>/dev/null || echo unknown)
stamp=$(date +%Y%m%d-%H%M%S)
[[ -n $OUTPUT ]] || OUTPUT="./docker-diag-${host//[^A-Za-z0-9._-]/_}-${stamp}.txt"
if ! : >"$OUTPUT" 2>/dev/null; then echo "Cannot create report: $OUTPUT" >&2; exit 3; fi

if [[ -n ${CONTAINER:-} ]]; then
  containers=("$CONTAINER")
else
  mapfile -t containers < <(docker ps -aq 2>/dev/null)
fi

collect_container() {
  local c=$1 name state health restarts
  name=$(docker inspect --format '{{.Name}}' "$c" 2>/dev/null | sed 's#^/##')
  section "Container: ${name:-$c}"
  run docker inspect --format $'ID: {{.Id}}\nName: {{.Name}}\nImage: {{.Config.Image}}\nCreated: {{.Created}}\nState: {{.State.Status}}\nStarted: {{.State.StartedAt}}\nFinished: {{.State.FinishedAt}}\nExitCode: {{.State.ExitCode}}\nOOMKilled: {{.State.OOMKilled}}\nError: {{.State.Error}}\nRestartCount: {{.RestartCount}}\nRestartPolicy: {{.HostConfig.RestartPolicy.Name}}\nMemoryLimit: {{.HostConfig.Memory}}\nNanoCPUs: {{.HostConfig.NanoCpus}}\nPidsLimit: {{.HostConfig.PidsLimit}}\nReadonlyRootfs: {{.HostConfig.ReadonlyRootfs}}\nPrivileged: {{.HostConfig.Privileged}}\nUser: {{.Config.User}}' "$c"
  run docker inspect --format 'Health: {{if .State.Health}}{{json .State.Health}}{{else}}not configured{{end}}' "$c"
  run docker inspect --format 'Mounts: {{json .Mounts}}' "$c"
  run docker inspect --format 'Networks: {{json .NetworkSettings.Networks}}' "$c"
  run docker inspect --format 'Ports: {{json .NetworkSettings.Ports}}' "$c"
  run docker inspect --format 'DNS: {{json .HostConfig.Dns}}; DNS search: {{json .HostConfig.DnsSearch}}' "$c"
  echo "Environment variable names (values redacted):"
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$c" 2>/dev/null | sed -E 's/^([^=]+)=.*$/\1=[REDACTED]/'
  echo "Image metadata:"
  image_id=$(docker inspect --format '{{.Image}}' "$c" 2>/dev/null)
  [[ -n $image_id ]] && docker image inspect --format $'ID: {{.Id}}\nRepoDigests: {{json .RepoDigests}}\nCreated: {{.Created}}\nArchitecture: {{.Architecture}}\nOS: {{.Os}}\nSize: {{.Size}}' "$image_id" 2>&1
  state=$(docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null)
  health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null)
  restarts=$(docker inspect --format '{{.RestartCount}}' "$c" 2>/dev/null)
  if [[ $state != running || $health == unhealthy || ${restarts:-0} -gt 0 ]]; then WARNINGS=$((WARNINGS + 1)); fi
  if ((INCLUDE_LOGS)); then
    echo "Recent logs (best-effort secret redaction; review before sharing):"
    docker logs --timestamps --since "$SINCE" --tail "$TAIL" "$c" 2>&1 | redact_logs
  else
    echo "Logs skipped by request."
  fi
}

collect() {
  echo "Docker diagnostic report"
  echo "Generated: $(date --iso-8601=seconds 2>/dev/null || date)"
  echo "Host: $host"
  echo "Collector version: $VERSION"
  echo "NOTICE: Read-only collector. Environment values are omitted."
  echo "        Logs receive heuristic redaction but may still contain sensitive data."

  section "Docker host"
  run docker version
  run docker info
  run docker system df -v
  run docker ps -a --no-trunc --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  run docker network ls
  run docker volume ls
  have systemctl && run systemctl status docker --no-pager
  have journalctl && run journalctl -u docker --since "$SINCE" --no-pager -n 500

  if ((${#containers[@]} == 0)); then
    section "Containers"
    echo "No containers found."
  else
    for c in "${containers[@]}"; do collect_container "$c"; done
  fi

  section "Recent events"
  if ((INCLUDE_EVENTS)); then
    run docker events --since "$SINCE" --until "$(date --iso-8601=seconds 2>/dev/null || date -Iseconds)"
  else
    echo "Events skipped by request."
  fi

  section "Result"
  ((WARNINGS == 0)) && echo "COMPLETED" || echo "COMPLETED WITH $WARNINGS CONTAINER/DAEMON WARNING(S)"
}

collect >"$OUTPUT" 2>&1
echo "Report written to: $OUTPUT"
((WARNINGS == 0)) || exit 1
exit 0
