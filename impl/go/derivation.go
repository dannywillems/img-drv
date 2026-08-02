// Package imgdrv is a content-addressed IR for reproducible build
// descriptions.
//
// Describe a build, compute its store paths, serialize it, and get bytes
// identical to what Nix emits.
//
// This is the Go implementation, and its job in this project is to be the
// FALSIFICATION TEST for the theory in docs/theory.md: Go has no sum types, no
// higher-kinded types and minimal generics, so if the first-order signature
// needs more than finite products, Go is where it breaks. README.md records
// what it actually cost, which is the experimental result.
package imgdrv

import "sort"

// The named string types are not decoration. A store path, a hex digest and an
// output name are all strings, and confusing them is the class of bug this
// project has already paid for once: a derivation's own path and the hash by
// which it is known as an input are both 64-character strings, and swapping
// them yields a plausible wrong answer rather than an error.
//
// Go's defined types catch that at compile time, exactly as Rust's newtypes do
// and unlike Python's erased NewType. This is the one row of the typing table
// where Go is as strong as Rust.

// StorePath is an absolute path in the store, e.g. /nix/store/<32 chars>-hello.
type StorePath string

// Sha256Hex is a sha256 digest as 64 lowercase hex characters.
type Sha256Hex string

// OutputName is the name of one output of a derivation: out, dev, lib, ...
type OutputName string

// Output is one output of a derivation.
//
// HashAlgo and Hash are empty for an ordinary derivation. When they are set the
// derivation is FIXED-OUTPUT: it declares its result in advance, so its
// identity comes from the declared hash rather than from how it is built.
//
// HashAlgo is a string and not the HashAlgo enum-alike in edsl.go, on purpose:
// parsing has to be TOTAL over whatever real Nix wrote, so the wire type stays
// permissive and strictness lives on the construction side.
type Output struct {
	Name     OutputName
	Path     StorePath
	HashAlgo string
	Hash     string
}

// Fixed reports whether this output declares its content hash in advance.
func (o Output) Fixed() bool { return o.HashAlgo != "" }

// InputDrv is a dependency on specific outputs of another derivation.
//
// Depending on dev alone is a real and common case, so the set of needed output
// names belongs to the EDGE rather than to the target.
type InputDrv struct {
	Path    StorePath
	Outputs []OutputName
}

// EnvEntry is one environment variable.
//
// Go has no tuple type, so what is (string, string) in Python and Rust needs a
// named struct here. One line of cost, recorded because the point of this
// implementation is to count them.
type EnvEntry struct {
	Key   string
	Value string
}

// Derivation is a build description: the seven fields of the Derive(...) form.
//
// Field order is the serialization order and is load-bearing. See
// docs/spec/canonical.md.
type Derivation struct {
	Outputs   []Output
	InputDrvs []InputDrv
	InputSrcs []StorePath
	System    string
	Builder   string
	Args      []string
	Env       []EnvEntry
}

// OutputNames returns the names of this derivation's own outputs.
//
// Used when masking: an env entry is blanked when its KEY is one of these,
// never when an output path merely appears inside some value.
func (d Derivation) OutputNames() map[OutputName]bool {
	names := make(map[OutputName]bool, len(d.Outputs))
	for _, o := range d.Outputs {
		names[o.Name] = true
	}
	return names
}

// FixedOutput returns the fixed output and true, if this is a fixed-output
// derivation.
//
// Go has no Option, so a two-case sum becomes a (value, bool) pair. That is the
// idiomatic encoding and it is fine here; it stops being fine when the Option
// has to survive being stored in a struct, which is what Build.Outputs runs
// into. See edsl.go.
func (d Derivation) FixedOutput() (Output, bool) {
	for _, o := range d.Outputs {
		if o.Fixed() {
			return o, true
		}
	}
	return Output{}, false
}

// Name returns the derivation name, from the name environment variable.
//
// Every derivation carries one, and it is what output store names are built
// from.
func (d Derivation) Name() string {
	for _, e := range d.Env {
		if e.Key == "name" {
			return e.Value
		}
	}
	return ""
}

// Equal reports whether two derivations are structurally equal.
//
// Go has no derivable structural equality: a struct containing a slice is not
// comparable with ==, so this is hand-written for every type that has one.
// reflect.DeepEqual would do it in one line, at the cost of dropping to
// runtime-typed comparison, which is exactly what this implementation is
// supposed to avoid. Four Equal methods is the price; it is recorded in
// README.md rather than hidden.
func (d Derivation) Equal(other Derivation) bool {
	if d.System != other.System || d.Builder != other.Builder {
		return false
	}
	if !equalSlice(d.Args, other.Args) || !equalSlice(d.InputSrcs, other.InputSrcs) {
		return false
	}
	if !equalSlice(d.Env, other.Env) || !equalSlice(d.Outputs, other.Outputs) {
		return false
	}
	if len(d.InputDrvs) != len(other.InputDrvs) {
		return false
	}
	for i := range d.InputDrvs {
		if !d.InputDrvs[i].Equal(other.InputDrvs[i]) {
			return false
		}
	}
	return true
}

// Equal reports whether two edges are structurally equal.
func (i InputDrv) Equal(other InputDrv) bool {
	return i.Path == other.Path && equalSlice(i.Outputs, other.Outputs)
}

// equalSlice compares two slices of comparable elements.
//
// This is the one place generics earn their keep here, and they are the weak
// kind: a type parameter constrained to comparable, with an identical body for
// every element type. Exactly the case "write code, not types" allows.
func equalSlice[T comparable](a, b []T) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// sortedCopy returns a sorted copy of a slice of ordered values.
func sortedCopy[T ~string](in []T) []T {
	out := append([]T(nil), in...)
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}
