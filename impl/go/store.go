package imgdrv

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"sort"
	"strings"
)

// Store path computation.
//
// Verified against real derivations: 1259 of 1259 output paths across 805 real
// nixpkgs derivations, plus 12 of 12 golden examples. The rules are written up
// in docs/spec/store-paths.md, and the structure behind them (output paths
// FACTOR through masking rather than solving a fixed point) in docs/theory.md
// section 7.

// Store is the store root every fingerprint is built against.
const Store = "/nix/store"

// Base32Alphabet is Nix's own base-32 alphabet.
//
// Note the omissions: e, o, u and t are absent, so that no store path can
// accidentally spell a word.
const Base32Alphabet = "0123456789abcdfghijklmnpqrsvwxyz"

// Base32Length is how many base-32 digits encode size bytes.
func Base32Length(size int) int { return (size*8-1)/5 + 1 }

// Base32 encodes bytes the way Nix does: least significant digit first, five
// bits at a time.
//
// Not RFC 4648. Digits are emitted from the END of the buffer backwards, which
// is why a stock base-32 library produces a different string. This is the first
// thing to check when a path is close but wrong.
func Base32(data []byte) string {
	length := Base32Length(len(data))
	out := make([]byte, 0, length)
	for i := length - 1; i >= 0; i-- {
		bit := i * 5
		idx, offset := bit/8, bit%8
		c := data[idx] >> offset
		// Unlike Rust, Go DEFINES an over-wide shift as producing zero rather
		// than panicking or masking, so `data[idx+1] << 8` would be harmless
		// here. The guard is kept anyway so the three implementations read the
		// same; relying on a language-specific shift rule in a hash function is
		// how you get an answer that is right in one language only.
		if idx+1 < len(data) && offset != 0 {
			c |= data[idx+1] << (8 - offset)
		}
		out = append(out, Base32Alphabet[c&0x1f])
	}
	return string(out)
}

// Base32Decode is the inverse of Base32.
//
// Needed because real fixed-output derivations write their hash in base-32 (or
// SRI) while the outputs tuple carries it as hex, so an implementation that
// cannot decode cannot reproduce the bytes. size is the expected digest length,
// which the encoding does not carry.
func Base32Decode(text string, size int) ([]byte, error) {
	if len(text) != Base32Length(size) {
		return nil, fmt.Errorf("expected %d digits, got %d", Base32Length(size), len(text))
	}
	out := make([]byte, size)
	for n := 0; n < len(text); n++ {
		c := text[len(text)-1-n]
		digit := strings.IndexByte(Base32Alphabet, c)
		if digit < 0 {
			return nil, fmt.Errorf("not a Nix base-32 digit: %q", string(c))
		}
		bit := n * 5
		idx, offset := bit/8, bit%8
		out[idx] |= byte(digit<<offset) & 0xff
		carry := byte(digit >> (8 - offset))
		if idx+1 < size {
			out[idx+1] |= carry
		} else if carry != 0 {
			return nil, fmt.Errorf("base-32 digits overflow the digest length")
		}
	}
	return out, nil
}

// Compress XOR-folds a digest down to size bytes.
//
// A store path carries 20 bytes, not 32, and the sha256 is folded rather than
// truncated: byte i of the digest is XORed into byte i mod size. Truncating
// gives a plausible-looking path that is wrong.
func Compress(h []byte, size int) []byte {
	out := make([]byte, size)
	for i, b := range h {
		out[i%size] ^= b
	}
	return out
}

// SHA256Hex is the sha256 of a string, as 64 lowercase hex characters.
func SHA256Hex(s string) Sha256Hex {
	sum := sha256.Sum256([]byte(s))
	return Sha256Hex(hex.EncodeToString(sum[:]))
}

// StorePathFor is the outer step, shared by every kind of store path.
//
// fingerprint = "<kind>:sha256:<inner hex>:<store dir>:<name>" and the path is
// <store dir>/<base32(compress(sha256(fingerprint)))>-<name>.
//
// Only kind and inner vary: text for a .drv file, output:<name> for a build
// output, source for a file added directly to the store.
func StorePathFor(kind string, inner Sha256Hex, name string) StorePath {
	fingerprint := fmt.Sprintf("%s:sha256:%s:%s:%s", kind, inner, Store, name)
	digest := sha256.Sum256([]byte(fingerprint))
	return StorePath(fmt.Sprintf("%s/%s-%s", Store, Base32(Compress(digest[:], 20)), name))
}

// FixedOutputPath is the store path of a fixed-output derivation.
//
// TWO schemes, selected by the ingestion method encoded in the algo field:
//
//   - r:sha256, recursive (NAR) ingestion with sha256, takes the source kind and
//     uses the declared hash DIRECTLY as the inner hash;
//   - everything else builds the usual fixed:out: fingerprint first.
//
// Missing the first case costs exactly one path in a 226-derivation closure,
// which is how it survived a corpus written by hand.
func FixedOutputPath(o Output, drvName string) StorePath {
	if o.HashAlgo == "r:sha256" {
		return StorePathFor("source", Sha256Hex(o.Hash), drvName)
	}
	inner := SHA256Hex(fmt.Sprintf("fixed:out:%s:%s:", o.HashAlgo, o.Hash))
	return StorePathFor("output:out", inner, drvName)
}

// FixedOutputInputHash is the hash by which a fixed-output derivation is known
// AS AN INPUT.
//
// Note the trailing store path. This is NOT the string used to compute the path
// itself, which ends at the colon; including the path there would be circular.
//
// Confusing the two is invisible until something DEPENDS on a fixed-output
// derivation, because the derivation's own path still comes out right. It
// accounted for every one of the 145 downstream failures in the first real
// corpus: the fetches all verified, and everything below them did not.
func FixedOutputInputHash(o Output) Sha256Hex {
	return SHA256Hex(fmt.Sprintf("fixed:out:%s:%s:%s", o.HashAlgo, o.Hash, o.Path))
}

// OutputStoreName gives out the plain name; every other output is suffixed.
//
// Package multi with outputs out, dev, lib yields store names multi, multi-dev,
// multi-lib.
func OutputStoreName(drvName string, output OutputName) string {
	if output == "out" {
		return drvName
	}
	return drvName + "-" + string(output)
}

// OutputPaths computes every output path of a derivation.
//
// The asymmetry that matters: mask MY outputs, because they are what is being
// computed; do not mask my inputs'.
func OutputPaths(d Derivation, drvName string, inputHashes map[StorePath]string) map[OutputName]StorePath {
	if fixed, ok := d.FixedOutput(); ok {
		return map[OutputName]StorePath{fixed.Name: FixedOutputPath(fixed, drvName)}
	}
	inner := SHA256Hex(UnparseWith(d, SerializeOptions{
		MaskOutputs: true,
		InputHashes: inputHashes,
	}))
	out := make(map[OutputName]StorePath, len(d.Outputs))
	for _, o := range d.Outputs {
		out[o.Name] = StorePathFor(
			"output:"+string(o.Name), inner, OutputStoreName(drvName, o.Name),
		)
	}
	return out
}

// DrvPath is the path of the .drv file itself: a text store object.
//
// references are the store paths the file MENTIONS: its inputDrvs and its
// inputSrcs. They are part of the fingerprint, sorted and inserted after the
// text kind:
//
//	text:<ref>:<ref>:...:sha256:<inner>:<store dir>:<name>
//
// Omitting them is right for a derivation with no inputs and wrong for
// everything else. Verified against 1458 real nixpkgs .drv files, which are
// named by real Nix: 1458 of 1458 with references, 149 of 1458 without.
func DrvPath(aterm string, drvName string, references []string) StorePath {
	refs := dedupe(references)
	sort.Strings(refs)
	kind := "text"
	if len(refs) > 0 {
		kind = "text:" + strings.Join(refs, ":")
	}
	return StorePathFor(kind, SHA256Hex(aterm), drvName+".drv")
}
