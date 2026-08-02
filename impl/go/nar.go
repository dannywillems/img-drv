package imgdrv

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"sort"
	"strings"
)

// NAR: the Nix Archive format, and the store path of a source.
//
// The last unspecified corner of the format (docs/spec/canonical.md section 3),
// and the one half of the .drv references rule that nothing we produced could
// exercise: a derivation's fingerprint lists its inputDrvs AND its inputSrcs,
// and until now every derivation we built had an empty inputSrcs.
//
// THE FORMAT.
//
// NAR is a CANONICAL serialization of a filesystem object, and canonical is the
// whole point: two directories with the same contents serialize to the same
// bytes regardless of inode order, mtimes, ownership, or permissions beyond one
// bit. Everything a filesystem records that is not content is discarded.
//
// The grammar, from the Nix thesis (Dolstra 2006, figure 5.2):
//
//	serialise(fso)  = str("nix-archive-1") ++ node(fso)
//	node(fso)       = str("(") ++ body(fso) ++ str(")")
//
//	body(Regular)   = str("type") str("regular")
//	                  [ str("executable") str("") ]
//	                  str("contents") str(contents)
//	body(Symlink)   = str("type") str("symlink") str("target") str(target)
//	body(Directory) = str("type") str("directory") entry*
//
//	entry           = str("entry") str("(") str("name") str(name)
//	                  str("node") node str(")")
//
//	str(s)          = int(len s) ++ s ++ zero padding to a multiple of 8
//	int(n)          = 8 bytes, little endian
//
// Three details decide whether an implementation is right, and all three are
// invisible in a happy-path test: entries sort BYTE-wise rather than by locale;
// the executable BIT is the only permission kept and is encoded as the PRESENCE
// of a field; and padding to eight adds NOTHING when already aligned rather
// than a full block.
//
// WHY THIS TAKES A TREE AND NOT A PATH.
//
// A filesystem object is an inductive type, the initial algebra of
//
//	F(X) = (contents x executable) + target + (name x X)*
//
// and NAR is the unique homomorphism out of it into bytes: a CATAMORPHISM.
// Writing it that way rather than as a directory walk keeps the package free of
// filesystem code, makes the serializer testable without a filesystem, and puts
// the part that decides the BYTES where it can be read.
//
// The sum is a SEALED INTERFACE, for the reasons in
// docs/decisions/2026-08-02-go-json-sealed-interface.md: an invalid shape
// cannot be written down, and the missing exhaustiveness check is covered by a
// panicking default.

// Fso is a filesystem object, as NAR understands one.
//
// Note what is ABSENT: mtimes, ownership, and every permission but one. NAR
// does not discard them as an optimisation; a format that kept them could not
// be canonical.
//
// Sealed: only this package can implement it.
type Fso interface {
	isFso()
}

// Regular is a file. The executable bit is the only permission NAR keeps.
type Regular struct {
	Contents   []byte
	Executable bool
}

// Symlink is a symbolic link, stored as its target text.
type Symlink struct{ Target string }

// DirEntry is one named child of a directory.
type DirEntry struct {
	Name string
	Node Fso
}

// Directory is a directory. Entries are sorted at serialization time.
type Directory struct{ Entries []DirEntry }

func (Regular) isFso()   {}
func (Symlink) isFso()   {}
func (Directory) isFso() {}

// padNar zero-pads to a multiple of eight, adding NOTHING when already aligned.
func padNar(out []byte, n int) []byte {
	if remainder := n % 8; remainder != 0 {
		out = append(out, make([]byte, 8-remainder)...)
	}
	return out
}

func putNar(out []byte, payload []byte) []byte {
	var length [8]byte
	binary.LittleEndian.PutUint64(length[:], uint64(len(payload)))
	out = append(out, length[:]...)
	out = append(out, payload...)
	return padNar(out, len(payload))
}

func putNarString(out []byte, s string) []byte { return putNar(out, []byte(s)) }

// narNode is the type switch a variant would make exhaustive. The default
// panics: a missing case would emit a well-formed but WRONG archive and
// therefore a wrong store path.
func narNode(out []byte, fso Fso) []byte {
	out = putNarString(out, "(")
	switch fso := fso.(type) {
	case Symlink:
		out = putNarString(out, "type")
		out = putNarString(out, "symlink")
		out = putNarString(out, "target")
		out = putNarString(out, fso.Target)
	case Directory:
		out = putNarString(out, "type")
		out = putNarString(out, "directory")
		// Sorted BY BYTES. A locale-aware sort produces a different archive and
		// therefore a different store path, for the same directory.
		entries := append([]DirEntry(nil), fso.Entries...)
		sort.Slice(entries, func(i, j int) bool {
			return entries[i].Name < entries[j].Name
		})
		for _, e := range entries {
			out = putNarString(out, "entry")
			out = putNarString(out, "(")
			out = putNarString(out, "name")
			out = putNarString(out, e.Name)
			out = putNarString(out, "node")
			out = narNode(out, e.Node)
			out = putNarString(out, ")")
		}
	case Regular:
		out = putNarString(out, "type")
		out = putNarString(out, "regular")
		// The executable bit is the ONLY permission NAR keeps, and it is
		// encoded as a present-or-absent FIELD rather than as a value.
		if fso.Executable {
			out = putNarString(out, "executable")
			out = putNarString(out, "")
		}
		out = putNarString(out, "contents")
		out = putNar(out, fso.Contents)
	default:
		panic(fmt.Sprintf("unknown filesystem object %T", fso))
	}
	return putNarString(out, ")")
}

// Nar serializes a filesystem object to its canonical NAR bytes.
func Nar(fso Fso) []byte {
	out := make([]byte, 0, 4096)
	out = putNarString(out, "nix-archive-1")
	return narNode(out, fso)
}

// NarHash is the sha256 of the NAR, as 64 lowercase hex characters.
func NarHash(fso Fso) Sha256Hex {
	sum := sha256.Sum256(Nar(fso))
	return Sha256Hex(hex.EncodeToString(sum[:]))
}

// SourcePath is the store path a source lands at, as nix-store --add computes
// it.
//
// references take the same treatment as a .drv's: sorted, joined with colons,
// and appended to the kind. Shared with the text kind through Nix's makeType,
// which is why one bug in that rule was two bugs.
func SourcePath(fso Fso, name string, references []string) StorePath {
	refs := dedupe(references)
	sort.Strings(refs)
	kind := "source"
	if len(refs) > 0 {
		kind = "source:" + strings.Join(refs, ":")
	}
	return StorePathFor(kind, NarHash(fso), name)
}
