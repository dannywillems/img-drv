// Command img-drv is the command line entry point, so CI and a laptop run the
// same code.
//
//	img-drv verify <dir>      recompute every store path
//	img-drv roundtrip <dir>   parse then re-serialize, byte for byte
//	img-drv canonical <dir>   canonicalizing must change nothing
//	img-drv examples <dir>    emit the conformance corpus
//	img-drv transpile <dir>   emit the same corpus as .nix source
//	img-drv parsecheck <dir>  parse real .nix files, diff the tree
//	img-drv reparse <dir>     parse what we emitted; must be the same tree
//	img-drv worked <dir>      emit the worked example
//
// All exit non-zero on any failure, which is what makes them usable as CI
// gates. The subcommands and their output match the Python and Rust
// implementations', so the same Makefile target can drive any of them.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"

	imgdrv "github.com/dannywillems/img-drv/impl/go"
	"github.com/dannywillems/img-drv/impl/go/nix"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: img-drv [verify|roundtrip|canonical|examples|transpile|parsecheck|reparse|worked] <dir>")
		os.Exit(2)
	}
	command, directory := os.Args[1], os.Args[2]
	if command != "examples" && command != "transpile" && command != "worked" {
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
	case "parsecheck":
		code, err = parsecheck(directory)
	case "reparse":
		code, err = reparse(directory)
	case "worked":
		code, err = worked(directory)
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

// parsecheck differential-tests the PARSER against real Nix.
//
// directory holds pairs: x.nix is the source and x.expected is what the pinned
// nix-instantiate --parse printed for it. We parse and print in the same form;
// the two must match byte for byte, which pins tree SHAPE rather than merely
// "it parsed".
func parsecheck(directory string) (int, error) {
	// Nix expands ~ at parse time, so the harness records the oracle's HOME.
	home := ""
	if b, err := os.ReadFile(filepath.Join(directory, "home")); err == nil {
		home = strings.TrimSpace(string(b))
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		return 0, err
	}
	names := []string{}
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".expected") {
			names = append(names, strings.TrimSuffix(e.Name(), ".expected"))
		}
	}
	sort.Strings(names)

	ok, bad := 0, 0
	for _, base := range names {
		origin := base
		if b, err := os.ReadFile(filepath.Join(directory, base+".path")); err == nil {
			origin = strings.TrimSpace(string(b))
		}
		wantBytes, err := os.ReadFile(filepath.Join(directory, base+".expected"))
		if err != nil {
			return 0, err
		}
		want := strings.TrimSpace(string(wantBytes))
		src, err := os.ReadFile(filepath.Join(directory, base+".nix"))
		if err != nil {
			return 0, err
		}
		got, perr := nix.ParseAndPrint(string(src), filepath.Dir(origin), home)
		if perr != nil {
			bad++
			if bad <= 5 {
				fmt.Printf("PARSE FAILED %s: %v\n", origin, perr)
			}
			continue
		}
		if strings.TrimSpace(got) == want {
			ok++
			continue
		}
		bad++
		if bad <= 5 {
			reportDiff(origin, want, strings.TrimSpace(got))
		}
	}
	fmt.Printf("%d/%d real nixpkgs expressions parse to the same tree as Nix\n",
		ok, ok+bad)
	if bad > 0 {
		return 1, nil
	}
	return 0, nil
}

// worked emits the worked example: a real package, through a real overlay.
func worked(directory string) (int, error) {
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return 0, err
	}
	body := nix.ToNix(nix.WorkedExample()) + "\n"
	target := filepath.Join(directory, "worked-example.nix")
	if err := os.WriteFile(target, []byte(body), 0o644); err != nil {
		return 0, err
	}
	fmt.Println("worked example written")
	return 0, nil
}

// reparse checks the RETRACTION law: parsing what we printed gives the same
// tree.
//
// emit and parse are the two arrows between EXPR and source text, and their law
// is parse(emit(e)) == e, up to the three semantic no-ops named in
// nix/normalize.go. That makes emit . parse idempotent: a canonical-form
// projection on source text.
//
// It is nearly free, because every file in the parser's corpus is a term to
// test emit on, and it moves that corpus from the arrow that was already
// well-tested to the one that was not.
func reparse(directory string) (int, error) {
	home := ""
	if b, err := os.ReadFile(filepath.Join(directory, "home")); err == nil {
		home = strings.TrimSpace(string(b))
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		return 0, err
	}
	names := []string{}
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".nix") {
			names = append(names, strings.TrimSuffix(e.Name(), ".nix"))
		}
	}
	sort.Strings(names)

	ok, bad := 0, 0
	for _, base := range names {
		origin := base
		if b, err := os.ReadFile(filepath.Join(directory, base+".path")); err == nil {
			origin = strings.TrimSpace(string(b))
		}
		src, err := os.ReadFile(filepath.Join(directory, base+".nix"))
		if err != nil {
			return 0, err
		}
		dir := filepath.Dir(origin)
		tree, perr := nix.Parse(string(src), dir, home)
		if perr != nil {
			continue
		}
		printed := nix.ToNix(tree)
		again, perr := nix.Parse(printed, dir, home)
		if perr != nil {
			bad++
			if bad <= 5 {
				fmt.Printf("EMITTED SOURCE DOES NOT PARSE %s: %v\n", origin, perr)
			}
			continue
		}
		if reflect.DeepEqual(nix.Normalize(again), nix.Normalize(tree)) {
			ok++
			continue
		}
		bad++
		if bad <= 5 {
			fmt.Printf("ROUND TRIP DIFFERS %s\n", origin)
		}
	}
	fmt.Printf("%d/%d real expressions survive emit then parse unchanged\n",
		ok, ok+bad)
	if bad > 0 {
		return 1, nil
	}
	return 0, nil
}

// reportDiff shows the first divergence with a window either side. Real
// expressions print to thousands of characters, so showing both in full says
// nothing.
func reportDiff(origin, want, got string) {
	d := 0
	for d < len(want) && d < len(got) && want[d] == got[d] {
		d++
	}
	window := func(s string) string {
		from := max(0, d-30)
		to := min(len(s), from+90)
		return s[from:to]
	}
	fmt.Printf("MISMATCH %s (at offset %d)\n", origin, d)
	fmt.Printf("  want ...%s...\n", window(want))
	fmt.Printf("  got  ...%s...\n", window(got))
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
