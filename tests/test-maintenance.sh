#!/usr/bin/env bash
# Tests for ucd-hpc/scripts/maintenance.sh. Real script, real fixture files, throwaway tmpdir.
# The only stand-in is a tiny `scontrol` that cats a captured `scontrol show reservation`
# sample, because no Slurm exists on CI; the parsing under test is the real awk/date code.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
M="$HERE/../ucd-hpc/scripts/maintenance.sh"
FX="$HERE/fixtures"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin"
printf '#!/bin/sh\n[ "$1 $2" = "show reservation" ] && cat "%s/scontrol-reservation.txt"\n' "$FX" > "$TMP/bin/scontrol"
chmod +x "$TMP/bin/scontrol"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; echo "$2" | sed 's/^/     /'; }
# run NAME EXPECTED_RC GREP_PATTERN -- env... -- args...
run() {
  local name=$1 rc=$2 pat=$3; shift 3
  local out got
  out=$(env "$@" 2>&1); got=$?
  [ "$got" = "$rc" ] || { bad "$name (rc $got != $rc)" "$out"; return; }
  grep -qE -- "$pat" <<<"$out" || { bad "$name (no match: $pat)" "$out"; return; }
  ok "$name"
}
NO_SC="MAINT_SKIP_SCONTROL=1"
N="MAINT_NOTICE_FILES=$FX/motd-maintenance"
C="MAINT_NOTICE_FILES=$FX/motd-clean"
BEFORE="MAINT_NOW=2026-11-10 16:00:00"

run "upcoming report"        10 "upcoming.*notice:"                 $NO_SC "$N" "$BEFORE" "$M"
run "start and end parsed"   10 "starts: 2026-12-07 06:00:00"       $NO_SC "$N" "$BEFORE" "$M"
run "end parsed"             10 "ends:   2026-12-14 18:00:00.*7d 12h" $NO_SC "$N" "$BEFORE" "$M"
run "max safe time"          10 "26-14:00:00"                       $NO_SC "$N" "$BEFORE" "$M"
run "mentions pending status" 10 "ReqNodeNotAvail, Reserved for maintenance" $NO_SC "$N" "$BEFORE" "$M"
run "brief"                  10 "^maintenance: upcoming start=2026-12-07 06:00:00 end=2026-12-14 18:00:00 max-safe-time=26-14:00:00$" $NO_SC "$N" "$BEFORE" "$M" --brief
run "active"                 11 "maintenance: active"               $NO_SC "$N" "MAINT_NOW=2026-12-08 10:00:00" "$M"
run "brief active"           11 "ACTIVE since 2026-12-07"           $NO_SC "$N" "MAINT_NOW=2026-12-08 10:00:00" "$M" --brief
run "window over -> none"     0 "none announced"                    $NO_SC "$N" "MAINT_NOW=2026-12-15 00:00:00" "$M"
run "clean motd -> none"      0 "none announced"                    $NO_SC "$C" "$BEFORE" "$M"
run "missing file -> none"    0 "none announced"                    $NO_SC "MAINT_NOTICE_FILES=$TMP/nope" "$BEFORE" "$M"
run "check short job ok"      0 "^OK"                               $NO_SC "$N" "$BEFORE" "$M" --check-time 2-00:00:00
run "check exactly at limit"  0 "^OK"                               $NO_SC "$N" "$BEFORE" "$M" --check-time 26-14:00:00
run "check overlap"          12 "OVERLAP.*26-14:00:00"              $NO_SC "$N" "$BEFORE" "$M" --check-time 30-00:00:00
run "check minutes form"     12 "OVERLAP"                           $NO_SC "$N" "$BEFORE" "$M" --check-time 99999
run "check H:M:S form"        0 "^OK"                               $NO_SC "$N" "$BEFORE" "$M" --check-time 12:00:00
run "check D-H form"          0 "^OK"                               $NO_SC "$N" "$BEFORE" "$M" --check-time 7-12
run "check during window"    12 "OVERLAP"                           $NO_SC "$N" "MAINT_NOW=2026-12-08 10:00:00" "$M" --check-time 1:00
run "check no window"         0 "no maintenance window"             $NO_SC "$C" "$BEFORE" "$M" --check-time 30-00:00:00
run "check bad spec"          2 "cannot parse"                      $NO_SC "$N" "$BEFORE" "$M" --check-time abc
run "bad flag"                2 "usage"                             "$M" --nope
# reservation-only (no notice file), MAINT flag selected, non-MAINT reservation ignored
run "reservation only"       10 "reservation:maintenance-window\(all-nodes\)"            "PATH=$TMP/bin:$PATH" "$C" "$BEFORE" "$M"
run "full-cluster window is the headline" 10 "starts: 2026-12-07"        "PATH=$TMP/bin:$PATH" "$C" "$BEFORE" "$M"
run "partial reservation listed separately" 10 "reservation:partial_maint\(partial\)" "PATH=$TMP/bin:$PATH" "$C" "$BEFORE" "$M"
run "notice+reservation merge" 10 "source: .*(notice:.*reservation:|reservation:.*notice:)" "PATH=$TMP/bin:$PATH" "$N" "$BEFORE" "$M"
# lint-jobscript integration: warns on overlap, silent when it fits (--no-test: no scheduler here)
L="$HERE/../ucd-hpc/scripts/lint-jobscript.sh"
mkjob() { printf '#!/bin/bash\n#SBATCH --account=a\n#SBATCH --partition=low\n#SBATCH --time=%s\n#SBATCH --mem=1G\n#SBATCH --output=j-%%j.out\nsleep 1\n' "$1" > "$TMP/job.sh"; }
mkjob 30-00:00:00
out=$(env "$N" "$BEFORE" $NO_SC bash "$L" "$TMP/job.sh" --no-test 2>&1); grep -q "WARN:  OVERLAP" <<<"$out" && ok "lint warns on overlap (output)" || bad "lint warns on overlap" "$out"
mkjob 1-00:00:00
out=$(env "$N" "$BEFORE" $NO_SC bash "$L" "$TMP/job.sh" --no-test 2>&1); grep -q OVERLAP <<<"$out" && bad "lint quiet when job fits" "$out" || ok "lint quiet when job fits"
# cluster-context shows the section (off-cluster it exits before; only assert it does not crash)
echo; echo "passed=$PASS failed=$FAIL"; [ "$FAIL" = 0 ]
