// mayhem/kat — known-answer probe for mayhem/test.sh (a behavioral oracle).
//
//	kat format    <sql>   prints the canonical re-rendering of the parsed statement
//	kat normalize <sql>   prints the normalized statement, then one `name=value` line per bind var
//	kat split     <sql>   prints each statement of a multi-statement blob on its own line
//	kat error     <sql>   prints the parse error for invalid SQL
package main

import (
	"fmt"
	"os"
	"sort"

	querypb "vitess.io/vitess/go/vt/proto/query"
	"vitess.io/vitess/go/vt/sqlparser"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: kat format|normalize|split|error <sql>")
		os.Exit(2)
	}
	cmd, sql := os.Args[1], os.Args[2]
	parser := sqlparser.NewTestParser()

	switch cmd {
	case "format":
		stmt, err := parser.Parse(sql)
		if err != nil {
			fail(err)
		}
		fmt.Println(sqlparser.String(stmt))
	case "normalize":
		stmt, reserved, err := parser.Parse2(sql)
		if err != nil {
			fail(err)
		}
		bv := make(map[string]*querypb.BindVariable)
		res, err := sqlparser.Normalize(stmt, sqlparser.NewReservedVars("bv", reserved), bv,
			true, "ks", 0, "", map[string]string{}, nil, nil)
		if err != nil {
			fail(err)
		}
		fmt.Println(sqlparser.String(res.AST))
		names := make([]string, 0, len(bv))
		for name := range bv {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			fmt.Printf("%s=%s\n", name, string(bv[name].Value))
		}
	case "split":
		pieces, err := parser.SplitStatementToPieces(sql)
		if err != nil {
			fail(err)
		}
		for _, p := range pieces {
			fmt.Println(p)
		}
	case "error":
		if _, err := parser.Parse(sql); err != nil {
			fmt.Println(err)
			return
		}
		fail(fmt.Errorf("expected a parse error for %q", sql))
	default:
		fmt.Fprintln(os.Stderr, "unknown command", cmd)
		os.Exit(2)
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "kat:", err)
	os.Exit(1)
}
