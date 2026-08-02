package nix

import "strings"

// Path resolution, which Nix performs at PARSE time.
//
// A relative path resolves against the directory of the file it is written in,
// and a leading ~ against HOME, so ./common/x11.nix written in
// nixos/tests/foo.nix is an ABSOLUTE path in the tree and
// nix-instantiate --parse prints it that way. A parser that keeps the relative
// text produces a different tree.
//
// Package state rather than a parameter because the parser is generated and
// its entry point takes only a lexer. Empty means "leave paths alone", which is
// what the transpiler and the unit vectors want. Not safe to use from two
// goroutines at once, which is the same caveat the surface carries.

var baseDir, homeDir string

// SetContext sets the directories path literals resolve against.
func SetContext(base, home string) {
	baseDir, homeDir = base, home
}

// Canonicalise folds away . and .., collapses separators, drops a trailing one.
func Canonicalise(p string) string {
	stack := []string{}
	for _, part := range strings.Split(p, "/") {
		switch part {
		case "", ".":
		case "..":
			if len(stack) > 0 {
				stack = stack[:len(stack)-1]
			}
		default:
			stack = append(stack, part)
		}
	}
	return "/" + strings.Join(stack, "/")
}

// ResolvePath resolves a path literal against the base or home directory.
func ResolvePath(p string) string {
	if rest, ok := strings.CutPrefix(p, "~"); ok {
		if homeDir == "" {
			return p
		}
		return Canonicalise(homeDir + rest)
	}
	if baseDir == "" {
		return p
	}
	if strings.HasPrefix(p, "/") {
		return Canonicalise(p)
	}
	return Canonicalise(baseDir + "/" + p)
}

// ResolvePathPrefix resolves the literal PREFIX of an interpolated path.
//
// Same as ResolvePath except a trailing separator is KEPT, because it is
// meaningful here: ./x/${v} denotes /abs/x/ concatenated with v, and dropping
// the separator would glue the two segments together.
func ResolvePathPrefix(p string) string {
	resolved := ResolvePath(p)
	if strings.HasSuffix(p, "/") {
		return resolved + "/"
	}
	return resolved
}
