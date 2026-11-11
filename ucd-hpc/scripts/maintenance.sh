#!/usr/bin/env bash
# ucd-hpc: report planned Slurm maintenance so an agent can pick a --time that finishes first and
# explain jobs pending as "(ReqNodeNotAvail, Reserved for maintenance)".
#
# Source: Slurm reservations whose Flags include MAINT, read live with ONE
# `scontrol -o show reservation` call (capped at 10 s). Nothing is cached or stored, and nothing
# here is specific to a site, cluster, or user: it works on any Slurm cluster. Run it on a login
# node; it can also be piped: ssh HOST 'bash -s -- --brief' < maintenance.sh
#
# A reservation counts as whole-cluster when it has the ALL_NODES flag and no PartitionName.
# Any other MAINT reservation (a partition, or a node list) is "partial": a job that can run on
# other nodes is not held by it, so it never sets the headline limit for a whole-cluster window.
#
# Usage:
#   maintenance.sh                 report
#   maintenance.sh --brief         one key=value line
#   maintenance.sh --check-time T  would a job with --time=T, started now, reach into a window?
#                                  T: M, M:S, H:M:S, D-H, D-H:M, D-H:M:S, 0, UNLIMITED, INFINITE
# Exit: 0  report/brief: reservations were read (window or not); --check-time: T fits, or no window
#       12 --check-time: T reaches into a whole-cluster window (or one is active now)
#       13 --check-time: T reaches only into a partial window (the job may run on other nodes)
#       3  reservations could not be read (no scontrol, error, or timeout): state unknown
#       2  usage
# Test hook: MAINTENANCE_SH_NOW="YYYY-MM-DD HH:MM:SS" replaces the clock.
set -u

USAGE="usage: maintenance.sh [--brief | --check-time TIME]"
MODE=report; CHECK=""
case "${1:-}" in
  "") ;;
  --brief) MODE=brief ;;
  --check-time) MODE=check; CHECK=${2:-}; CHECK=${CHECK//[[:space:]]/}
                [ -n "$CHECK" ] || { echo "$USAGE" >&2; exit 2; } ;;
  -h|--help) echo "$USAGE"; echo "exit: 0 ok/fits, 12 overlaps whole-cluster window, 13 overlaps partial window, 3 unknown, 2 usage"; exit 0 ;;
  *) echo "$USAGE" >&2; exit 2 ;;
esac

NOW=$(date -d "${MAINTENANCE_SH_NOW:-now}" +%s 2>/dev/null) || NOW=$(date +%s)

# Slurm local time (2026-12-07T06:00:00) -> epoch. Validates the shape first: `date -d` happily
# parses junk such as "(null)", and Slurm prints Unknown / (null) / NONE for unset times.
epoch() {
  [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?$ ]] || return 1
  date -d "${1/T/ }" +%s 2>/dev/null
}
fmt_time() { date -d "@$1" "+${2:-%Y-%m-%d %H:%M:%S %Z}"; }
fmt_dhms() { local s=$(( $1 < 0 ? 0 : $1 / 60 * 60 )); printf '%d-%02d:%02d:%02d' $((s/86400)) $((s%86400/3600)) $((s%3600/60)) 0; }
fmt_human() { local s=$1; printf '%dd %dh %dm' $((s/86400)) $((s%86400/3600)) $((s%3600/60)); }

# Slurm --time spec -> seconds in SECS; INF for 0/UNLIMITED/INFINITE; returns 1 if unparseable.
# Seconds round up to whole minutes, as Slurm does.
slurm_secs() {
  local t=$1 d=0 h=0 m=0 s=0 r
  SECS=""
  if [[ $t =~ ^(UNLIMITED|INFINITE|unlimited|infinite)$ ]]; then SECS=INF; return 0; fi
  if [[ $t =~ ^([0-9]{1,5})-([0-9]{1,6})(:([0-9]{1,6}))?(:([0-9]{1,6}))?$ ]]; then
    r=("${BASH_REMATCH[@]}"); d=${r[1]}; h=${r[2]}; m=${r[4]:-0}; s=${r[6]:-0}
  elif [[ $t =~ ^([0-9]{1,8})(:([0-9]{1,6}))?(:([0-9]{1,6}))?$ ]]; then
    r=("${BASH_REMATCH[@]}")
    if [ -n "${r[5]}" ]; then h=${r[1]}; m=${r[3]}; s=${r[5]}
    elif [ -n "${r[3]}" ]; then m=${r[1]}; s=${r[3]}
    else m=${r[1]}; fi
  else
    return 1
  fi
  SECS=$(( 10#$d*86400 + 10#$h*3600 + 10#$m*60 + 10#$s ))
  SECS=$(( (SECS + 59) / 60 * 60 ))
  [ "$SECS" -eq 0 ] && SECS=INF   # --time=0 means no limit
  return 0
}

if [ "$MODE" = check ] && ! slurm_secs "$CHECK"; then
  echo "cannot parse --time '$CHECK' (Slurm forms: M, M:S, H:M:S, D-H, D-H:M, D-H:M:S)" >&2; exit 2
fi

# --- read reservations: one scontrol call ------------------------------------------------------
# Optional, harmless elsewhere: UC Davis HPC keeps Slurm at a fixed CVMFS path that a
# non-interactive ssh shell may not have on PATH.
if ! command -v scontrol >/dev/null 2>&1; then
  SLURM_BIN=/cvmfs/hpc.ucdavis.edu/sw/spack/environments/core/view/generic/slurm/bin
  [ -x "$SLURM_BIN/scontrol" ] && PATH="$SLURM_BIN:$PATH"
fi
unknown() {
  case $MODE in
    brief) echo "maintenance: state=unknown reason=\"$1\"" ;;
    *)     echo "maintenance: UNKNOWN, could not read Slurm reservations: $1"
           echo "  Do not assume there is no maintenance window. Retry on a login node: scontrol show reservation" ;;
  esac
  exit 3
}
command -v scontrol >/dev/null 2>&1 || unknown "scontrol not found (not on a Slurm login node?)"
# SLURM_TIME_FORMAT=standard: a user's own SLURM_TIME_FORMAT would otherwise change the dates.
# Only "ReservationName=" lines and indented continuations are parsed, so stray stderr is ignored.
RAW=$(SLURM_TIME_FORMAT=standard timeout 10 scontrol -o show reservation 2>&1); rc=$?
[ $rc = 124 ] && unknown "scontrol timed out after 10 s"
if [ $rc != 0 ] && ! grep -q 'No reservations' <<<"$RAW"; then
  unknown "scontrol show reservation failed (exit $rc): $(head -1 <<<"$RAW")"
fi

# One record per reservation (also joins the multi-line layout, should -o be ignored), keeping
# MAINT ones: name|start|end|kind|scope. Flags are matched as exact comma-separated tokens.
ROWS=$(awk '
  /^[[:space:]]*ReservationName=/ { if (rec != "") print rec; rec = $0; next }
  rec != "" && /^[[:space:]]+[^[:space:]]/ { rec = rec " " $0 }
  END { if (rec != "") print rec }' <<<"$RAW" | awk '
  {
    delete v
    for (i = 1; i <= NF; i++) { k = $i; sub(/=.*/, "", k); if (!(k in v)) { x = $i; sub(/^[^=]*=/, "", x); v[k] = x } }
    nf = split(v["Flags"], f, ","); maint = 0; all = 0
    for (i = 1; i <= nf; i++) { if (f[i] == "MAINT") maint = 1; if (f[i] == "ALL_NODES") all = 1 }
    if (!maint) next
    p = v["PartitionName"]; if (p == "(null)" || p == "NONE") p = ""
    if (all && p == "")  { kind = "cluster"; scope = "whole cluster" }
    else if (p != "")    { kind = "partial"; scope = "partition " p (all ? "" : ", " v["NodeCnt"] " nodes") }
    else                 { kind = "partial"; scope = v["NodeCnt"] " nodes only: " v["Nodes"] }
    print v["ReservationName"] "|" v["StartTime"] "|" v["EndTime"] "|" kind "|" scope
  }')

# Live windows (not yet over), as start_ep|end_ep(0=unknown)|name|kind|scope, earliest first.
LIVE=""; BAD=""
while IFS='|' read -r name s e kind scope; do
  [ -n "$name" ] || continue
  se=$(epoch "$s") || { BAD+="$name (StartTime=$s) "; continue; }
  ee=$(epoch "$e") || ee=0
  [ "$ee" != 0 ] && [ "$ee" -le "$NOW" ] && continue
  LIVE+="$se|$ee|$name|$kind|$scope"$'\n'
done <<<"$ROWS"
LIVE=$(sort -t'|' -k1,1n <<<"$LIVE" | sed '/^$/d')

if [ -z "$LIVE" ]; then
  case $MODE in
    brief)  echo "maintenance: state=none" ;;
    check)  echo "OK: no current or upcoming Slurm maintenance reservation" ;;
    report) echo "maintenance: none (no current or upcoming Slurm reservation with Flags=MAINT)"
            echo "  Windows appear when the admins create the reservation; re-check before long submissions." ;;
  esac
  [ -n "$BAD" ] && echo "  note: MAINT reservation with an unreadable StartTime ignored: $BAD"
  exit 0
fi

# Headline: earliest whole-cluster window; if there is none, the earliest partial one.
HEAD=$(grep -m1 '|cluster|' <<<"$LIVE" || head -1 <<<"$LIVE")
IFS='|' read -r S_EP E_EP NAME KIND SCOPE <<<"$HEAD"
UNTIL=$(( S_EP - NOW ))
if [ "$UNTIL" -le 0 ]; then STATE=active; else STATE=upcoming; fi
MAXT=$(fmt_dhms "$UNTIL")
END_TXT=unknown; [ "$E_EP" != 0 ] && END_TXT=$(fmt_time "$E_EP")
OTHERS=$(( $(wc -l <<<"$LIVE") - 1 ))

case $MODE in
  brief)
    printf 'maintenance: state=%s scope=%s start=%s end=%s tz=%s' "$STATE" "$KIND" \
      "$(fmt_time "$S_EP" '%Y-%m-%dT%H:%M:%S')" \
      "$([ "$E_EP" != 0 ] && fmt_time "$E_EP" '%Y-%m-%dT%H:%M:%S' || echo unknown)" "$(fmt_time "$S_EP" '%Z')"
    [ $STATE = upcoming ] && printf ' max_time_now=%s' "$MAXT"
    printf ' reservation=%s other_windows=%d\n' "$NAME" "$OTHERS"
    exit 0 ;;
  check)
    # Overlap with [start, end) for a job starting now: active window, or start falls before now+T.
    hit=""
    while IFS='|' read -r se _ name kind scope; do
      if [ "$SECS" = INF ] || [ "$(( se - NOW ))" -lt "$SECS" ]; then hit="$se|$name|$kind|$scope"; [ "$kind" = cluster ] && break; fi
    done <<<"$LIVE"
    [ -z "$hit" ] && { echo "OK: --time=$CHECK finishes before the next maintenance window ($(fmt_time "$S_EP"))"; exit 0; }
    IFS='|' read -r se name kind scope <<<"$hit"
    when="starting $(fmt_time "$se")"; [ "$se" -le "$NOW" ] && when="in progress since $(fmt_time "$se")"
    if [ "$kind" = cluster ]; then
      echo "OVERLAP: --time=$CHECK reaches into the whole-cluster maintenance window $when (reservation $name). Submitted now, the job waits as (ReqNodeNotAvail, Reserved for maintenance) until the window ends.$([ "$se" -gt "$NOW" ] && echo " Largest --time that finishes first if it starts now: $(fmt_dhms $(( se - NOW )))")"
      exit 12
    fi
    echo "PARTIAL OVERLAP: --time=$CHECK reaches into maintenance reservation $name ($scope) $when. The job can still run on nodes outside it; it waits only if it needs those nodes."
    exit 13 ;;
esac

# --- report -----------------------------------------------------------------------------------
if [ $STATE = active ]; then
  echo "maintenance: ACTIVE now, $SCOPE (Slurm reservation $NAME, Flags=MAINT)"
  echo "  started: $(fmt_time "$S_EP")"
  echo "  ends:    $END_TXT"
else
  echo "maintenance: upcoming, $SCOPE (Slurm reservation $NAME, Flags=MAINT)"
  echo "  starts:  $(fmt_time "$S_EP")   (in $(fmt_human "$UNTIL"))"
  echo "  ends:    $END_TXT$([ "$E_EP" != 0 ] && echo "   (lasts $(fmt_human $(( E_EP - S_EP ))))")"
  echo "  largest --time that finishes before the start, if the job starts now: $MAXT (it shrinks as time passes)"
fi
if [ "$OTHERS" -gt 0 ]; then
  echo "  other maintenance reservations:"
  grep -vxF -- "$HEAD" <<<"$LIVE" | while IFS='|' read -r se ee name _ scope; do
    printf '    %s -> %s  %s  (%s)\n' "$(fmt_time "$se")" "$([ "$ee" != 0 ] && fmt_time "$ee" || echo unknown)" "$name" "$scope"
  done
fi
[ -n "$BAD" ] && echo "  note: MAINT reservation with an unreadable StartTime ignored: $BAD"
if [ "$KIND" = cluster ]; then
  echo "  A job whose --time reaches into the window does not start; it waits as"
  echo "  (ReqNodeNotAvail, Reserved for maintenance) and starts after the window. That is expected:"
  echo "  do not cancel and resubmit it. All jobs still running when the window starts are killed: shorten --time,"
  echo "  or checkpoint and resubmit after the window."
else
  echo "  Partial window: only jobs that need these nodes/partition wait (ReqNodeNotAvail, Reserved for"
  echo "  maintenance); jobs that can use other nodes are not held. Do not cancel and resubmit for it."
fi
exit 0
