#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# crun's own autogen.sh runs `git submodule update`, which needs the network: the submodules
# (libocispec and its spec submodules) are already in the tree, so regenerate the build system directly.
mkdir -p m4
autoreconf -fi

# Out-of-tree build dirs, gitignored via mayhem/.gitignore (they must not survive `git clean -ffdX`).
FUZZ_BUILD="$SRC/mayhem/.build-fuzz"
TEST_BUILD="$SRC/mayhem/.build-test"
rm -rf "$FUZZ_BUILD" "$TEST_BUILD"
CONFIGURE_OPTS=(--enable-embedded-blake3 --disable-dependency-tracking)

# 1) The project itself, sanitized, with DWARF 3. Configure's run-tests are linked with ASan, so
#    leak detection is off for the build tools only (the fuzz binaries get it off via lsan_off.c).
mkdir "$FUZZ_BUILD"
(
  cd "$FUZZ_BUILD"
  export ASAN_OPTIONS=detect_leaks=0
  "$SRC/configure" CC="$CC" CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" LDFLAGS="$SANITIZER_FLAGS" "${CONFIGURE_OPTS[@]}"
  make git-version.h .version
  # libocispec generates the headers libcrun includes, so it has to finish first.
  # libFuzzer coverage instrumentation goes on the project objects (compile time only, so configure's
  # own link checks do not need the fuzzer runtime).
  FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
  make -j"$MAYHEM_JOBS" CFLAGS="$FUZZ_CFLAGS" libocispec/libocispec.la
  make -j"$MAYHEM_JOBS" CFLAGS="$FUZZ_CFLAGS" libcrun_testing.la
)

# 2) Harnesses (mayhem/fuzz_crun.c wraps tests/tests_libcrun_fuzzer.c), each fixed to one FUZZING_MODE of
#    the upstream harness, linked twice: libFuzzer and the standalone run-once reproducer.
INCS=(-DHAVE_CONFIG_H -I"$FUZZ_BUILD" -I"$FUZZ_BUILD/src" -I"$SRC/src" -I"$SRC/libocispec/src" -I"$FUZZ_BUILD/libocispec/src")
LIBS=("$FUZZ_BUILD/.libs/libcrun_testing.a" "$FUZZ_BUILD/libocispec/.libs/libocispec.a" -lsystemd -lseccomp -lcap -ljson-c)

FUZZ_CC_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.c" -o "$FUZZ_BUILD/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FUZZ_BUILD/standalone_main.o"

# <target> <FUZZING_MODE of tests/tests_libcrun_fuzzer.c; 100 = the string parsers (3,6,7,8,9)>
TARGETS=(
  "fuzz-crun-seccomp 2"
  "fuzz-crun-paths 4"
  "fuzz-crun-ebpf 5"
  "fuzz-crun-parsers 100"
)
for entry in "${TARGETS[@]}"; do
  read -r name mode <<<"$entry"
  $CC $FUZZ_CC_FLAGS -DFUZZ_MODE="$mode" -c "$SRC/mayhem/fuzz_crun.c" "${INCS[@]}" -o "$FUZZ_BUILD/$name.o"
  $CC $FUZZ_CC_FLAGS $LIB_FUZZING_ENGINE "$FUZZ_BUILD/$name.o" "$FUZZ_BUILD/lsan_off.o" "${LIBS[@]}" -o "/mayhem/$name"
  $CC $FUZZ_CC_FLAGS "$FUZZ_BUILD/$name.o" "$FUZZ_BUILD/standalone_main.o" "$FUZZ_BUILD/lsan_off.o" "${LIBS[@]}" -o "/mayhem/$name-standalone"
done

# 3) The upstream C unit tests (TAP), built with the project's NORMAL flags; mayhem/test.sh only runs them.
UNIT_TESTS="tests/tests_libcrun_utils tests/tests_libcrun_ring_buffer tests/tests_libcrun_errors tests/tests_libcrun_intelrdt tests/tests_libcrun_terminal tests/tests_libcrun_custom_handler tests/tests_libcrun_linux tests/tests_libcrun_signals tests/tests_libcrun_mount_flags tests/tests_libcrun_chroot_realpath tests/tests_libcrun_seccomp_notify tests/tests_libcrun_cgroup"
mkdir "$TEST_BUILD"
(
  cd "$TEST_BUILD"
  env -u CFLAGS -u LDFLAGS "$SRC/configure" CC="$CC" CFLAGS="-g -O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" "${CONFIGURE_OPTS[@]}"
  make git-version.h .version
  make -j"$MAYHEM_JOBS" libocispec/libocispec.la
  make -j"$MAYHEM_JOBS" $UNIT_TESTS
)
