# How Nix actually works

Written to be implementable against, not to sell anything. Every claim here
should carry a source; where one is missing it is marked UNVERIFIED and must be
checked before code depends on it.

## The three systems people call "Nix"

1. **The evaluator.** Reads the Nix language, produces derivations. Lazy, pure,
   dynamically typed. Its only output that matters is `.drv` files.
2. **The store and the daemon.** Realizes derivations: sandboxed builds, the
   content-addressed store, garbage collection, substituters, remote builders.
3. **NixOS.** A module system on top, producing a system closure and an
   activation script.

`img-drv` replaces (1), reuses (2), and defers (3).

## Expressions, derivations, outputs: three stages, not two

The single most common confusion, and the one that decides what this project
can and cannot read. These are three different things with three different
representations:

| stage | what it is | representation |
| --- | --- | --- |
| **expression** | source in the Nix LANGUAGE | `default.nix`, `flake.nix`: text in a lazy functional language |
| **derivation** | a build recipe, first-order DATA | `/nix/store/<hash>-name.drv`, an ATerm |
| **output** | the built files | `/nix/store/<hash>-name/`, a directory |

and two transitions between them:

```
expression --[ evaluate ]--> derivation --[ realise ]--> output
              nix-instantiate              nix-store --realise
```

So yes: **an expression produces a derivation**, by evaluation. It is not a
different notation for one. `pkgs/.../cnijfilter_2_80/default.nix` is 140 lines
of Nix calling `stdenv.mkDerivation`; evaluating it yields ONE `.drv` whose
closure is 1458 derivations, because `stdenv`, its inputs, and their inputs are
all expressions that evaluate to derivations too.

The evaluation is where nearly all of Nix's complexity lives: laziness, the
module system's fixed point, `import`, string contexts, and the whole of
nixpkgs' `lib`. The derivation, by contrast, is inert first-order data with a
documented on-disk format, which is exactly why `img-drv` targets it.

**What that means for this project.** The four implementations here read and
write DERIVATIONS. None of them can parse an expression, and that is a design
choice rather than an omission: the eDSLs replace the evaluator, so a build is
described in Python, Rust, Go or OCaml and emitted straight as a `.drv`. The
gap is visible and measurable: `cnijfilter_2_80`'s expression cannot be parsed
by anything here, while its instantiated closure verifies completely (1458 of
1458 round-tripped byte-identically, 2063 of 2063 output paths reproduced, in
all four languages).

Closing that gap means writing an evaluator, which is `PLAN.md` phase 4 and is
deliberately the largest remaining item.

## What exactly is a Nix expression

**First, a correction to the obvious question: there are no type inference
rules, because Nix has no static type system.** It is dynamically typed, in the
same sense as Python or Scheme. Nothing is checked before evaluation, there are
no type annotations, no inference, no principal types, and no way to declare a
type of your own. An expression is checked by running it, and a type error is a
runtime error that only surfaces on a code path you actually took. That is the
single most important fact about the language for anyone building a front-end,
and it is why a partial evaluator cannot lean on types to tell it what it has.

What DOES exist is a grammar, a fixed set of runtime value tags, and a
call-by-need evaluation order.

Everything below is read out of the Nix source at commit
[`a86a3638`](https://github.com/NixOS/nix/tree/a86a363831d4eab7ad5c1d62a6bdc0380c94bd63),
not recalled. Line numbers are against that commit; re-verify and move the pin
together.

### The grammar

`src/libexpr/parser.y` is a Bison grammar, layered by precedence. The
nonterminals, outermost first:

```
expr            -> expr_function
expr_function   -> ID ':' expr_function                  -- lambda
                 | formal_set ':' expr_function          -- { a, b ? e, ... }:
                 | formal_set '@' ID ':' expr_function   -- {...}@args:
                 | ID '@' formal_set ':' expr_function   -- args@{...}:
                 | ASSERT expr ';' expr_function
                 | WITH expr ';' expr_function
                 | LET binds IN expr_function
                 | expr_if
expr_if         -> IF expr THEN expr ELSE expr
                 | expr_pipe_from | expr_pipe_into | expr_op
expr_op         -> the operator table below
expr_app        -> expr_app expr_select | expr_select     -- application, left assoc
expr_select     -> expr_simple '.' attrpath [OR_KW expr_select]
expr_simple     -> ID | INT | FLOAT | '"' string_parts '"'
                 | IND_STRING_OPEN ind_string_parts       -- '' ... ''
                 | path | SPATH | URI | '(' expr ')'
                 | LET '{' binds '}'                      -- deprecated
                 | REC '{' binds '}' | '{' binds '}' | '[' list ']'
```

Note what is NOT there: no pattern matching (attribute-set destructuring in a
lambda argument is the only thing resembling it), no type declarations, no
modules or namespaces, no user-defined operators, and no loops. Recursion and
`builtins.foldl'` do all the work.

`expr_function` being the top of the tree is why `x: y: z` parses as
`x: (y: z)` and why `a: b == c` is `a: (b == c)`: a lambda body extends as far
right as it can.

### Operator precedence, which has two real oddities

From `parser.y:208-219`, lowest binding to highest:

| level | operators | associativity |
| --- | --- | --- |
| 1 | `->` | right |
| 2 | `\|\|` | left |
| 3 | `&&` | left |
| 4 | `==` `!=` | non-assoc |
| 5 | `<` `>` `<=` `>=` | non-assoc |
| 6 | `//` | right |
| 7 | `!` | left |
| 8 | `+` `-` | left |
| 9 | `*` `/` | left |
| 10 | `++` | right |
| 11 | `?` | non-assoc |
| 12 | unary `-` | non-assoc |

Two things here surprise almost everyone:

- **`!` binds LOOSER than arithmetic**, sitting between `//` and `+`. So
  `!a + b` is `!(a + b)`, not `(!a) + b`. In C-family languages unary `not` is
  near the top.
- **`//` (attribute-set update) binds tighter than the comparisons**, so
  `a // b == c` is `(a // b) == c`.

`==` and `<` are non-associative, so `a == b == c` is a syntax error rather
than a silent mis-parse, which is the right choice.

### The types, such as they are

There is no type LANGUAGE, only a tag on every runtime value. From
`src/libexpr/include/nix/expr/value.hh:75`, the `ValueType` enum is:

```
nInt  nFloat  nBool  nString  nPath  nNull  nAttrs  nList  nFunction
```

plus three that are not user-visible: `nThunk` (unevaluated), `nFailed`, and
`nExternal` (plugin values). `builtins.typeOf` maps them to the nine strings
`"int" "float" "bool" "string" "path" "null" "set" "list" "lambda"`.

That is the whole type universe. Consequences worth stating plainly:

- **No sum types, no records with fixed fields, no parametric polymorphism.**
  An attribute set is the only compound structure, and it is heterogeneous and
  open.
- **Strings carry a hidden component**: a *string context*, the set of store
  paths that must be built before the string is meaningful. This is invisible
  to `typeOf` and is what makes `"${pkgs.hello}/bin/hello"` add a dependency.
  It is data smuggled inside a value tag, and it is the one part of the value
  model with no analogue in this project's IR.
- **Paths are a distinct type from strings**, which is why `./foo` and
  `"./foo"` behave differently and why copying a path to the store is
  implicit.
- **Integers are 64-bit and overflow is checked**, floats are doubles, and the
  two do not unify: `1 + 1.0` works by coercion in the primop, not by a typing
  rule.

### What people mean when they say "types" in Nix

Two different things, neither of which is a language type system:

1. **`builtins.typeOf` and friends** (`isAttrs`, `isFunction`, ...): runtime
   tag inspection. Every primop that needs an argument of a given shape checks
   it itself and throws on mismatch.
2. **`lib.types` in nixpkgs**: the MODULE SYSTEM's option types. These are
   ordinary values, records of a `check` predicate and a `merge` function, used
   by `lib.evalModules` at runtime to validate and combine option definitions.
   They are a library, not a checker, and they are what `theory.md` section 6
   is about. `types.int` cannot make an ill-typed expression fail to parse; it
   makes a bad option definition fail to evaluate, with a better message.

### Evaluation order

Call-by-need. Every expression becomes a thunk, forced at most once, with the
result written back in place. `nThunk` in the value enum is that machinery
leaking into the type tag. Laziness is not an optimisation here: it is what
makes nixpkgs possible at all, since evaluating one attribute of a set of
100000 packages must not evaluate the other 99999. It is also why the module
system's fixed point works and why a cycle reports "infinite recursion
encountered" rather than being caught statically.

### `nix-instantiate --parse` is a differential oracle for a parser

It re-prints the parsed AST, so it pins tree SHAPE rather than merely "it
parsed". Every row below was produced by the pinned Nix, and together they
specify the printer a front-end has to match.

| input | `--parse` output | what it pins |
| --- | --- | --- |
| `1 + 2 * 3` | `(1 + (__mul 2 3))` | precedence, and that `*` DESUGARS |
| `!a + b` | `(! (a + b))` | `!` really does bind looser than `+` |
| `a // b == c` | `((a // b) == c)` | `//` binds tighter than `==` |
| `a ++ b ++ c` | `(a ++ (b ++ c))` | `++` is right associative |
| `a -> b -> c` | `(a -> (b -> c))` | `->` is right associative |
| `-a` | `(__sub 0 a)` | unary minus desugars |
| `a - -a` | `(__sub a (__sub 0 a))` | binary `-` desugars too, though `+` does not |
| `"a${toString b}c"` | `("a" + (toString b) + "c")` | interpolation is a `+` chain |
| `a.b.${"c"}` | `(a).b.c` | a constant dynamic attribute is folded |
| `a.b.c or d` | `(a).b.c or (d)` | select parenthesises its operand |
| `[ a (a) ]` | `[ (a) (a) ]` | list elements are always parenthesised |

Two things to know before relying on it:

- it performs **static scope resolution** and fails with "undefined variable"
  on a free variable, so a probe has to bind everything it mentions;
- it prints a **desugared** tree, so a front-end matching it has to reproduce
  the desugaring (`*` to `__mul`, `/` to `__div`, `-` to `__sub`, unary minus
  to `__sub 0`, interpolation to `+`), not merely the parse.

### One lexer trap worth knowing before writing a lexer

```
let f = x:x; in f 1 2   =>   (let f = "x:x"; in (f 1 2))
```

`x:x` is not a lambda. It lexes as a **URI**, because Nix has a URI token
(`scheme:path` with no whitespace) and it wins against `ID ':' expr`. Writing
`x: x` with the space gives the lambda. A hand-written lexer that tokenises
identifiers and `:` separately will silently disagree with Nix here, and the
disagreement is invisible until something evaluates the string as a function.

This is the strongest single argument for generating the lexer from the same
kind of maximal-munch rules Nix's own Flex file uses, rather than hand-rolling
one, and it is why `docs/decisions/2026-08-02-nix-frontend-build-not-reuse.md`
settles on the standard tools per language.

### What this means for a front-end

The grammar is small and a parser is a weekend. The evaluator is not, and the
absence of types is precisely why: nothing can be resolved ahead of time, so a
front-end has to implement laziness, string contexts, and enough of `lib` and
`stdenv` to reach a `derivation` call. `PLAN.md` phase 4 sizes that honestly,
and notes that Snix already has an evaluator worth comparing against before
writing another.

## Derivations: the IR

A **store derivation** is the reified build description. It is stored on disk in
**ATerm** format, and the derivation itself is content-addressed using the
"text" method of content addressing.
Source: <https://nix.dev/manual/nix/2.34/store/derivation/> and the derivation
ATerm format page in the same manual.

Fields (to be confirmed field-by-field against the manual before implementing):

- `outputs`: named outputs and their paths
- `inputDrvs`: other derivations this one depends on, with the outputs needed
- `inputSrcs`: store paths used directly as sources
- `system`: e.g. `x86_64-linux`
- `builder`: the executable to run
- `args`: its arguments
- `env`: the environment it runs under

Note from the manual worth remembering: the ATerm format does NOT contain the
derivation's name, on the assumption that a store path is supplied
out-of-band.

## Input addressing: why paths are known before building

In the default (input-addressed) scheme, a store path is computed from a hash
over the derivation, which transitively includes the hashes of every input
derivation. So the output path is determined BEFORE anything is built.

That single property is what makes substitution possible: Nix can ask a binary
cache "do you have this path?" without building, because it already knows the
path it would produce.

Content-addressed derivations, where the path is derived from the built output
instead, exist but are experimental.

## Purity comes from the sandbox, not the language

The Nix language being pure is not what makes builds reproducible. The BUILDER
is sandboxed: no network access, a fixed environment, an isolated filesystem,
timestamps normalized. The escape hatch is the **fixed-output derivation**,
which is allowed network access precisely because it declares the hash of what
it will fetch up front, so the result is still verified.

This is the piece `img-drv` most wants to reuse rather than reimplement.

## Realisation: turning the recipe into files

A derivation is inert data. `minimal.drv` says: run `/bin/sh` with
`["-c","echo hi > $out"]` and this environment. Nothing has executed.
`nix-instantiate` stops here, having evaluated the language down to
derivations and written them to the store. The output path is nevertheless
already fixed, even though nothing exists there yet: that is input addressing,
the path is a hash of the RECIPE, not of the result.

`nix-store --realise` (or `nix build`) turns a recipe into files. For each
output path:

1. **Does the path already exist?** If so, done, nothing runs. This is why
   rebuilding an unchanged package is instant.
2. **Can a substituter provide it?** Nix asks a binary cache "do you have this
   path?", and because the path was computed from the recipe the cache can
   answer WITHOUT building anything. If yes, it downloads a prebuilt result.
   This is why most Nix users never compile anything.
3. **Otherwise build it**, having first realised every `inputDrvs` entry
   recursively, which is the dependency graph doing its work.

The build itself runs `builder` with `args` in a sandbox:

- a fresh mount namespace containing only the declared inputs, the closure of
  `inputDrvs` and `inputSrcs`, and nothing else from the system
- no network, which is why a plain build cannot fetch anything
- a scrubbed environment holding exactly the derivation's `env`
- an empty writable `$TMPDIR`, typically an unprivileged build user, and
  timestamps normalised to 1970 so archives and mtimes are deterministic

The builder writes to `$out`, which is just an environment variable holding the
predetermined path. That is why `echo hi > $out` works at all.

For a real package the builder is not `/bin/sh` directly but bash from the
store, running a script that does the familiar `./configure && make && make
install` with `--prefix=$out`. Nothing exotic: real compilers producing real
binaries. The only unusual parts are WHERE the inputs come from (store paths,
not `/usr`) and WHERE the output goes.

When the builder exits, Nix makes the output read-only, scans it for references
to other store paths (the runtime closure is discovered by literally looking
for store path strings inside the files), and registers it in its database.

### The fixed-output escape hatch

Something has to download source tarballs, and builds have no network. Hence
the fixed-output derivation, which declares its result hash UP FRONT. Because
the output is verified against that hash, network access is safe: nothing can
be smuggled in, since the bytes must match. Every `fetchurl` in nixpkgs is one
of these.

### Why this is exactly what img-drv reuses

The sandboxing, the store database, garbage collection, the substituter
protocol and reference scanning are the hard 90%, and none of it is being
rebuilt. Emitting a byte-correct `.drv` is the whole interface: hand it to
`nix-store --realise` and all of that comes for free.

Which is why store path computation had to be exactly right. Wrong hashes
produce a syntactically valid derivation that no cache can ever satisfy, that
silently rebuilds the world, and whose outputs land at paths nothing else
refers to. Right shape, wrong identity. See
[`spec/store-paths.md`](spec/store-paths.md).

## Atomic activation is a symlink rename

`/run/current-system` points at a store path. A "generation" is a symlink.
Switching is repointing it plus running an activation script; rolling back is
repointing it at the previous one. Bootloader entries are generated per
generation.

Worth internalizing: the celebrated atomic rollback is mostly **a symlink swap
over an immutable store**. It is cheap to copy conceptually, and it is the
property `iso-img` most lacks.

## The module system is a fixed point

NixOS modules are functions of the FINAL configuration. Evaluation computes the
fixed point of that system of equations. Option declarations carry a type, and
the type supplies a merge function; `mkDefault`, `mkForce` and `mkOrder` adjust
priority when several modules define the same option.

Implementation entry points, for reading:
`nixpkgs/lib/modules.nix` and `nixpkgs/nixos/lib/eval-config.nix`.

The law that makes module ORDER irrelevant is that the merge be commutative,
associative and idempotent, i.e. a join-semilattice. See `theory.md` section 6.

## What is genuinely hard, and therefore reused

- sandboxing per platform (namespaces on Linux, `sandbox-exec` on macOS)
- the store, its database, and garbage collection with roots
- substituters, signatures and trust
- remote and distributed builds
- twenty years of accumulated corner cases in nixpkgs' stdenv

**Snix** and **Tvix** matter here: they split Nix into evaluator, builder and
store behind defined protocols, explicitly so alternative front-ends can plug
in. That is what makes a foreign front-end tractable rather than a rewrite.
Source: <https://snix.dev/blog/announcing-snix/>, <https://tvix.dev/>

## Open questions to resolve before Phase 1

- [x] Exact ATerm grammar and escaping rules, field by field. DONE, and
      derived empirically because the manual does not publish the grammar.
      See `spec/canonical.md`.
- [x] Exact store path hash computation. SOLVED and verified against real
      Nix; see `spec/store-paths.md` and `scripts/store_paths.py`.
- [x] How `inputDrvs` names outputs: `(drvPath, [outputNames])`. Multi-entry
      sort order is still open.
- [ ] Whether `nix-instantiate` output is byte-stable across Nix versions, and
      which version we pin as the differential oracle.
- [ ] Whether to target the Nix daemon protocol or simply write `.drv` files
      into the store and invoke `nix-store --realise`.
