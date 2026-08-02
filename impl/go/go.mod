// The Go implementation is the FALSIFICATION TEST. It has no sum types, no
// higher-kinded types and minimal generics, so if the signature in
// docs/spec/signature.md needs more than finite products, this is where it
// shows. See README.md for what it actually cost.
//
// Zero dependencies, like the Python reference: hashing and base-64 are both
// in the standard library.
module github.com/dannywillems/img-drv/impl/go

go 1.26.5
