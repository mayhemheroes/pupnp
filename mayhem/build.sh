#!/usr/bin/env bash
#
# pupnp/mayhem/build.sh — build pupnp's OSS-Fuzz harness FuzzIxml as a sanitized libFuzzer
# target (+ a standalone reproducer), AND pupnp's OWN self-contained ixml unit/regression
# tests for mayhem/test.sh.
#
# Fuzzed surface: FuzzIxml writes the input bytes to a temp file and loads it as an XML
# document via ixmlLoadDocumentEx() + ixmlPrintDocument() — i.e. it fuzzes pupnp's bundled
# ixml XML/DOM PARSER (ixml/src/*.c). Inputs are XML documents (10..5120 bytes per the harness
# bounds). (The wider pupnp SDK also parses HTTP/SSDP/SOAP, but THIS harness exercises ixml.)
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). We compile the ixml library ITSELF with $SANITIZER_FLAGS (via the
# project's CMake) so the parser code (not just the harness) is instrumented.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
# DEBUG_FLAGS: explicit DWARF-3 so Mayhem triage can read symbols (clang-19 plain -g emits DWARF-5).
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${OUT:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN MAYHEM_JOBS OUT

cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"

# ── Ensure ixml_static is coverage-instrumented ──────────────────────────────────────────────────
# The base image exports SANITIZER_FLAGS with ASan+UBSan but WITHOUT -fsanitize=fuzzer-no-link.
# Since SANITIZER_FLAGS is already set in ENV, the `:=` default above has no effect.
# We unconditionally append fuzzer-no-link so SanitizerCoverage (PC-table + 8-bit counters) is
# emitted into every TU of ixml_static; without it the fuzzer sees 0 edges and makes no progress.
case "$SANITIZER_FLAGS" in
  *fuzzer-no-link*) ;;
  *) SANITIZER_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link" ;;
esac
export SANITIZER_FLAGS

# ── 1) Build ixml (sanitized) + the FuzzIxml libFuzzer target via the project's CMake ─────────────
# -DFUZZER=ON wires fuzzer/CMakeLists.txt to link FuzzIxml against ixml_static + $LIB_FUZZING_ENGINE.
# We feed $SANITIZER_FLAGS through CMAKE_C/CXX_FLAGS so ixml_static (the parser) is instrumented.
# Disable the heavyweight integration tests (they install + reconfigure cmake projects) but keep the
# self-contained ixml unit/regression tests for mayhem/test.sh.
FUZZ_BUILD="$SRC/mayhem-build"
rm -rf "$FUZZ_BUILD"
cmake -S "$SRC" -B "$FUZZ_BUILD" -G Ninja \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DFUZZER=ON -DLIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE" \
  -DUPNP_BUILD_SHARED=OFF -DUPNP_BUILD_STATIC=ON \
  -DUPNP_BUILD_SAMPLES=OFF \
  -DUPNP_ENABLE_TESTING=OFF -DIXML_ENABLE_TESTING=OFF \
  -DIXML_ENABLE_TESTING_INTEGRATION=OFF -DUPNP_ENABLE_TESTING_INTEGRATION=OFF \
  -DCMAKE_BUILD_TYPE=Debug
cmake --build "$FUZZ_BUILD" --target FuzzIxml -j"$MAYHEM_JOBS"

# FuzzIxml lands under the fuzzer/ subdir of the build tree.
FUZZBIN="$(find "$FUZZ_BUILD" -name FuzzIxml -type f -perm -u+x | head -1)"
[ -n "$FUZZBIN" ] || { echo "FuzzIxml not found in $FUZZ_BUILD" >&2; exit 1; }
cp "$FUZZBIN" "$OUT/FuzzIxml"
echo "built FuzzIxml (libFuzzer) -> $OUT/FuzzIxml"

# ── 2) Standalone reproducer: harness + base StandaloneFuzzTargetMain + the sanitized ixml lib ────
IXMLLIB="$(find "$FUZZ_BUILD" -name 'libixml_static.a' -o -name 'libixml.a' | head -1)"
[ -n "$IXMLLIB" ] || { echo "ixml static lib not found in $FUZZ_BUILD" >&2; exit 1; }
$CC $SANITIZER_FLAGS $DEBUG_FLAGS \
  -I"$SRC/ixml/inc" -I"$SRC/upnp/inc" -I"$FUZZ_BUILD/upnp/inc" -I"$FUZZ_BUILD/ixml/inc" \
  "$HARNESS_DIR/FuzzIxml.c" "$STANDALONE_FUZZ_MAIN" "$IXMLLIB" \
  -o "$OUT/FuzzIxml-standalone"
echo "built FuzzIxml-standalone (run-once reproducer) -> $OUT/FuzzIxml-standalone"

# ── 3) Build pupnp's OWN self-contained ixml tests with NORMAL flags (clean tree) so test.sh
#       only RUNS them. These are golden / regression tests over the SAME ixml parser the harness
#       fuzzes: test-ixml parses every testdata XML and prints it back; the poc-* tests are
#       regression checks for fixed parser CVEs (gh-249/506/517, ghsa-hcx4[/utf8]).
#       Integration tests stay OFF (they need install + nested cmake builds). ───────────────────────
TEST_BUILD="$SRC/mayhem-tests"
rm -rf "$TEST_BUILD"
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake -S "$SRC" -B "$TEST_BUILD" -G Ninja \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DUPNP_BUILD_SHARED=OFF -DUPNP_BUILD_STATIC=ON \
    -DUPNP_BUILD_SAMPLES=OFF \
    -DIXML_ENABLE_TESTING=ON -DUPNP_ENABLE_TESTING=OFF \
    -DIXML_ENABLE_TESTING_INTEGRATION=OFF -DUPNP_ENABLE_TESTING_INTEGRATION=OFF \
    -DCMAKE_BUILD_TYPE=Debug
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake --build "$TEST_BUILD" -j"$MAYHEM_JOBS"
echo "built pupnp ixml test suite in mayhem-tests/"

echo "build.sh complete:"
ls -la "$OUT/FuzzIxml" "$OUT/FuzzIxml-standalone" 2>&1 || true
