package nix

import "strings"

// The two string transformations Nix applies at PARSE time.
//
// Both belong to the parser rather than the printer because Nix puts them
// there: the AST holds the dedented text, so --parse prints one plain string
// for an indented literal.

// indexedPart is a part plus Nix's StringToken.hasIndentation.
//
// The flag matters for a reason that is easy to miss: a chunk produced by an
// escape is NOT scanned during dedenting, it only ends the current run of
// start-of-line whitespace. An escaped newline is a real newline character, so
// scanning it would make the following text look like an unindented line and
// switch the dedent off for the whole string.
type indexedPart struct {
	Part     Part
	Indented bool
}

func plainParts(parts []indexedPart) []Part {
	out := make([]Part, 0, len(parts))
	for _, p := range parts {
		out = append(out, p.Part)
	}
	return out
}

// dropEmpty removes empty literals, which would otherwise print as "" + ...
//
// Note what this does NOT do: merge adjacent literals. Nix does not merge them
// either. Its lexer matches a MAXIMAL run so the pieces arrive already joined,
// and the pieces it keeps separate stay separate in the printed tree.
func dropEmpty(parts []Part) []Part {
	kept := make([]Part, 0, len(parts))
	for _, p := range parts {
		if lit, ok := p.(Lit); ok && lit.Text == "" {
			continue
		}
		kept = append(kept, p)
	}
	if len(kept) == 0 {
		return []Part{Lit{Text: ""}}
	}
	return kept
}

// StripIndentation removes the common indentation from an indented string.
//
// Transcribed from stripIndentation in NixOS/nix parser.y. Two passes: the
// first finds the minimum indentation over lines that have content, where a
// line of only spaces does not count and an interpolation counts as content;
// the second removes that many leading spaces per line and drops a final line
// that is nothing but spaces.
func StripIndentation(parts []indexedPart) []Part {
	minIndent := -1
	atStart, cur := true, 0
	note := func() {
		if atStart {
			atStart = false
			if minIndent < 0 || cur < minIndent {
				minIndent = cur
			}
		}
	}
	for _, ip := range parts {
		lit, isLit := ip.Part.(Lit)
		if !ip.Indented || !isLit {
			note()
			continue
		}
		for _, c := range lit.Text {
			if atStart {
				switch c {
				case ' ':
					cur++
				case '\n':
					cur = 0
				default:
					note()
				}
			} else if c == '\n' {
				atStart, cur = true, 0
			}
		}
	}
	if minIndent < 0 {
		minIndent = 0
	}

	out := make([]Part, 0, len(parts))
	atStart, dropped := true, 0
	last := len(parts) - 1
	for i, ip := range parts {
		lit, isLit := ip.Part.(Lit)
		if !ip.Indented {
			atStart, dropped = false, 0
			out = append(out, ip.Part)
			continue
		}
		if !isLit {
			out = append(out, ip.Part)
			continue
		}
		var b strings.Builder
		for _, c := range lit.Text {
			if atStart {
				switch c {
				case ' ':
					if dropped >= minIndent {
						b.WriteRune(c)
					}
					dropped++
				case '\n':
					dropped = 0
					b.WriteRune(c)
				default:
					atStart, dropped = false, 0
					b.WriteRune(c)
				}
			} else {
				b.WriteRune(c)
				if c == '\n' {
					atStart, dropped = true, 0
				}
			}
		}
		text := b.String()
		// The closing delimiter usually sits on its own indented line, and that
		// trailing run of spaces is not part of the value.
		if i == last {
			if nl := strings.LastIndex(text, "\n"); nl >= 0 {
				if strings.Trim(text[nl+1:], " ") == "" {
					text = text[:nl+1]
				}
			}
		}
		out = append(out, Lit{Text: text})
	}
	return dropEmpty(out)
}

// withAlias attaches an `@ name` alias to a set pattern.
//
// Lives here rather than in the grammar because a goyacc action is Go embedded
// in a .y file, and keeping helpers out of it lets the rules read as grammar.
func withAlias(p Pattern, name string) Pattern {
	if set, ok := p.(PSet); ok {
		set.Alias = name
		return set
	}
	return p
}
