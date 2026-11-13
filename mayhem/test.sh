#!/usr/bin/env bash
#
# mayhem/test.sh — RUN Vitess' own sqlparser test suite plus a known-answer probe, emit CTRF.
# exit 0 = pass. mayhem/build.sh already built both (this script never compiles).
#
#  1) mayhem/_build/sqlparser.test — `go test -c` of go/vt/sqlparser, upstream's suite of
#     parse/format round-trip, normalizer, tokenizer and splitter cases that assert exact output.
#  2) /mayhem/kat — a dynamically linked probe (cgo) that parses fixed SQL and prints the result.
#     A Go test binary is static, so verify-repo's LD_PRELOAD sabotage shim cannot neuter it; the
#     probe can be, and the exact-output assertions below then fail. Probes are unconditional: a
#     missing binary is a failure, never a skip.
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


PASSED=0; FAILED=0; SKIPPED=0

# ── 1) upstream sqlparser suite ──────────────────────────────────────────────────────────────
TESTBIN="$SRC/mayhem/_build/sqlparser.test"
if [ ! -x "$TESTBIN" ]; then
  echo "FAIL: $TESTBIN missing (build.sh should have produced it)" >&2
  emit_ctrf "go-test+kat" 0 1 0; exit 1
fi
OUT="$(mktemp)"
(cd "$SRC/go/vt/sqlparser" && "$TESTBIN" -test.v >"$OUT" 2>&1); rc=$?
tail -5 "$OUT"
count() { grep -cE "^[[:space:]]*--- $1:" "$OUT"; }
PASSED=$(count PASS); FAILED=$(count FAIL); SKIPPED=$(count SKIP)
if [ $(( PASSED + FAILED + SKIPPED )) -eq 0 ]; then
  echo "FAIL: no test results parsed — the suite did not run (exit $rc)" >&2
  emit_ctrf "go-test+kat" 0 1 0; exit 1
fi
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=1; fi

# ── 2) KAT probe ─────────────────────────────────────────────────────────────────────────────
KAT=/mayhem/kat
kat_expect() {  # kat_expect <label> <expected stdout> <kat args...>
  local label="$1" expected="$2"; shift 2
  local got
  got="$("$KAT" "$@" 2>&1)"
  if [ "$got" = "$expected" ]; then
    echo "KAT PASS: $label"; PASSED=$(( PASSED + 1 ))
  else
    echo "KAT FAIL: $label" >&2
    echo "  expected: $expected" >&2
    echo "  got:      $got" >&2
    FAILED=$(( FAILED + 1 ))
  fi
}

kat_expect "format select" \
  "select a, b from t where x = 1 and y = 's' order by a asc limit 5" \
  format "select a,b from t where x=1 and y='s' order by a limit 5"
kat_expect "format create table" \
  "$(printf 'create table t (\n\tid int primary key,\n\t`name` varchar(10) not null default '"'"'x'"'"'\n)')" \
  format "create table t (id int primary key, name varchar(10) not null default 'x')"
kat_expect "format insert on duplicate key" \
  "insert into t(a, b) values (1, 2), (3, 4) on duplicate key update b = values(b)" \
  format "insert into t(a,b) values (1,2),(3,4) on duplicate key update b=values(b)"
kat_expect "format join/group by/having with hint" \
  "select /*+ x */ count(*) from a join b on a.id = b.id group by a.x having count(*) > 1" \
  format "select /*+ x */ count(*) from a join b on a.id=b.id group by a.x having count(*)>1"
kat_expect "normalize literals to bind vars" \
  "$(printf 'select a from t where x = :x /* INT64 */ and y = :y /* VARCHAR */\nx=1\ny=s')" \
  normalize "select a from t where x=1 and y='s'"
kat_expect "split statements" \
  "$(printf 'select 1\nselect 2\ninsert into t values (3)')" \
  split "select 1;select 2;insert into t values (3)"
kat_expect "syntax error" \
  "$(printf 'Code: INVALID_ARGUMENT\nsyntax error at position 12 near '"'"'from'"'"'\n')" \
  error "select from where"

emit_ctrf "go-test+kat" "$PASSED" "$FAILED" "$SKIPPED"
