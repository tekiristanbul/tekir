//go:build ignore

// Command gosyntaxcheck parses each .go file path given as an argument and
// reports a syntax error if any — a stand-in for `gofmt -l`/`go build`'s
// syntax check that this development sandbox's broken GOROOT couldn't run
// (see this change's PR description for the full explanation). Excluded
// from the module's real build graph by the "ignore" build tag above, so
// `go build ./...`/`go test ./...`/`go vet ./...` never see it — but this
// directory could not be deleted from this sandboxed session (rm/mv were
// both denied here) and should be removed entirely by a human before this
// branch merges; it was never meant to ship.
package main

import (
	"fmt"
	"go/parser"
	"go/token"
	"os"
)

func main() {
	fset := token.NewFileSet()
	ok := true
	for _, path := range os.Args[1:] {
		if _, err := parser.ParseFile(fset, path, nil, parser.AllErrors); err != nil {
			fmt.Fprintf(os.Stderr, "%s: %v\n", path, err)
			ok = false
		} else {
			fmt.Printf("%s: OK\n", path)
		}
	}
	if !ok {
		os.Exit(1)
	}
}
