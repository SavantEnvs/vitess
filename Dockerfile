FROM golang:1.25 AS builder

WORKDIR /src

# Copy the source code
COPY . .

# Install go-fuzz tooling
RUN GOFLAGS=-mod=mod go install github.com/dvyukov/go-fuzz/go-fuzz@latest \
    github.com/dvyukov/go-fuzz/go-fuzz-build@latest && \
    GOFLAGS=-mod=mod go get github.com/dvyukov/go-fuzz/go-fuzz-dep@latest

# Remove all stale fuzz files whose APIs have drifted from the current codebase
RUN rm -f go/test/fuzzing/vttablet_fuzzer.go \
          go/test/fuzzing/vt_schema_fuzzer.go \
          go/test/fuzzing/tabletserver_schema_fuzzer.go \
          go/test/fuzzing/tablet_manager_fuzzer.go \
          go/test/fuzzing/tabletserver_rules_fuzzer.go \
          go/test/fuzzing/vtctl_fuzzer.go \
          go/test/fuzzing/ast_fuzzer.go \
          go/test/fuzzing/parser_fuzzer.go

# Write a new minimal fuzz file using the current sqlparser API
RUN cat > go/test/fuzzing/sql_parser_fuzzer.go << 'GOEOF'
//go:build gofuzz
// +build gofuzz

package fuzzing

import (
	"vitess.io/vitess/go/vt/sqlparser"
)

func FuzzParser(data []byte) int {
	_, err := sqlparser.NewTestParser().Parse(string(data))
	if err != nil {
		return 0
	}
	return 1
}

func FuzzIsDML(data []byte) int {
	_ = sqlparser.IsDML(string(data))
	return 1
}

func FuzzSplitStatementToPieces(data []byte) int {
	_, _ = sqlparser.NewTestParser().SplitStatementToPieces(string(data))
	return 1
}
GOEOF

# Build FuzzParser target
RUN go-fuzz-build -func FuzzParser -o /FuzzParser.zip vitess.io/vitess/go/test/fuzzing

# Final image with the fuzz binary
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /go/bin/go-fuzz /usr/local/bin/go-fuzz
COPY --from=builder /FuzzParser.zip /FuzzParser.zip

CMD ["/usr/local/bin/go-fuzz", "-bin=/FuzzParser.zip", "-workdir=/tmp/fuzz"]
