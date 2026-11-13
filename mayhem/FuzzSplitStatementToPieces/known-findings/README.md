# SplitStatementToPieces: slice-bounds panic

`slice-bounds-panic.sql` (9 bytes: `[;;'@;'';`) makes `sqlparser.Parser.SplitStatementToPieces` panic:

    panic: runtime error: slice bounds out of range [:10] with length 9
    vitess.io/vitess/go/vt/sqlparser.(*Parser).SplitStatementToPieces  go/vt/sqlparser/parser.go:322

Cause: in the `case 0, eofChar:` arm the splitter slices `blob[stmtBegin : blobTail+1]` with
`blobTail := tokenizer.Pos - 1`, but after the tokenizer consumes a trailing unterminated quoted
literal `tokenizer.Pos` can already be past `len(blob)`, so `blobTail+1` exceeds the blob length.

Impact: any caller that splits a client-supplied multi-statement blob (vtgate / vttablet query
paths) can be crashed by a short malformed string, unless it recovers the panic.

Likely fix: clamp the end index to `len(blob)`.

Reproduce: `/mayhem/FuzzSplitStatementToPieces mayhem/FuzzSplitStatementToPieces/known-findings/slice-bounds-panic.sql`.
Kept out of `testsuite/` because seeds are replayed on every run.
