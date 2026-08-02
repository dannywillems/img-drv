package imgdrv

import (
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// The eDSL surface: DESCRIBE a build, and get a derivation back.
//
// This file is where the falsification test in docs/theory.md actually bites,
// so the awkward parts are commented as findings rather than apologised for.
// Nothing here turned out to be INEXPRESSIBLE; several things turned out to be
// unenforceable, which is a different and more interesting result. See
// README.md for the tally.

// HashAlgo is one of the hash algorithms Nix accepts for a fixed-output
// derivation.
//
// FINDING. This is a finite sum, and Go cannot express one. A defined string
// type with constants is the closest idiom, and it buys strictly less than
// Rust's enum or Python's Literal:
//
//   - any string literal converts to it, so HashAlgo("sha3") compiles;
//   - a switch over it has no exhaustiveness check, so a fifth algorithm added
//     later compiles everywhere and is simply not handled.
//
// The compensation is a runtime Valid check on every construction path. That
// is a real cost, and it is exactly the cost the Go implementation exists to
// measure.
type HashAlgo string

// The algorithms Nix accepts. The empty value means "read it from an SRI
// hash", which is a third state this type cannot distinguish from a typo.
const (
	SHA256 HashAlgo = "sha256"
	SHA512 HashAlgo = "sha512"
	SHA1   HashAlgo = "sha1"
	MD5    HashAlgo = "md5"
)

var digestBytes = map[HashAlgo]int{MD5: 16, SHA1: 20, SHA256: 32, SHA512: 64}

// Valid reports whether the algorithm is one Nix accepts.
//
// In Rust this function does not exist, because the value cannot be wrong.
func (a HashAlgo) Valid() bool {
	_, ok := digestBytes[a]
	return ok
}

// HashMode is how the output is ingested: a single file, or a NAR of a
// directory tree.
//
// Recursive is what puts the r: prefix on the serialized algorithm, and
// r:sha256 selects an entirely different store-path scheme.
//
// FINDING. A second finite sum, encoded a THIRD way: the zero value doubles as
// the default. That is idiomatic Go and genuinely convenient, but note that
// this file now carries three different encodings of "optional" (this one, the
// Declared bool in Outputs, and the nil pointer in Build.FixedOutput). In
// Python and Rust all three are one type. Go's lack of a sum type does not stop
// you saying any of it; it stops you saying it the SAME WAY twice.
type HashMode string

// The ingestion modes. The zero value is Flat.
const (
	Flat      HashMode = "flat"
	Recursive HashMode = "recursive"
)

func (m HashMode) orDefault() HashMode {
	if m == "" {
		return Flat
	}
	return m
}

// The errors a description can fail with.
//
// FINDING. In Python and Rust this is one sum type with a case per failure, and
// the compiler checks that a match handles all of them. Here it is a set of
// sentinel values compared with errors.Is, which is idiomatic and gives callers
// no help at all in noticing a new case.
var (
	ErrInvalidName         = errors.New("not a valid store path name")
	ErrEmptyOutputs        = errors.New("outputs must not be empty")
	ErrDuplicateOutputs    = errors.New("duplicate output names")
	ErrFixedNeedsOneOutput = errors.New("a fixed-output derivation has exactly one output")
	ErrReservedEnvKey      = errors.New("env key is derived from another field")
	ErrNoSuchOutput        = errors.New("no such output")
	ErrHash                = errors.New("invalid hash")
	ErrUntypedEnv          = errors.New(
		"env value is not a string; the flat encoding can only carry " +
			"strings, so set StructuredAttrs")
)

// nameMax is Nix's store-name length cap.
const nameMax = 211

// ValidName reports whether name is usable as a store path name.
//
// Accepts every name in the real corpus. That shows the predicate is not too
// strict; it does not show it is not too permissive, which is why
// spec/signature.md still lists the exact rules as open.
func ValidName(name string) bool {
	if name == "" || len(name) > nameMax || name == "." || name == ".." {
		return false
	}
	if strings.HasPrefix(name, ".") {
		return false
	}
	for i := 0; i < len(name); i++ {
		c := name[i]
		alnum := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
		if !alnum && !strings.ContainsRune("+-._?=", rune(c)) {
			return false
		}
	}
	return true
}

// FixedOutput is a declared result: the derivation's identity comes from this
// hash.
//
// Hash is kept EXACTLY as written, because that is what reaches the env, while
// the outputs tuple carries it re-encoded as hex. Both forms are in
// examples/fixed.drv, and the rule is verified on all 93 fixed-output
// derivations in the real corpus.
//
// Algo may be left empty when Hash is SRI (sha256-<base64>), which already
// names its algorithm. Real derivations do exactly that: 11 of the 93 carry no
// outputHashAlgo at all.
type FixedOutput struct {
	Hash string
	Algo HashAlgo
	Mode HashMode
}

// Resolve returns the algorithm and the hex digest, decoded from whatever
// representation the hash was written in.
//
// Accepts hex, Nix base-32, base-64 and SRI. The corpus contains SRI and
// base-32 and no hex at all, so an implementation that accepts only hex parses
// nothing real.
func (f FixedOutput) Resolve() (HashAlgo, string, error) {
	var algo HashAlgo
	var raw []byte
	if prefix, body, isSRI := strings.Cut(f.Hash, "-"); isSRI {
		algo = HashAlgo(prefix)
		if !algo.Valid() {
			return "", "", fmt.Errorf("%w: unknown algorithm %q", ErrHash, prefix)
		}
		if f.Algo != "" && f.Algo != algo {
			return "", "", fmt.Errorf(
				"%w: Algo=%q contradicts the SRI prefix %q", ErrHash, f.Algo, prefix)
		}
		decoded, err := base64.StdEncoding.DecodeString(body)
		if err != nil {
			return "", "", fmt.Errorf("%w: not base-64: %q", ErrHash, body)
		}
		raw = decoded
	} else {
		if f.Algo == "" {
			return "", "", fmt.Errorf(
				"%w: Algo is required unless the hash is SRI (sha256-...)", ErrHash)
		}
		if !f.Algo.Valid() {
			return "", "", fmt.Errorf("%w: unknown algorithm %q", ErrHash, f.Algo)
		}
		algo = f.Algo
		size := digestBytes[algo]
		switch {
		case len(f.Hash) == size*2:
			decoded, err := hex.DecodeString(f.Hash)
			if err != nil {
				return "", "", fmt.Errorf("%w: not hex: %q", ErrHash, f.Hash)
			}
			raw = decoded
		case len(f.Hash) == Base32Length(size):
			decoded, err := Base32Decode(f.Hash, size)
			if err != nil {
				return "", "", fmt.Errorf("%w: %s", ErrHash, err)
			}
			raw = decoded
		default:
			decoded, err := base64.StdEncoding.DecodeString(f.Hash)
			if err != nil {
				return "", "", fmt.Errorf("%w: not base-64: %q", ErrHash, f.Hash)
			}
			raw = decoded
		}
	}
	if len(raw) != digestBytes[algo] {
		return "", "", fmt.Errorf(
			"%w: %s needs %d bytes, got %d", ErrHash, algo, digestBytes[algo], len(raw))
	}
	return algo, hex.EncodeToString(raw), nil
}

// hashAlgoField is the serialized algorithm, with the r: prefix when recursive.
func (f FixedOutput) hashAlgoField() (string, error) {
	algo, _, err := f.Resolve()
	if err != nil {
		return "", err
	}
	if f.Mode.orDefault() == Recursive {
		return "r:" + string(algo), nil
	}
	return string(algo), nil
}

// env returns the entries Nix synthesizes for a fixed-output derivation.
//
// outputHashAlgo is omitted for an SRI hash, matching what real Nix emits;
// writing it anyway would change the bytes.
func (f FixedOutput) env() map[string]string {
	out := map[string]string{
		"outputHash":     f.Hash,
		"outputHashMode": string(f.Mode.orDefault()),
	}
	if f.Algo != "" {
		out["outputHashAlgo"] = string(f.Algo)
	}
	return out
}

// Outputs is the Option from spec/signature.md: outputs are either DECLARED or
// not, and the two are distinguishable in the bytes.
//
// FINDING, and the sharpest one in this implementation. Nix emits an outputs
// env variable exactly when the caller declared the attribute, so nil and
// ["out"] are different derivations with different store paths, and 96 of the
// corpus's single-output derivations take the first while 605 take the second.
//
// The obvious Go encoding, a plain []OutputName with nil meaning "not
// declared", is WRONG here and quietly so: Go deliberately makes nil and empty
// slices behave alike under len, range and append, so the distinction the bytes
// depend on is the one distinction the language encourages you to ignore. An
// explicit discriminant is the only safe encoding, which is precisely the
// "struct with a discriminant plus a constructor per case" that AGENTS.md
// predicts a sum type degrades into.
//
// The zero value means "not declared", so Build{} does the right thing.
type Outputs struct {
	Declared bool
	Names    []OutputName
}

// Declare names the outputs explicitly, producing an outputs env variable.
//
// This is `Some`, and Implicit below is `None`.
func Declare(names ...OutputName) Outputs {
	return Outputs{Declared: true, Names: names}
}

// Implicit leaves outputs undeclared: a single out, and no outputs env
// variable, as a bare `derivation { ... }` produces.
func Implicit() Outputs { return Outputs{} }

// names returns the effective output names, declared or not.
func (o Outputs) names() []OutputName {
	if !o.Declared {
		return []OutputName{"out"}
	}
	return o.Names
}

// Dep is an edge: a derivation, and the outputs of it actually needed.
type Dep struct {
	path      StorePath
	inputHash Sha256Hex
	outputs   []OutputName
}

// Path is the .drv path of the derivation this edge points at.
func (d Dep) Path() StorePath { return d.path }

// Outputs are the outputs this edge needs.
func (d Dep) Outputs() []OutputName { return append([]OutputName(nil), d.outputs...) }

// Drv is a described derivation, and everything derivable from it.
//
// InputHash is the hash by which this derivation is known when it is someone
// ELSE's input, which is NOT the hash used to compute its own output paths.
// Keeping both on the value is what lets a dependent be built without
// re-walking the graph, and keeping them named apart is what stops them being
// swapped.
type Drv struct {
	derivation Derivation
	path       StorePath
	inputHash  Sha256Hex
}

// Derivation returns the underlying derivation record.
func (d Drv) Derivation() Derivation { return d.derivation }

// Path is the path of the .drv file itself.
func (d Drv) Path() StorePath { return d.path }

// InputHash is the hash by which this derivation is known as someone's input.
func (d Drv) InputHash() Sha256Hex { return d.inputHash }

// Name is the derivation name, as it appears in store path suffixes.
func (d Drv) Name() string { return d.derivation.Name() }

// Outputs maps every output name to the path it will occupy.
func (d Drv) Outputs() map[OutputName]StorePath {
	out := make(map[OutputName]StorePath, len(d.derivation.Outputs))
	for _, o := range d.derivation.Outputs {
		out[o.Name] = o.Path
	}
	return out
}

// Output is the path of one output, known before anything is built.
func (d Drv) Output(name OutputName) (StorePath, error) {
	for _, o := range d.derivation.Outputs {
		if o.Name == name {
			return o.Path, nil
		}
	}
	have := make([]string, 0, len(d.derivation.Outputs))
	for _, o := range d.derivation.Outputs {
		have = append(have, string(o.Name))
	}
	return "", fmt.Errorf("%w: %q has no output %q; it has %v",
		ErrNoSuchOutput, d.Name(), name, have)
}

// MustOutput is Output for a name known to exist, for use in examples and
// tests.
//
// FINDING. Python and Rust get this from `?`/exceptions plus the fact that a
// literal example cannot fail. In Go, a fallible accessor inside an expression
// forces either a temporary variable per use or a panicking helper. The
// examples in examples.go would otherwise be three times their length.
func (d Drv) MustOutput(name OutputName) StorePath {
	p, err := d.Output(name)
	if err != nil {
		panic(err)
	}
	return p
}

// Needs builds an edge to this derivation, requiring the named outputs.
//
// With no names it means out. This is Python's Drv.ref and Rust's Drv::needs.
func (d Drv) Needs(outputs ...OutputName) (Dep, error) {
	wanted := outputs
	if len(wanted) == 0 {
		wanted = []OutputName{"out"}
	}
	seen := map[OutputName]bool{}
	names := []OutputName{}
	for _, n := range wanted {
		if _, err := d.Output(n); err != nil {
			return Dep{}, err
		}
		if !seen[n] {
			seen[n] = true
			names = append(names, n)
		}
	}
	return Dep{path: d.path, inputHash: d.inputHash, outputs: sortedCopy(names)}, nil
}

// MustNeed is Needs for outputs known to exist.
func (d Drv) MustNeed(outputs ...OutputName) Dep {
	dep, err := d.Needs(outputs...)
	if err != nil {
		panic(err)
	}
	return dep
}

// ATerm returns the canonical bytes.
//
// These ARE the artifact: Path is their hash, so a difference of one separator
// is a different derivation.
func (d Drv) ATerm() string { return Unparse(d.derivation) }

// Write writes the .drv under directory, named as in the store.
//
// No trailing newline: the store object does not have one, and adding one would
// change the hash of anything that reads it back.
func (d Drv) Write(directory string) (string, error) {
	name := string(d.path)
	if i := strings.LastIndex(name, "/"); i >= 0 {
		name = name[i+1:]
	}
	target := filepath.Join(directory, name)
	if err := os.WriteFile(target, []byte(d.ATerm()), 0o644); err != nil {
		return "", err
	}
	return target, nil
}

// Canonical puts a derivation into canonical form.
//
// The orderings, all of which are load-bearing (spec/canonical.md): outputs by
// name, env by key, inputDrvs by store path with each inner name list sorted,
// inputSrcs ascending. Args keeps its order, because there it is the meaning.
//
// This is idempotent, and it is the IDENTITY on every derivation real Nix
// emits, which is the sense in which the form is canonical rather than merely
// ours. Both are property-tested.
func Canonical(d Derivation) Derivation {
	outputs := append([]Output(nil), d.Outputs...)
	sort.Slice(outputs, func(i, j int) bool { return outputs[i].Name < outputs[j].Name })

	inputDrvs := make([]InputDrv, 0, len(d.InputDrvs))
	for _, i := range d.InputDrvs {
		inputDrvs = append(inputDrvs, InputDrv{
			Path:    i.Path,
			Outputs: sortedCopy(dedupe(i.Outputs)),
		})
	}
	sort.Slice(inputDrvs, func(i, j int) bool { return inputDrvs[i].Path < inputDrvs[j].Path })

	env := append([]EnvEntry(nil), d.Env...)
	sort.Slice(env, func(i, j int) bool {
		if env[i].Key != env[j].Key {
			return env[i].Key < env[j].Key
		}
		return env[i].Value < env[j].Value
	})

	return Derivation{
		Outputs:   outputs,
		InputDrvs: inputDrvs,
		InputSrcs: sortedCopy(dedupe(d.InputSrcs)),
		System:    d.System,
		Builder:   d.Builder,
		Args:      append([]string(nil), d.Args...),
		Env:       env,
	}
}

func dedupe[T comparable](in []T) []T {
	seen := make(map[T]bool, len(in))
	out := make([]T, 0, len(in))
	for _, v := range in {
		if !seen[v] {
			seen[v] = true
			out = append(out, v)
		}
	}
	return out
}

// Build is a build description: the first-order signature, as a product.
//
// Go has no keyword arguments, so this is a struct literal with the zero value
// doing the work of every default. That is the same shape as the Rust Build,
// and it is arguably the most honest translation of all four: the signature IS
// a finite product, and here it is written as one with no ceremony at all.
//
// Env is a map, which makes key uniqueness free. Go additionally RANDOMISES map
// iteration order on purpose, which turns "forgot to sort before serializing"
// from a silent bug into a loudly flaky one. That is a genuine advantage over
// Python's insertion-ordered dict for this particular problem.
type Build struct {
	// Name is the package name. Must be a valid store path name.
	Name string
	// System is the platform to build on, e.g. x86_64-linux.
	System string
	// Builder is the program to run.
	Builder string
	// Args are arguments to the builder. Order is the meaning; never sorted.
	Args []string
	// Env holds extra environment entries. The ones derived from the other
	// fields are rejected, because supplying one would let the env disagree
	// with the field it mirrors.
	//
	// Values are JSONValue rather than string because StructuredAttrs can
	// carry types. With it off, every value must be a JSON string; anything
	// else is refused, because the flat encoding cannot represent it.
	Env map[string]JSONValue
	// StructuredAttrs selects the SECOND env encoding (spec/canonical.md
	// section 1.8): attributes carried as one __json entry with their types
	// preserved, rather than one string-valued variable each. 1223 of 2516
	// real derivations use it.
	StructuredAttrs bool
	// Outputs is the Option: zero value means undeclared. See the Outputs type.
	Outputs Outputs
	// InputDrvs are edges to other derivations, built with Drv.Needs.
	InputDrvs []Dep
	// InputSrcs are store paths used directly as sources.
	InputSrcs []StorePath
	// FixedOutput, when non-nil, declares the result in advance.
	//
	// A nil pointer is this file's third encoding of "optional".
	FixedOutput *FixedOutput
}

// reserved lists env keys derived from other fields.
var reserved = []string{
	"name", "system", "builder", "outputs",
	"outputHash", "outputHashAlgo", "outputHashMode",
	"__json", "__structuredAttrs",
}

// Derive describes a build. This is the whole eDSL.
//
// FINDING. It cannot be called Derivation, which is what Python and Rust call
// it, because Go's visibility is capitalisation and a package has ONE exported
// namespace, so the type and its constructor would collide. The rename is
// trivial, and it is the kind of thing that makes a "portable" API not quite
// portable in its spelling even when it is exactly portable in its meaning.
func Derive(b Build) (Drv, error) {
	if !ValidName(b.Name) {
		return Drv{}, fmt.Errorf("%w: %q", ErrInvalidName, b.Name)
	}

	names := b.Outputs.names()
	if len(names) == 0 {
		return Drv{}, ErrEmptyOutputs
	}
	if len(dedupe(names)) != len(names) {
		return Drv{}, fmt.Errorf("%w: %v", ErrDuplicateOutputs, names)
	}
	for _, n := range names {
		if !ValidName(string(n)) {
			return Drv{}, fmt.Errorf("%w: output %q", ErrInvalidName, n)
		}
	}
	if b.FixedOutput != nil && len(names) != 1 {
		return Drv{}, fmt.Errorf("%w: got %v", ErrFixedNeedsOneOutput, names)
	}

	blocked := map[string]bool{}
	for _, k := range reserved {
		blocked[k] = true
	}
	for _, n := range names {
		blocked[string(n)] = true
	}
	clashes := []string{}
	for k := range b.Env {
		if blocked[k] {
			clashes = append(clashes, k)
		}
	}
	if len(clashes) > 0 {
		sort.Strings(clashes)
		return Drv{}, fmt.Errorf("%w: %v", ErrReservedEnvKey, clashes)
	}

	if !b.StructuredAttrs {
		untyped := []string{}
		for k, v := range b.Env {
			if !v.IsString() {
				untyped = append(untyped, k)
			}
		}
		if len(untyped) > 0 {
			sort.Strings(untyped)
			return Drv{}, fmt.Errorf("%w: %v", ErrUntypedEnv, untyped)
		}
	}

	var algo, digest string
	if b.FixedOutput != nil {
		var err error
		if algo, err = b.FixedOutput.hashAlgoField(); err != nil {
			return Drv{}, err
		}
		if _, digest, err = b.FixedOutput.Resolve(); err != nil {
			return Drv{}, err
		}
	}

	env := map[string]string{}
	if b.StructuredAttrs {
		// One __json entry carrying every attribute WITH ITS TYPE, plus one
		// entry per output. The output paths stay OUTSIDE the JSON, which is
		// why masking needs no special case. See spec/canonical.md 1.8.
		attrs := map[string]JSONValue{}
		for k, v := range b.Env {
			attrs[k] = v
		}
		attrs["name"] = Str(b.Name)
		attrs["system"] = Str(b.System)
		attrs["builder"] = Str(b.Builder)
		if b.Outputs.Declared {
			items := make([]JSONValue, 0, len(names))
			for _, n := range names {
				items = append(items, Str(string(n)))
			}
			attrs["outputs"] = Array(items...)
		}
		if b.FixedOutput != nil {
			for k, v := range b.FixedOutput.env() {
				attrs[k] = Str(v)
			}
		}
		env["__json"] = Object(attrs).JSON()
	} else {
		for k, v := range b.Env {
			env[k] = v.Str
		}
		env["name"] = b.Name
		env["system"] = b.System
		env["builder"] = b.Builder
		if b.Outputs.Declared {
			parts := make([]string, 0, len(names))
			for _, n := range names {
				parts = append(parts, string(n))
			}
			env["outputs"] = strings.Join(parts, " ")
		}
		if b.FixedOutput != nil {
			for k, v := range b.FixedOutput.env() {
				env[k] = v
			}
		}
	}
	// Placeholders. The real paths are the hash of the derivation that contains
	// them, so they cannot be known until the next step, and the masked form
	// used to compute them blanks these anyway.
	for _, n := range names {
		env[string(n)] = ""
	}

	edges := mergeEdges(b.InputDrvs)
	outputs := make([]Output, 0, len(names))
	for _, n := range names {
		outputs = append(outputs, Output{Name: n, HashAlgo: algo, Hash: digest})
	}
	inputDrvs := make([]InputDrv, 0, len(edges))
	for _, e := range edges {
		inputDrvs = append(inputDrvs, InputDrv{Path: e.path, Outputs: e.outputs})
	}
	envEntries := make([]EnvEntry, 0, len(env))
	for k, v := range env {
		envEntries = append(envEntries, EnvEntry{Key: k, Value: v})
	}

	draft := Canonical(Derivation{
		Outputs:   outputs,
		InputDrvs: inputDrvs,
		InputSrcs: b.InputSrcs,
		System:    b.System,
		Builder:   b.Builder,
		Args:      b.Args,
		Env:       envEntries,
	})

	inputHashes := make(map[StorePath]string, len(edges))
	for _, e := range edges {
		inputHashes[e.path] = string(e.inputHash)
	}
	paths := OutputPaths(draft, b.Name, inputHashes)

	final := draft
	for i := range final.Outputs {
		final.Outputs[i].Path = paths[final.Outputs[i].Name]
	}
	for i := range final.Env {
		if p, ok := paths[OutputName(final.Env[i].Key)]; ok {
			final.Env[i].Value = string(p)
		}
	}

	aterm := Unparse(final)
	var inputHash Sha256Hex
	if fixed, ok := final.FixedOutput(); ok {
		inputHash = FixedOutputInputHash(fixed)
	} else {
		inputHash = SHA256Hex(UnparseWith(final, SerializeOptions{InputHashes: inputHashes}))
	}
	return Drv{derivation: final, path: DrvPath(aterm, b.Name), inputHash: inputHash}, nil
}

// MustDerive is Derive for a description known to be valid.
func MustDerive(b Build) Drv {
	d, err := Derive(b)
	if err != nil {
		panic(err)
	}
	return d
}

// mergeEdges merges duplicate targets into one edge with the union of the
// outputs needed.
//
// That is what Nix emits: store paths are unique within inputDrvs in 1293 of
// 1293 real derivations.
func mergeEdges(deps []Dep) []Dep {
	byPath := map[StorePath]*Dep{}
	order := []StorePath{}
	for _, d := range deps {
		existing, ok := byPath[d.path]
		if !ok {
			copied := Dep{path: d.path, inputHash: d.inputHash}
			byPath[d.path] = &copied
			order = append(order, d.path)
			existing = &copied
		}
		existing.outputs = append(existing.outputs, d.outputs...)
	}
	sort.Slice(order, func(i, j int) bool { return order[i] < order[j] })
	out := make([]Dep, 0, len(order))
	for _, p := range order {
		d := byPath[p]
		out = append(out, Dep{
			path:      d.path,
			inputHash: d.inputHash,
			outputs:   sortedCopy(dedupe(d.outputs)),
		})
	}
	return out
}
