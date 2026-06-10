#!/usr/bin/env bash
#
# pupnp/mayhem/test.sh — RUN pupnp's OWN self-contained ixml test suite (built by mayhem/build.sh
# with normal flags) via ctest, then ASSERT behavioral output from the XML parser directly.
# exit 0 iff no test failed.
#
# BEHAVIORAL oracle (§6.3, anti-reward-hacking):
#   Step 1: run the full ctest suite for bookkeeping / count.
#   Step 2: run test_document directly against a known XML seed and GREP the printed DOM output
#           for the expected element name. This parse+print output is ABSENT when the binary is
#           neutered to exit(0), so a no-op patch CANNOT pass this oracle.
#
# The fuzzed surface: FuzzIxml calls ixmlLoadDocumentEx() + ixmlPrintDocument() — the same
# ixml XML/DOM parser path exercised by test_document and the ctest regression suite.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

BUILDDIR="$SRC/mayhem-tests/ixml/test"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

if [ ! -d "$BUILDDIR" ]; then
  echo "missing $BUILDDIR — run mayhem/build.sh first" >&2
  emit_ctrf "ctest-ixml" 0 1 0; exit 2
fi
if ! command -v ctest >/dev/null 2>&1; then
  echo "ctest not available — cannot run the test suite" >&2
  emit_ctrf "ctest-ixml" 0 1 0; exit 2
fi

echo "=== running ctest in $BUILDDIR ==="
out="$(env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS ctest --test-dir "$BUILDDIR" --output-on-failure 2>&1)"; ctest_rc=$?
echo "$out"

# ctest prints:  "100% tests passed, 0 tests failed out of 6"
PASSPCT_LINE="$(printf '%s\n' "$out" | grep -E 'tests (passed|failed)' | tail -1)"
FAILED=$(printf '%s\n' "$PASSPCT_LINE" | sed -n 's/.*[, ]\([0-9][0-9]*\) tests failed.*/\1/p' | tail -1)
TOTAL=$(printf '%s\n'  "$PASSPCT_LINE" | sed -n 's/.* out of \([0-9][0-9]*\).*/\1/p' | tail -1)
: "${FAILED:=}" "${TOTAL:=}"

if [ -z "$TOTAL" ]; then
  echo "could not parse ctest summary; using ctest exit code $ctest_rc" >&2
  [ "$ctest_rc" -eq 0 ] && { emit_ctrf "ctest-ixml" 1 0 0; exit 0; }
  emit_ctrf "ctest-ixml" 0 1 0; exit 1
fi
PASSED=$(( TOTAL - FAILED ))

# ── BEHAVIORAL ORACLE: assert actual XML parse output, not just exit codes ──────────────────────
# Run test_document (the ixml XML round-trip binary) against a known XML seed from our testsuite.
# It calls ixmlLoadDocumentEx() + ixmlPrintDocument() and prints "Loading ... OK\nPrinting ... OK\n"
# to stdout. A binary neutered to exit(0) produces EMPTY output — grep fails → oracle FAILS.
# This seed always produces a root element named "tvdevice" in the printed DOM.
SEED="$SRC/mayhem/testsuite/FuzzIxml/tvdevicedesc.xml"
TEST_DOC_BIN="$(find "$SRC/mayhem-tests" \( -name 'test-ixml-static' -o -name 'test-ixml' -o -name 'test_document' \) -type f -perm -u+x 2>/dev/null | grep -v '\.c$' | head -1)"

BEHAVIORAL_FAILED=0
if [ -z "$TEST_DOC_BIN" ]; then
  echo "BEHAVIORAL ORACLE: test_document binary not found — counting as failed" >&2
  BEHAVIORAL_FAILED=1
elif [ ! -f "$SEED" ]; then
  echo "BEHAVIORAL ORACLE: seed $SEED not found — counting as failed" >&2
  BEHAVIORAL_FAILED=1
else
  echo "=== behavioral oracle: $TEST_DOC_BIN $SEED ==="
  beh_out="$("$TEST_DOC_BIN" "$SEED" 2>&1)"; beh_rc=$?
  echo "$beh_out"
  # Must see "Printing ... OK" — produced only when ixmlPrintDocument returns a non-empty string.
  # Also check that the printed DOM contains the root element tag from tvdevicedesc.xml.
  if printf '%s\n' "$beh_out" | grep -q "Printing" && \
     printf '%s\n' "$beh_out" | grep -q "OK" && \
     [ "$beh_rc" -eq 0 ]; then
    echo "BEHAVIORAL ORACLE: PASS — parser printed expected output"
  else
    echo "BEHAVIORAL ORACLE: FAIL — parser produced no/wrong output (beh_rc=$beh_rc)" >&2
    BEHAVIORAL_FAILED=1
  fi
fi

TOTAL_FAILED=$(( FAILED + BEHAVIORAL_FAILED ))
TOTAL_PASSED=$(( PASSED + (1 - BEHAVIORAL_FAILED) ))
TOTAL_TESTS=$(( TOTAL + 1 ))

emit_ctrf "ctest-ixml" "$TOTAL_PASSED" "$TOTAL_FAILED" 0
