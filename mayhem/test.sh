#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# crun's upstream C unit tests (TAP output) were built by build.sh into mayhem/.build-test.
# Each assertion line is `ok N - name`, `ok N - name #SKIP` or `not ok N - name`; a binary that dies
# or prints no `1..N` plan counts as a failure, so a neutered program cannot pass.
BUILD="$SRC/mayhem/.build-test"
UNIT_TESTS="tests_libcrun_utils tests_libcrun_ring_buffer tests_libcrun_errors tests_libcrun_intelrdt tests_libcrun_terminal tests_libcrun_custom_handler tests_libcrun_linux tests_libcrun_signals tests_libcrun_mount_flags tests_libcrun_chroot_realpath tests_libcrun_seccomp_notify tests_libcrun_cgroup"

passed=0; failed=0; skipped=0
cd "$BUILD"
for t in $UNIT_TESTS; do
  bin="tests/$t"
  if [ ! -x "$bin" ]; then
    echo "missing test binary $bin (mayhem/build.sh should have built it)" >&2
    failed=$((failed + 1)); continue
  fi
  out="$("$bin" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -eq 77 ]; then
    skipped=$((skipped + 1)); continue
  fi
  p=$(printf '%s\n' "$out" | grep -cE '^ok [0-9]+' || true)
  sk=$(printf '%s\n' "$out" | grep -cE '^ok [0-9]+.*#SKIP' || true)
  f=$(printf '%s\n' "$out" | grep -cE '^not ok' || true)
  plan=$(printf '%s\n' "$out" | grep -cE '^1\.\.[0-9]+$' || true)
  if [ "$plan" -ne 1 ] || [ "$p" -eq 0 ] || { [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; }; then
    f=$((f + 1))
  fi
  passed=$((passed + p - sk)); skipped=$((skipped + sk)); failed=$((failed + f))
done

emit_ctrf "crun-tap" "$passed" "$failed" "$skipped"
