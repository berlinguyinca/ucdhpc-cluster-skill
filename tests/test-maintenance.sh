#!/usr/bin/env bash
# Tests for ucd-hpc/scripts/maintenance.sh and its callers. Real scripts, real awk/date code.
# The only stand-ins are tiny `scontrol`/`sinfo` commands that print a captured `scontrol show
# reservation` sample (no Slurm on CI). Fixtures: a real whole-cluster capture (one-line form, host names anonymized) plus
# generic, non-UC-Davis samples (multi-line form, other names/flags/scopes, Unknown/(null) times).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/../ucd-hpc/scripts"; M="$S/maintenance.sh"; FX="$HERE/fixtures"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin" "$TMP/empty"
LOG="$TMP/scontrol.log"
cat > "$TMP/bin/scontrol" <<EOF
#!/bin/sh
echo "args=\$* SLURM_TIME_FORMAT=\${SLURM_TIME_FORMAT:-}" >> "$LOG"
case "\$*" in *config*) echo "ClusterName = testcluster"; exit 0 ;; esac
[ -n "\${FIXTURE:-}" ] && cat "\$FIXTURE"
exit "\${SCONTROL_RC:-0}"
EOF
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/sinfo"
chmod +x "$TMP/bin/scontrol" "$TMP/bin/sinfo"
SP="PATH=$TMP/bin:$PATH"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; echo "$2" | sed 's/^/     /'; }
# run NAME EXPECTED_RC REGEX env-assignments... CMD args...   (REGEX prefixed with ! = must not match)
run() {
  local name=$1 rc=$2 pat=$3 out got; shift 3
  out=$(env "$@" 2>&1); got=$?
  [ "$got" = "$rc" ] || { bad "$name (rc $got != $rc)" "$out"; return; }
  if [[ $pat == '!'* ]]; then
    grep -qE -- "${pat#!}" <<<"$out" && { bad "$name (unexpected: ${pat#!})" "$out"; return; }
  else
    grep -qE -- "$pat" <<<"$out" || { bad "$name (no match: $pat)" "$out"; return; }
  fi
  ok "$name"
}
WHOLE="FIXTURE=$FX/reservations-whole-cluster.txt"
GEN="FIXTURE=$FX/reservations-generic.txt"
ACT="FIXTURE=$FX/reservations-active.txt"
NONE="FIXTURE=$FX/reservations-none.txt"
NOW="MAINTENANCE_SH_NOW=2026-11-10 16:00:00"

# --- real capture: one whole-cluster window  ----------------
run "whole-cluster: upcoming whole-cluster"   0 "^maintenance: upcoming, whole cluster \(Slurm reservation maintenance-window" "$SP" "$WHOLE" "$NOW" "$M"
run "whole-cluster: start with tz"            0 "starts:  2026-12-07 06:00:00 P[SD]T +\(in 26d 14h 0m\)" "$SP" "$WHOLE" "$NOW" "$M"
run "whole-cluster: end and length"           0 "ends:    2026-12-14 18:00:00 P[SD]T +\(lasts 7d 12h 0m\)" "$SP" "$WHOLE" "$NOW" "$M"
run "whole-cluster: max time = site notice"  0 "if the job starts now: 26-14:00:00" "$SP" "$WHOLE" "$NOW" "$M"
run "whole-cluster: pending reason explained" 0 "ReqNodeNotAvail, Reserved for maintenance" "$SP" "$WHOLE" "$NOW" "$M"
run "whole-cluster: brief key=value"          0 "^maintenance: state=upcoming scope=cluster start=2026-12-07T06:00:00 end=2026-12-14T18:00:00 tz=P[SD]T max_time_now=26-14:00:00 reservation=maintenance-window other_windows=0$" "$SP" "$WHOLE" "$NOW" "$M" --brief
run "whole-cluster: during window -> active"  0 "^maintenance: ACTIVE now, whole cluster" "$SP" "$WHOLE" "MAINTENANCE_SH_NOW=2026-12-08 10:00:00" "$M"
run "whole-cluster: brief active no max"      0 "^maintenance: state=active .*reservation=maintenance-window" "$SP" "$WHOLE" "MAINTENANCE_SH_NOW=2026-12-08 10:00:00" "$M" --brief
run "whole-cluster: after window -> none"     0 "^maintenance: none" "$SP" "$WHOLE" "MAINTENANCE_SH_NOW=2026-12-15 00:00:00" "$M"
# --check-time: Slurm time forms, boundaries, junk
run "check: short fits"              0 "^OK" "$SP" "$WHOLE" "$NOW" "$M" --check-time 2-00:00:00
run "check: exactly the limit fits"  0 "^OK" "$SP" "$WHOLE" "$NOW" "$M" --check-time 26-14:00:00
run "check: one minute over"        12 "^OVERLAP.*whole-cluster.*maintenance-window.*26-14:00:00" "$SP" "$WHOLE" "$NOW" "$M" --check-time 26-14:01:00
run "check: seconds round up"       12 "^OVERLAP" "$SP" "$WHOLE" "$NOW" "$M" --check-time 26-14:00:01
run "check: minutes form"           12 "^OVERLAP" "$SP" "$WHOLE" "$NOW" "$M" --check-time 99999
run "check: M:S form"                0 "^OK" "$SP" "$WHOLE" "$NOW" "$M" --check-time 90:30
run "check: H:M:S form"              0 "^OK" "$SP" "$WHOLE" "$NOW" "$M" --check-time 12:00:00
run "check: D-H form"                0 "^OK" "$SP" "$WHOLE" "$NOW" "$M" --check-time 7-12
run "check: D-H:M form"             12 "^OVERLAP" "$SP" "$WHOLE" "$NOW" "$M" --check-time 30-0:0
run "check: leading zeros (08)"      0 "^OK" "$SP" "$WHOLE" "$NOW" "$M" --check-time 08-08:08:08
run "check: whitespace trimmed"      0 "^OK" "$SP" "$WHOLE" "$NOW" "$M" --check-time " 1-00:00:00 "
run "check: 0 = no limit"           12 "^OVERLAP" "$SP" "$WHOLE" "$NOW" "$M" --check-time 0
run "check: UNLIMITED"              12 "^OVERLAP" "$SP" "$WHOLE" "$NOW" "$M" --check-time UNLIMITED
run "check: INFINITE"               12 "^OVERLAP" "$SP" "$WHOLE" "$NOW" "$M" --check-time INFINITE
run "check: during window"          12 "^OVERLAP.*in progress since" "$SP" "$WHOLE" "MAINTENANCE_SH_NOW=2026-12-08 10:00:00" "$M" --check-time 1:00
run "check: too many fields"         2 "cannot parse" "$SP" "$WHOLE" "$NOW" "$M" --check-time 1-2:3:4:5
run "check: no silent overflow"      2 "cannot parse" "$SP" "$WHOLE" "$NOW" "$M" --check-time 99999999999999999999
run "check: junk"                    2 "cannot parse" "$SP" "$WHOLE" "$NOW" "$M" --check-time abc
run "check: negative"                2 "cannot parse" "$SP" "$WHOLE" "$NOW" "$M" --check-time -5
run "check: missing value"           2 "usage" "$SP" "$WHOLE" "$NOW" "$M" --check-time
run "bad flag"                       2 "usage" "$M" --nope
run "help works when piped"          0 "usage" bash -s -- --help < "$M"

# --- generic (non-UC-Davis) Slurm: multi-line layout, several windows of different scope -------
run "generic: whole-cluster is headline" 0 "^maintenance: upcoming, whole cluster \(Slurm reservation Q1-downtime" "$SP" "$GEN" "$NOW" "$M"
run "generic: FLEX,MAINT token matched"  0 "starts:  2027-01-04 09:00:00" "$SP" "$GEN" "$NOW" "$M"
run "generic: partial node list listed"  0 "gpu_firmware +\(4 nodes only: gpu\[01-04\]\)" "$SP" "$GEN" "$NOW" "$M"
run "generic: partition scope listed"    0 "lustre_upgrade +\(partition standard\)" "$SP" "$GEN" "$NOW" "$M"
run "generic: no-MAINT name ignored"     0 "!maint-lookalike" "$SP" "$GEN" "$NOW" "$M"
run "generic: finished window ignored"   0 "!old_maint" "$SP" "$GEN" "$NOW" "$M"
run "generic: Unknown StartTime noted"   0 "unreadable StartTime ignored: broken_maint" "$SP" "$GEN" "$NOW" "$M"
run "generic: brief counts others"       0 "scope=cluster .*reservation=Q1-downtime other_windows=2$" "$SP" "$GEN" "$NOW" "$M" --brief
run "generic: fits everything"           0 "^OK" "$SP" "$GEN" "$NOW" "$M" --check-time 5-00:00:00
run "generic: only partial overlapped"  13 "^PARTIAL OVERLAP.*gpu_firmware.*nodes outside it" "$SP" "$GEN" "$NOW" "$M" --check-time 10-00:00:00
run "generic: partition overlap partial" 13 "^PARTIAL OVERLAP.*(gpu_firmware|lustre_upgrade)" "$SP" "$GEN" "$NOW" "$M" --check-time 20-00:00:00
run "generic: cluster overlap wins"     12 "^OVERLAP.*Q1-downtime" "$SP" "$GEN" "$NOW" "$M" --check-time 60-00:00:00
# only partial windows -> headline says so, never "whole cluster"
awk 'BEGIN{RS="";ORS="\n\n"} !/Q1-downtime/' "$FX/reservations-generic.txt" > "$TMP/partial-only.txt"
run "partial only: headline scoped"  0 "^maintenance: upcoming, 4 nodes only" "$SP" "FIXTURE=$TMP/partial-only.txt" "$NOW" "$M"
run "partial only: no whole-cluster" 0 "!whole cluster" "$SP" "FIXTURE=$TMP/partial-only.txt" "$NOW" "$M"
# ACTIVE with EndTime=(null): `date -d "(null)"` parses as a date, so the shape check matters
run "active, end (null) -> unknown"  0 "ends:    unknown" "$SP" "$ACT" "$NOW" "$M"
run "active brief"                   0 "^maintenance: state=active scope=cluster start=2026-11-10T12:00:00 end=unknown" "$SP" "$ACT" "$NOW" "$M" --brief
run "active blocks any job"         12 "^OVERLAP" "$SP" "$ACT" "$NOW" "$M" --check-time 5
run "no reservations -> none"        0 "^maintenance: state=none$" "$SP" "$NONE" "$NOW" "$M" --brief
run "no reservations, nonzero rc"    0 "^maintenance: state=none$" "$SP" "$NONE" "SCONTROL_RC=1" "$NOW" "$M" --brief

# --- cannot read: never claim "none" -------------------------------------------------------------
run "no scontrol -> unknown (3)"     3 "UNKNOWN.*scontrol not found" "PATH=$TMP/empty:/usr/bin:/bin" "$NOW" "$M"
run "no scontrol, brief -> 3"        3 "state=unknown" "PATH=$TMP/empty:/usr/bin:/bin" "$NOW" "$M" --brief
run "scontrol error -> unknown"      3 "failed \(exit 1\)" "$SP" "FIXTURE=/dev/null" "SCONTROL_RC=1" "$NOW" "$M"
run "scontrol timeout -> unknown"    3 "timed out" "$SP" "FIXTURE=/dev/null" "SCONTROL_RC=124" "$NOW" "$M" --check-time 5
# Load / format discipline: exactly one scontrol call, one-line form, standard time format
: > "$LOG"
env "$SP" "$WHOLE" "$NOW" SLURM_TIME_FORMAT=relative bash "$M" >/dev/null 2>&1
[ "$(cat "$LOG")" = "args=-o show reservation SLURM_TIME_FORMAT=standard" ] && ok "one scontrol call, -o, SLURM_TIME_FORMAT=standard" || bad "scontrol call discipline" "$(cat "$LOG")"
run "piped over stdin works"         0 "^maintenance: state=upcoming" "$SP" "$WHOLE" "$NOW" bash -s -- --brief < "$M"

# --- lint-jobscript.sh integration (--no-test: no scheduler here) -------------------------------
L="$S/lint-jobscript.sh"
mkjob() { printf '#!/bin/bash\n#SBATCH --account=a\n#SBATCH --partition=low\n#SBATCH %s\n#SBATCH --mem=1G\n#SBATCH --output=j-%%j.out\nsleep 1\n' "$1" > "$TMP/job.sh"; }
mkjob --time=30-00:00:00
run "lint: warns on overlap"        0 "WARN:  OVERLAP" "$SP" "$WHOLE" "$NOW" bash "$L" "$TMP/job.sh" --no-test
mkjob "-t 30-0"
run "lint: -t D-H form overlaps"    0 "WARN:  OVERLAP" "$SP" "$WHOLE" "$NOW" bash "$L" "$TMP/job.sh" --no-test
mkjob --time=1-0
run "lint: quiet when job fits"     0 "!OVERLAP|maintenance" "$SP" "$WHOLE" "$NOW" bash "$L" "$TMP/job.sh" --no-test
mkjob --time=10-0
run "lint: partial is info only"    0 "info:  PARTIAL OVERLAP" "$SP" "$GEN" "$NOW" bash "$L" "$TMP/job.sh" --no-test
run "lint: unknown is info"         0 "info:  maintenance window not checked" "PATH=$TMP/empty:/usr/bin:/bin" bash "$L" "$TMP/job.sh" --no-test
mkjob --time=30-00:00:00
# piped: no script dir, so it must not run ./maintenance.sh from the cwd (plant a trap there)
printf 'echo PLANTED; exit 12\n' > "$TMP/maintenance.sh"
out=$(cd "$TMP" && env "$SP" "$WHOLE" "$NOW" bash -s -- "$TMP/job.sh" --no-test < "$L" 2>&1)
grep -q PLANTED <<<"$out" && bad "lint piped: ignores ./maintenance.sh" "$out" || ok "lint piped: ignores ./maintenance.sh"
grep -q "maintenance window not checked (maintenance.sh not found" <<<"$out" && ok "lint piped: says not checked" || bad "lint piped: says not checked" "$out"

# --- cluster-context.sh integration (stand-in scontrol answers ClusterName; sinfo prints nothing)
C="$S/cluster-context.sh"
run "context: full report section"  0 "^maintenance: upcoming, whole cluster" "$SP" "$WHOLE" "$NOW" bash "$C"
run "context: --brief passes on"    0 "^maintenance: state=upcoming" "$SP" "$WHOLE" "$NOW" bash "$C" --brief
out=$(cd "$TMP" && env "$SP" "$WHOLE" "$NOW" bash -s -- --brief < "$C" 2>&1); rc=$?
{ [ $rc = 0 ] && ! grep -qiE 'PLANTED|No such file|error' <<<"$out" && grep -q "ReservationName=maintenance-window StartTime=2026-12-07T06:00:00" <<<"$out"; } \
  && ok "context piped: raw MAINT reservation, no errors" || bad "context piped: raw MAINT reservation, no errors" "$out"
out=$(cd "$TMP" && env "$SP" "$GEN" "$NOW" bash -s < "$C" 2>&1)
{ grep -q "ReservationName=Q1-downtime" <<<"$out" && ! grep -q maint-lookalike <<<"$out"; } \
  && ok "context piped: MAINT token only" || bad "context piped: MAINT token only" "$out"

echo; echo "passed=$PASS failed=$FAIL"; [ "$FAIL" = 0 ]
