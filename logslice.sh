#!/usr/bin/env bash
# logslice.sh - extract Apache/nginx combined-log entries within a time window
# Stops reading shortly after END (log must be roughly chronological).
set -eu

usage() {
  cat <<EOF
Usage: $(basename "$0") -f LOG -s "START" -e "END" [-o OUT] [-b MIN]
  -f  log file (.gz supported)
  -s  start time, inclusive   e.g. "2026-09-28 18:50:00"
  -e  end time, exclusive     e.g. "2026-09-28 19:25:00"
  -o  output file (default: stdout)
  -b  early-exit buffer in minutes (default: 1)

Example:
  $(basename "$0") -f access.log -s "2026-09-28 18:50" -e "2026-09-28 19:25" -o slice.log
EOF
  exit 1
}

log="" start="" end="" out="" buf=1
while getopts "f:s:e:o:b:h" opt; do
  case $opt in
    f) log=$OPTARG ;;
    s) start=$OPTARG ;;
    e) end=$OPTARG ;;
    o) out=$OPTARG ;;
    b) buf=$OPTARG ;;
    *) usage ;;
  esac
done

[[ -z $log || -z $start || -z $end ]] && usage
[[ -r $log ]] || { echo "Error: cannot read $log" >&2; exit 2; }
[[ $buf =~ ^[0-9]+$ ]] || { echo "Error: -b must be whole minutes" >&2; exit 2; }

s=$(date -d "$start" +%Y%m%d%H%M%S 2>/dev/null) || { echo "Error: bad start '$start'" >&2; exit 2; }
e=$(date -d "$end"   +%Y%m%d%H%M%S 2>/dev/null) || { echo "Error: bad end '$end'" >&2; exit 2; }
x=$(date -d "$end $buf min" +%Y%m%d%H%M%S)
(( s < e )) || { echo "Error: start must be before end" >&2; exit 2; }

read -r -d '' prog <<'AWK' || true
BEGIN {
  split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " ")
  for (i = 1; i <= 12; i++) mon[m[i]] = sprintf("%02d", i)
}
$4 !~ /^\[/ { next }
{
  split($4, t, /[\[\/:]/)
  k = t[4] mon[t[3]] t[2] t[5] t[6] t[7]
  if (k >= x) exit
  if (k >= s && k < e) { print; n++ }
}
END { printf "%d lines matched\n", n > "/dev/stderr" }
AWK

[[ -n $out ]] && exec >"$out"
export LC_ALL=C

if [[ $log == *.gz ]]; then
  zcat -- "$log" | awk -v s="$s" -v e="$e" -v x="$x" "$prog"
else
  awk -v s="$s" -v e="$e" -v x="$x" "$prog" "$log"
fi
