#!/usr/bin/env bash
# ucd-hpc: report planned cluster maintenance so agents can pick a safe --time and explain
# jobs pending as "(ReqNodeNotAvail, Reserved for maintenance)". Read-only and cheap; run it on
# the login node (it reads the login notice files and `scontrol show reservation`).
#
# Sources, merged and de-duplicated:
#   1. Slurm reservations whose Flags contain MAINT (authoritative: HPCCF's login notice,
#      /etc/profile.d/zzz_show-slurm-reservation.sh, is just a formatter over this reservation;
#      that script is interactive-only and needs scontrol on PATH, so it is NOT run here);
#   2. a "Maintenance Window Notice" in the MOTD files, as a fallback if scontrol is unavailable.
#
# Usage:
#   maintenance.sh                  human-readable report
#   maintenance.sh --brief          one line (for dashboards / context probes)
#   maintenance.sh --check-time T   does a job with --time=T cross the window? (Slurm formats:
#                                   M, M:S, H:M:S, D-H, D-H:M, D-H:M:S)
# Exit: 0 no window known | 10 window upcoming | 11 window active now | 12 (--check-time only)
#       T would reach into the window | 2 usage.
# Test hooks: MAINT_NOW="YYYY-MM-DD HH:MM:SS" fakes the clock; MAINT_NOTICE_FILES="a:b" replaces
# the MOTD fallback list; MAINT_SKIP_SCONTROL=1 ignores Slurm.
set -u

MODE=report; CHECK=""
case "${1:-}" in
  "") ;;
  --brief) MODE=brief ;;
  --check-time) MODE=check; CHECK="${2:-}"; [ -n "$CHECK" ] || { echo "usage: maintenance.sh --check-time TIME" >&2; exit 2; } ;;
  -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: maintenance.sh [--brief | --check-time TIME]" >&2; exit 2 ;;
esac

T() { timeout 25 "$@" 2>/dev/null; }
epoch() { date -d "$1" +%s 2>/dev/null; }
NOW=$(epoch "${MAINT_NOW:-now}") || NOW=$(date +%s)

# --- 2. MOTD fallback -----------------------------------------------------------------------
NOTICE_FILES=${MAINT_NOTICE_FILES:-/etc/motd:/run/motd.dynamic:/etc/motd.d/*:/etc/ssh/banner*:/etc/issue.net}
WINDOWS=""     # lines: start_epoch|end_epoch|start_text|end_text|source
NOTICE_TEXT=""

# parse_notice LABEL TEXT : append a window to WINDOWS if TEXT holds a maintenance notice
parse_notice() {
  local label=$1 text=$2 body s e se ee
  grep -q 'Maintenance Window Notice' <<<"$text" || return 0
  body=$(sed -n '/Maintenance Window Notice/,$p' <<<"$text")
  s=$(sed -nE 's/.*[Mm]aintenance starts at ([0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9:]{8}).*/\1/p' <<<"$body" | head -1)
  e=$(sed -nE 's/.*downtime ends at ([0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9:]{8}).*/\1/p' <<<"$body" | head -1)
  [ -n "$s" ] || return 0
  se=$(epoch "${s/T/ }") || return 0
  ee=""; [ -n "$e" ] && ee=$(epoch "${e/T/ }")
  WINDOWS+="$se|${ee:-0}|${s/T/ }|${e/T/ }|$label"$'\n'
  [ -z "$NOTICE_TEXT" ] && NOTICE_TEXT=$(awk '/Maintenance Window Notice/{n++} n>=1{print} n>=2{exit}' <<<"$body")
  return 0
}

IFS=':' read -r -a CANDS <<<"$NOTICE_FILES"
for pat in "${CANDS[@]}"; do
  # shellcheck disable=SC2086  # the glob is intentional
  for f in $pat; do
    if [ -f "$f" ] && [ -r "$f" ]; then parse_notice "notice:$f" "$(cat "$f")"; fi
  done
done

# --- 1. Slurm MAINT reservations (primary) -----------------------------------------------------------
if [ "${MAINT_SKIP_SCONTROL:-0}" != 1 ]; then
  if ! command -v scontrol >/dev/null 2>&1; then
    SLURM_BIN=/cvmfs/hpc.ucdavis.edu/sw/spack/environments/core/view/generic/slurm/bin
    [ -d "$SLURM_BIN" ] && PATH="$SLURM_BIN:$PATH"
  fi
  if command -v scontrol >/dev/null 2>&1; then
    while IFS='|' read -r name s e scope; do
      [ -n "$s" ] || continue
      se=$(epoch "${s/T/ }") || continue
      ee=$(epoch "${e/T/ }") || ee=0
      WINDOWS+="$se|$ee|${s/T/ }|${e/T/ }|reservation:$name($scope)"$'\n'
    done < <(T scontrol show reservation | awk -v RS= '
      /Flags=[^ ]*MAINT/ {
        n=""; s=""; e=""
        if (match($0,/ReservationName=[^ \n]+/)) n=substr($0,RSTART+16,RLENGTH-16)
        if (match($0,/StartTime=[^ \n]+/))       s=substr($0,RSTART+10,RLENGTH-10)
        if (match($0,/EndTime=[^ \n]+/))         e=substr($0,RSTART+8,RLENGTH-8)
        sc = ($0 ~ /Flags=[^ ]*ALL_NODES/) ? "all-nodes" : "partial"
        print n "|" s "|" e "|" sc }')
  fi
fi

# --- pick the relevant window: not yet over, earliest start --------------------------------
LIVE=$(awk -F'|' -v now="$NOW" 'NF>=5 && ($2==0 || $2>now) {print}' <<<"$WINDOWS" | sort -t'|' -k1,1n)
# Headline = earliest full-cluster window (notice or ALL_NODES reservation); a MAINT reservation
# on only some nodes is listed separately so it cannot hide the full downtime.
PICK=$(grep -v '(partial)$' <<<"$LIVE" | head -1)
PARTIAL=$(grep '(partial)$' <<<"$LIVE")
[ -z "$PICK" ] && PICK=$(head -1 <<<"$LIVE")
if [ -z "$PICK" ]; then
  case $MODE in
    brief)  echo "maintenance: none announced" ;;
    check)  echo "OK: no maintenance window announced" ;;
    report) echo "maintenance: none announced (checked login notice files and MAINT reservations)"
            echo "  Not a guarantee: re-run at login time, and see https://docs.hpc.ucdavis.edu for announcements." ;;
  esac
  exit 0
fi

IFS='|' read -r S_EP E_EP S_TXT E_TXT _ <<<"$PICK"
SOURCES=$(awk -F'|' -v s="$S_EP" '$1==s{print $5}' <<<"$WINDOWS" | sort -u | paste -sd, -)
if [ "$S_EP" -le "$NOW" ]; then STATE=active; RC=11; else STATE=upcoming; RC=10; fi

fmt_dhms() {  # seconds -> D-HH:MM:SS (Slurm --time format)
  local s=$1; [ "$s" -lt 0 ] && s=0
  printf '%d-%02d:%02d:%02d' $((s/86400)) $((s%86400/3600)) $((s%3600/60)) $((s%60))
}
fmt_human() { local s=$1; printf '%dd %dh %dm' $((s/86400)) $((s%86400/3600)) $((s%3600/60)); }

# Slurm time spec -> seconds
slurm_secs() {
  local t=$1 d=0 h=0 m=0 s=0 rest
  [[ $t =~ ^[0-9]+(-[0-9]+(:[0-9]+){0,2})?(:[0-9]+){0,2}$ ]] || { echo -1; return; }
  if [[ $t == *-* ]]; then
    d=${t%%-*}; rest=${t#*-}
    IFS=: read -r h m s <<<"$rest"
  else
    local n; n=$(tr -cd ':' <<<"$t" | wc -c)
    case $n in
      0) m=$t ;;
      1) IFS=: read -r m s <<<"$t" ;;
      2) IFS=: read -r h m s <<<"$t" ;;
    esac
  fi
  echo $(( 10#${d:-0}*86400 + 10#${h:-0}*3600 + 10#${m:-0}*60 + 10#${s:-0} ))
}

UNTIL_START=$(( S_EP - NOW ))
MAXTIME=$(fmt_dhms $(( UNTIL_START / 60 * 60 )))

case $MODE in
  brief)
    if [ $STATE = upcoming ]; then
      echo "maintenance: upcoming start=$S_TXT end=${E_TXT:-unknown} max-safe-time=$MAXTIME"
    else
      echo "maintenance: ACTIVE since $S_TXT end=${E_TXT:-unknown}"
    fi
    exit $RC ;;
  check)
    secs=$(slurm_secs "$CHECK")
    [ "$secs" -ge 0 ] || { echo "cannot parse --time '$CHECK'" >&2; exit 2; }
    if [ $STATE = active ] || [ "$secs" -gt "$UNTIL_START" ]; then
      echo "OVERLAP: --time=$CHECK reaches into the maintenance window starting $S_TXT; the job will stay pending as (ReqNodeNotAvail, Reserved for maintenance) until the downtime ends${E_TXT:+ ($E_TXT)}. Largest --time that finishes first: $MAXTIME"
      exit 12
    fi
    echo "OK: --time=$CHECK finishes before maintenance starts ($S_TXT)"
    exit 0 ;;
esac

echo "maintenance: $STATE   (source: $SOURCES)"
echo "  starts: $S_TXT$([ $STATE = upcoming ] && echo "   (in $(fmt_human "$UNTIL_START"))")"
if [ "$E_EP" != 0 ] && [ -n "$E_TXT" ]; then
  echo "  ends:   $E_TXT   (downtime lasts $(fmt_human $(( E_EP - S_EP ))))"
else
  echo "  ends:   not announced"
fi
if [ $STATE = upcoming ]; then
  echo "  largest --time that still finishes before the start: $MAXTIME"
  echo "  A job asking for more than that does not start until the downtime ends."
else
  echo "  The cluster is in its maintenance window: nothing new starts until it ends."
fi
if [ -n "$PARTIAL" ]; then
  echo "  also, MAINT reservations on only some nodes (jobs overlapping them avoid those nodes):"
  awk -F'|' '{printf "    %s -> %s  (%s)\n",$3,$4,$5}' <<<"$PARTIAL"
fi
echo "  Running jobs are killed when the window starts. Checkpoint or shorten work that would overlap."
echo "  Pending jobs show: (ReqNodeNotAvail, Reserved for maintenance). That is expected; do not"
echo "  cancel and resubmit it. Shorten --time below the limit above only if the user wants it to run sooner."
if [ -n "$NOTICE_TEXT" ]; then
  echo "  login notice:"; sed 's/^/    | /' <<<"$NOTICE_TEXT"
fi
exit $RC
