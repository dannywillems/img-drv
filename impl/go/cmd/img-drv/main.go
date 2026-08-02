// Command img-drv is the command line entry point, so CI and a laptop run the
// same code.
//
//	img-drv verify <dir>      recompute every store path
//	img-drv roundtrip <dir>   parse then re-serialize, byte for byte
//	img-drv canonical <dir>   canonicalizing must change nothing
//	img-drv examples <dir>    emit the conformance corpus
//	img-drv transpile <dir>   emit the same corpus as .nix source
//
// All exit non-zero on any failure, which is what makes them usable as CI
// gates. The subcommands and their output match the Python and Rust
// implementations', so the same Makefile target can drive any of them.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	imgdrv "github.com/dannywillems/img-drv/impl/go"
	"github.com/dannywillems/img-drv/impl/go/nix"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: img-drv [verify|roundtrip|canonical|examples|transpile] <directory>")
		os.Exit(2)
	}
	command, directory := os.Args[1], os.Args[2]
	if command != "examples" && command != "transpile" {
		if info, err := os.Stat(directory); err != nil || !info.IsDir() {
			fmt.Fprintf(os.Stderr, "not a directory: %s\n", directory)
			os.Exit(2)
		}
	}
	var code int
	var err error
	switch command {
	case "verify":
		code, err = verify(directory)
	case "roundtrip":
		code, err = roundtrip(directory)
	case "canonical":
		code, err = canonicalCheck(directory)
	case "examples":
		code, err = emitExamples(directory)
	case "transpile":
		code, err = transpile(directory)
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n", command)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	os.Exit(code)
}

func verify(directory string) (int, error) {
	corpus, err := imgdrv.LoadCorpus(directory)
	if err != nil {
		return 0, err
	}
	checked, bad := corpus.Verify()
	for _, m := range bad {
		fmt.Printf("FAIL %s\n", m)
	}
	fmt.Printf("%d/%d output paths reproduced from %d derivations\n",
		checked-len(bad), checked, corpus.Len())
	return boolToCode(len(bad) > 0), nil
}

func roundtrip(directory string) (int, error) {
	files, err := drvFiles(directory)
	if err != nil {
		return 0, err
	}
	ok, bad := 0, 0
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			return 0, err
		}
		text := strings.TrimRight(string(raw), "\n")
		d, err := imgdrv.Parse(text)
		switch {
		case err != nil:
			bad++
			fmt.Printf("PARSE ERROR %s: %s\n", filepath.Base(f), err)
		case imgdrv.Unparse(d) != text:
			bad++
			fmt.Printf("ROUND-TRIP DIFFERS: %s\n", filepath.Base(f))
		default:
			ok++
		}
	}
	fmt.Printf("%d/%d round-tripped byte-identically\n", ok, ok+bad)
	return boolToCode(bad > 0), nil
}

func canonicalCheck(directory string) (int, error) {
	files, err := drvFiles(directory)
	if err != nil {
		return 0, err
	}
	ok, bad := 0, 0
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			return 0, err
		}
		d, err := imgdrv.Parse(string(raw))
		if err != nil {
			return 0, err
		}
		if imgdrv.Canonical(d).Equal(d) {
			ok++
		} else {
			bad++
			fmt.Printf("NOT CANONICAL: %s\n", filepath.Base(f))
		}
	}
	fmt.Printf("%d/%d real derivations are already canonical\n", ok, ok+bad)
	return boolToCode(bad > 0), nil
}

// emitExamples writes every intent in the conformance corpus, named as in the
// store.
//
// The FILENAME is the derivation's own computed store path, so a wrong hash
// shows up as a differently named file rather than as differing content, and
// make conformance catches both.
func emitExamples(directory string) (int, error) {
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return 0, err
	}
	corpus := imgdrv.ExampleCorpus()
	for _, e := range corpus {
		if _, err := e.Drv.Write(directory); err != nil {
			return 0, err
		}
	}
	fmt.Printf("%d derivations written to %s\n", len(corpus), directory)
	return 0, nil
}

// transpile writes each intent as a .nix expression, for real Nix to
// instantiate.
//
// The other half of the commuting square: examples emits the IR directly, this
// emits source that must produce the SAME bytes when Nix evaluates it. Names
// match the goldens so scripts/transpile-check.sh can pair them up.
func transpile(directory string) (int, error) {
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return 0, err
	}
	corpus := nix.Corpus()
	for _, e := range corpus {
		name := strings.TrimSuffix(e.Name, ".drv") + ".nix"
		target := filepath.Join(directory, name)
		body := nix.ToNix(e.Expr) + "\n"
		if err := os.WriteFile(target, []byte(body), 0o644); err != nil {
			return 0, err
		}
	}
	fmt.Printf("%d expressions written to %s\n", len(corpus), directory)
	return 0, nil
}

func drvFiles(directory string) ([]string, error) {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return nil, err
	}
	out := []string{}
	for _, e := range entries {
		if !e.IsDir() && filepath.Ext(e.Name()) == ".drv" {
			out = append(out, filepath.Join(directory, e.Name()))
		}
	}
	sort.Strings(out)
	return out, nil
}

func boolToCode(failed bool) int {
	if failed {
		return 1
	}
	return 0
}
