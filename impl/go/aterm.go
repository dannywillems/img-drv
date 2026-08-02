package imgdrv

import (
	"fmt"
	"sort"
	"strings"
)

// A hand-written recursive-descent parser, and NOT a regex, for the reason
// recorded in AGENTS.md: a regex-based reader of derivations passed 12 of 12
// hand-written examples and then failed 323 of 403 real ones, because real
// derivations contain escaped quotes inside values, store paths embedded in
// unrelated environment variables, and `],[` sequences inside strings.

// ParseError is a derivation that could not be read.
type ParseError struct {
	// What the parser expected to find.
	What string
	// Byte offset at which it was expected.
	At int
}

func (e *ParseError) Error() string {
	return fmt.Sprintf("expected %s at byte %d", e.What, e.At)
}

type parser struct {
	// Bytes, not runes: offsets have to be stable, and every structural
	// character in the grammar is ASCII.
	text []byte
	pos  int
}

func (p *parser) errorf(what string) error {
	return &ParseError{What: what, At: p.pos}
}

func (p *parser) peek() (byte, bool) {
	if p.pos >= len(p.text) {
		return 0, false
	}
	return p.text[p.pos], true
}

func (p *parser) expect(ch byte) error {
	if c, ok := p.peek(); ok && c == ch {
		p.pos++
		return nil
	}
	return p.errorf(fmt.Sprintf("%q", string(ch)))
}

func (p *parser) literal(text string) error {
	if strings.HasPrefix(string(p.text[p.pos:]), text) {
		p.pos += len(text)
		return nil
	}
	return p.errorf(text)
}

// str reads a double-quoted string, undoing exactly the five escapes.
//
// Every other byte is taken literally, INCLUDING other control characters. An
// implementation that also decodes \uXXXX, as JSON does, reads a different
// language.
func (p *parser) str() (string, error) {
	if err := p.expect('"'); err != nil {
		return "", err
	}
	var out strings.Builder
	for {
		c, ok := p.peek()
		if !ok {
			return "", p.errorf("closing quote")
		}
		p.pos++
		switch c {
		case '"':
			return out.String(), nil
		case '\\':
			esc, ok := p.peek()
			if !ok {
				return "", p.errorf("escape character")
			}
			p.pos++
			switch esc {
			case 'n':
				out.WriteByte('\n')
			case 'r':
				out.WriteByte('\r')
			case 't':
				out.WriteByte('\t')
			default:
				out.WriteByte(esc)
			}
		default:
			out.WriteByte(c)
		}
	}
}

// listOf parses a bracketed, comma-separated list.
//
// Generic over the element type, which is the second and last place generics
// are used here: the body is identical for every element, so a type parameter
// is the right tool rather than an interface.
func listOf[T any](p *parser, item func(*parser) (T, error)) ([]T, error) {
	if err := p.expect('['); err != nil {
		return nil, err
	}
	out := []T{}
	if c, ok := p.peek(); ok && c == ']' {
		p.pos++
		return out, nil
	}
	for {
		v, err := item(p)
		if err != nil {
			return nil, err
		}
		out = append(out, v)
		c, ok := p.peek()
		if !ok {
			return nil, p.errorf("',' or ']'")
		}
		p.pos++
		switch c {
		case ',':
		case ']':
			return out, nil
		default:
			return nil, p.errorf("',' or ']'")
		}
	}
}

func (p *parser) output() (Output, error) {
	if err := p.expect('('); err != nil {
		return Output{}, err
	}
	name, err := p.str()
	if err != nil {
		return Output{}, err
	}
	if err := p.expect(','); err != nil {
		return Output{}, err
	}
	path, err := p.str()
	if err != nil {
		return Output{}, err
	}
	if err := p.expect(','); err != nil {
		return Output{}, err
	}
	algo, err := p.str()
	if err != nil {
		return Output{}, err
	}
	if err := p.expect(','); err != nil {
		return Output{}, err
	}
	hash, err := p.str()
	if err != nil {
		return Output{}, err
	}
	if err := p.expect(')'); err != nil {
		return Output{}, err
	}
	return Output{
		Name:     OutputName(name),
		Path:     StorePath(path),
		HashAlgo: algo,
		Hash:     hash,
	}, nil
}

func (p *parser) inputDrv() (InputDrv, error) {
	if err := p.expect('('); err != nil {
		return InputDrv{}, err
	}
	path, err := p.str()
	if err != nil {
		return InputDrv{}, err
	}
	if err := p.expect(','); err != nil {
		return InputDrv{}, err
	}
	names, err := listOf(p, func(q *parser) (OutputName, error) {
		s, err := q.str()
		return OutputName(s), err
	})
	if err != nil {
		return InputDrv{}, err
	}
	if err := p.expect(')'); err != nil {
		return InputDrv{}, err
	}
	return InputDrv{Path: StorePath(path), Outputs: names}, nil
}

func (p *parser) envEntry() (EnvEntry, error) {
	if err := p.expect('('); err != nil {
		return EnvEntry{}, err
	}
	key, err := p.str()
	if err != nil {
		return EnvEntry{}, err
	}
	if err := p.expect(','); err != nil {
		return EnvEntry{}, err
	}
	value, err := p.str()
	if err != nil {
		return EnvEntry{}, err
	}
	if err := p.expect(')'); err != nil {
		return EnvEntry{}, err
	}
	return EnvEntry{Key: key, Value: value}, nil
}

// Parse reads a derivation from its ATerm text.
//
// A trailing newline is tolerated, because a .drv checked into a repository has
// one and the store object does not.
//
// Note how much of this function is error plumbing. Go has no `?`, so every
// step of a nine-step grammar spends three lines on propagation. That is the
// single largest source of bulk in this implementation, and it is honest to say
// it is verbosity rather than weakness: nothing here is unexpressible.
func Parse(text string) (Derivation, error) {
	p := &parser{text: []byte(strings.TrimSpace(text))}
	var d Derivation
	if err := p.literal("Derive("); err != nil {
		return d, err
	}
	outputs, err := listOf(p, (*parser).output)
	if err != nil {
		return d, err
	}
	if err := p.expect(','); err != nil {
		return d, err
	}
	inputDrvs, err := listOf(p, (*parser).inputDrv)
	if err != nil {
		return d, err
	}
	if err := p.expect(','); err != nil {
		return d, err
	}
	inputSrcs, err := listOf(p, func(q *parser) (StorePath, error) {
		s, err := q.str()
		return StorePath(s), err
	})
	if err != nil {
		return d, err
	}
	if err := p.expect(','); err != nil {
		return d, err
	}
	system, err := p.str()
	if err != nil {
		return d, err
	}
	if err := p.expect(','); err != nil {
		return d, err
	}
	builder, err := p.str()
	if err != nil {
		return d, err
	}
	if err := p.expect(','); err != nil {
		return d, err
	}
	args, err := listOf(p, (*parser).str)
	if err != nil {
		return d, err
	}
	if err := p.expect(','); err != nil {
		return d, err
	}
	env, err := listOf(p, (*parser).envEntry)
	if err != nil {
		return d, err
	}
	if err := p.expect(')'); err != nil {
		return d, err
	}
	return Derivation{
		Outputs:   outputs,
		InputDrvs: inputDrvs,
		InputSrcs: inputSrcs,
		System:    system,
		Builder:   builder,
		Args:      args,
		Env:       env,
	}, nil
}

// Escape applies exactly the five ATerm escapes, and nothing else.
func Escape(s string) string {
	var out strings.Builder
	out.Grow(len(s))
	for _, r := range s {
		switch r {
		case '"':
			out.WriteString(`\"`)
		case '\\':
			out.WriteString(`\\`)
		case '\n':
			out.WriteString(`\n`)
		case '\r':
			out.WriteString(`\r`)
		case '\t':
			out.WriteString(`\t`)
		default:
			out.WriteRune(r)
		}
	}
	return out.String()
}

// Quote escapes and wraps in double quotes.
func Quote(s string) string { return `"` + Escape(s) + `"` }

// SerializeOptions selects one of the two variants needed for hashing.
//
// Getting either backwards yields a syntactically perfect derivation with wrong
// paths, which is worse than an error because it looks correct.
type SerializeOptions struct {
	// MaskOutputs blanks this derivation's own output paths, in the outputs
	// list AND in the env entries whose KEY is an output name. Required when
	// computing those paths, since they are what is being computed. It must NOT
	// blank an output path that merely appears inside some other value, which
	// is precisely where a textual substitution goes wrong.
	MaskOutputs bool
	// InputHashes replaces each input's store path with that input's own hash,
	// and RE-SORTS by it. The serialized .drv sorts inputs by PATH; the form
	// that gets hashed sorts them by HASH. One derivation, two orderings.
	//
	// A nil map means "do not substitute", which is Go's Option again: here the
	// nil-map encoding is safe because a nil map reads as empty and the
	// distinction that matters is nil versus non-nil, checked explicitly below.
	InputHashes map[StorePath]string
}

// Unparse serializes a derivation back to ATerm, in the plain canonical form.
//
// This is the inverse of Parse on canonical input.
func Unparse(d Derivation) string {
	return UnparseWith(d, SerializeOptions{})
}

// UnparseWith serializes a derivation, selecting one of the hashing variants.
func UnparseWith(d Derivation, opts SerializeOptions) string {
	outs := make([]string, 0, len(d.Outputs))
	for _, o := range d.Outputs {
		path := string(o.Path)
		if opts.MaskOutputs {
			path = ""
		}
		outs = append(outs, "("+strings.Join([]string{
			Quote(string(o.Name)), Quote(path), Quote(o.HashAlgo), Quote(o.Hash),
		}, ",")+")")
	}

	type entry struct {
		key   string
		names []OutputName
	}
	entries := make([]entry, 0, len(d.InputDrvs))
	for _, i := range d.InputDrvs {
		key := string(i.Path)
		if opts.InputHashes != nil {
			if h, ok := opts.InputHashes[i.Path]; ok {
				key = h
			}
		}
		entries = append(entries, entry{key: key, names: i.Outputs})
	}
	if opts.InputHashes != nil {
		sort.Slice(entries, func(a, b int) bool { return entries[a].key < entries[b].key })
	}
	ins := make([]string, 0, len(entries))
	for _, e := range entries {
		names := make([]string, 0, len(e.names))
		for _, n := range e.names {
			names = append(names, Quote(string(n)))
		}
		ins = append(ins, "("+Quote(e.key)+",["+strings.Join(names, ",")+"])")
	}

	srcs := make([]string, 0, len(d.InputSrcs))
	for _, s := range d.InputSrcs {
		srcs = append(srcs, Quote(string(s)))
	}
	args := make([]string, 0, len(d.Args))
	for _, a := range d.Args {
		args = append(args, Quote(a))
	}

	names := d.OutputNames()
	env := make([]string, 0, len(d.Env))
	for _, e := range d.Env {
		value := e.Value
		if opts.MaskOutputs && names[OutputName(e.Key)] {
			value = ""
		}
		env = append(env, "("+Quote(e.Key)+","+Quote(value)+")")
	}

	return "Derive([" + strings.Join(outs, ",") +
		"],[" + strings.Join(ins, ",") +
		"],[" + strings.Join(srcs, ",") +
		"]," + Quote(d.System) +
		"," + Quote(d.Builder) +
		",[" + strings.Join(args, ",") +
		"],[" + strings.Join(env, ",") + "])"
}
