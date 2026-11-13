#!/usr/bin/env bash
#
# mayhem/build.sh — build Vitess' SQL-parser fuzz harnesses as sanitized libFuzzer binaries
# (go-118-fuzz-build + clang link), the KAT probe, and the sqlparser test binary.
#
# Targets (one Mayhemfile each):
#   /mayhem/FuzzParser                  sqlparser.Parser.Parse
#   /mayhem/FuzzNormalizer              Parse2 + Normalize
#   /mayhem/FuzzSplitStatementToPieces  Parser.SplitStatementToPieces
# And the other upstream OSS-Fuzz fuzzers (go/test/fuzzing/oss_fuzz_build.sh) that build offline,
# listed in mayhem/fuzzsrc/targets.txt: built from a scratch copy of the tree (see below).
# Plus, for mayhem/test.sh:
#   /mayhem/kat                         dynamically linked known-answer probe
#   mayhem/_build/sqlparser.test        upstream's go/vt/sqlparser test binary (normal flags)
#
# Runs in the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. GOROOT/GOPATH/GOMODCACHE
# are pinned by the Dockerfile ENV under /opt/toolchains, so they do not depend on $HOME.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs this script OFFLINE. The first (online)
# build fills $GOMODCACHE; GOPROXY prefers that cache as a file proxy, so the re-run resolves from
# it. go-118-fuzz-build needs its testing shim on the module graph, which we add to a COPY of
# go.mod/go.sum (-modfile) so upstream's go.mod is never edited. Re-running on a built tree works.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SRC:=/mayhem}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# The Go libFuzzer link is ASan-only (as OSS-Fuzz's Go path). An explicit empty
# --build-arg SANITIZER_FLAGS= gives a no-sanitizer build, so default with `=`, not `:=`.
: "${SANITIZER_FLAGS=-fsanitize=address}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS MAYHEM_JOBS
# DWARF < 4 (SPEC §6.2 item 10): Go's gc always emits DWARF4, so the clang-compiled C shims and the
# final link carry DWARF3 and the shim is the first CU.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"

export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOFLAGS="${GOFLAGS:--mod=mod}"
# The testing shim is not in upstream's go.sum, so the offline re-run could not verify it against
# the checksum database; the module cache already holds the verified zip from the first build.
export GOSUMDB="${GOSUMDB:-off}"

cd "$SRC"
go version

BUILD="$SRC/mayhem/_build"
mkdir -p "$BUILD"

# go.mod/go.sum copy that also requires the go-118-fuzz-build testing shim. Order matters: the
# shim is added with `go get` after the copy; a `go mod tidy` would prune it again.
cp -f "$SRC/go.mod" "$BUILD/fuzz.mod"
cp -f "$SRC/go.sum" "$BUILD/fuzz.sum"
FUZZ_FLAGS="-mod=mod -modfile=$BUILD/fuzz.mod"
GOFLAGS="$FUZZ_FLAGS" go get github.com/AdamKorcz/go-118-fuzz-build/testing

# The harness ships as .go.src; stage it as a real _test.go in its own directory. The leading
# underscore keeps `go build ./...` / `go test ./...` away from it.
HARNESS_DIR="$SRC/mayhem/_harness/sqlparser"
mkdir -p "$HARNESS_DIR"
cp -f "$SRC/mayhem/harness_sqlparser_test.go.src" "$HARNESS_DIR/harness_test.go"

SHIM_O="$BUILD/go_runtime_ready.o"
# shellcheck disable=SC2086
$CC $GO_DEBUG_FLAGS -c "$SRC/mayhem/go_runtime_ready.c" -o "$SHIM_O"
LSAN_O="$BUILD/lsan_off.o"
$CXX $SANITIZER_FLAGS $GO_DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$LSAN_O"

# build_target <fuzz-func>   (the binary is named after the function: the legacy target name)
build_target() {
  local func="$1"
  echo "=== building $func (go-118-fuzz-build) ==="
  GOFLAGS="$FUZZ_FLAGS" go-118-fuzz-build -o "$BUILD/$func.a" -func "$func" "$HARNESS_DIR"
  # shellcheck disable=SC2086  # the flag lists are intentionally word-split
  $CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SHIM_O" "$LSAN_O" "$BUILD/$func.a" -o "$SRC/$func"
  echo "built $SRC/$func"
}

build_target FuzzParser
build_target FuzzNormalizer
build_target FuzzSplitStatementToPieces

# ── Upstream OSS-Fuzz fuzzers (mayhem/fuzzsrc/targets.txt) ───────────────────────────────────
# Upstream's fuzzers are `func FuzzX(data []byte) int` behind `//go:build gofuzz`, and need some
# _test.go helpers renamed to ordinary files (go/test/fuzzing/oss_fuzz_build.sh). That script is
# bit-rotted at this commit, so we repeat its renames and apply mayhem/fuzzsrc/ossfuzz-fixes.patch
# (gofuzz tags dropped, compile fixes, the helpers sliced out of the _test files) -- all on a scratch
# COPY of go/, so the committed tree stays untouched. A thin testing.F wrapper per target feeds
# libFuzzer's bytes to the upstream function.
FS="$BUILD/fuzzsrc"
rm -rf "$FS"
mkdir -p "$FS"
cp -a "$SRC/go" "$SRC/go.mod" "$SRC/go.sum" "$FS/"
[ -d "$SRC/config" ] && cp -a "$SRC/config" "$FS/"
(
  cd "$FS"
  mv go/vt/vttablet/tabletmanager/vreplication/framework_test.go go/vt/vttablet/tabletmanager/vreplication/framework_fuzz.go
  mv go/vt/vtgate/vindexes/consistent_lookup_test.go go/vt/vtgate/vindexes/consistent_lookup_test_fuzz.go
  mv go/vt/vtgate/engine/fake_vcursor_test.go go/vt/vtgate/engine/fake_vcursor.go
  mv go/vt/vtgate/planbuilder/plan_test.go go/vt/vtgate/planbuilder/plan_test_fuzz.go
  mv go/vt/vttablet/tabletserver/testutils_test.go go/vt/vttablet/tabletserver/testutils_fuzz.go
  mv go/mysql/collations/colldata/uca_test.go go/mysql/collations/colldata/uca_test_fuzz.go
  mv go/vt/vtgate/grpcvtgateconn/suite_test.go go/vt/vtgate/grpcvtgateconn/suite_test_fuzz.go
  mv go/vt/vtgate/grpcvtgateconn/fuzz_flaky_test.go go/vt/vtgate/grpcvtgateconn/fuzz.go
  patch -p1 -E -s < "$SRC/mayhem/fuzzsrc/ossfuzz-fixes.patch"
  # FuzzAPIMarshal: regenerate upstream's autogenerated marshal fuzzer, then repair it.
  (cd go/vt && grep -r ') Unmarshal' . > /tmp/marshal_targets.txt)
  (cd go/test/fuzzing/autogenerate && go run convert_grep_to_fuzzer.go)
  mkdir -p go/test/fuzzing/amtest
  python3 "$SRC/mayhem/fuzzsrc/fix_api_marshal.py" go/test/fuzzing/autogenerate/api_marshal_fuzzer.go \
    go/test/fuzzing/amtest/api_marshal_fuzzer.go amtest
  rm -f go/test/fuzzing/autogenerate/api_marshal_fuzzer.go
)

build_upstream_target() {
  local name="$1" pkgdir="$2" fn="$3"
  local hdir="$FS/mayhem/_harness/$name"
  mkdir -p "$hdir"
  cat > "$hdir/harness_test.go" <<GO
package harness

import (
	"log/slog"
	"testing"

	"vitess.io/vitess/go/vt/log"
	upstream "vitess.io/vitess/$pkgdir"
)

func init() {
	// the vitess logger writes an ERROR line per rejected input to stderr; drop it (set once, input-independent)
	log.SwapLogger(slog.New(slog.DiscardHandler))
}

func $name(f *testing.F) {
	f.Fuzz(func(t *testing.T, data []byte) {
		upstream.$fn(data)
	})
}
GO
  echo "=== building $name (upstream $pkgdir.$fn) ==="
  (cd "$FS" && GOFLAGS="$FUZZ_FLAGS" go-118-fuzz-build -o "$BUILD/$name.a" -func "$name" "$hdir")
  # shellcheck disable=SC2086
  $CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SHIM_O" "$LSAN_O" "$BUILD/$name.a" -o "$SRC/$name"
  rm -f "$BUILD/$name.a"
  echo "built $SRC/$name"
}

while read -r name pkgdir fn; do
  case "$name" in ''|'#'*) continue ;; esac
  build_upstream_target "$name" "$pkgdir" "$fn"
done < "$SRC/mayhem/fuzzsrc/targets.txt"

# ── Oracle artifacts: NORMAL flags (no sanitizer, no fuzz instrumentation). ─────────────────
# cgo => externally linked => dynamically linked, so verify-repo's LD_PRELOAD sabotage shim can
# neuter it. Assert that, so a toolchain change cannot silently weaken the oracle.
echo "=== building /mayhem/kat (KAT probe, dynamically linked) ==="
CGO_ENABLED=1 CGO_CFLAGS="$GO_DEBUG_FLAGS" go build -mod=mod -o "$SRC/kat" ./mayhem/kat
file "$SRC/kat" | grep 'dynamically linked' >/dev/null \
  || { echo "FATAL: $SRC/kat is not dynamically linked; the sabotage check could not neuter it" >&2; exit 1; }

echo "=== building upstream sqlparser test binary ==="
go test -mod=mod -c -o "$BUILD/sqlparser.test" ./go/vt/sqlparser

echo "build.sh complete"
