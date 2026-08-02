(** Nix values, and the laziness that makes them Nix values.

    {1 Laziness is [Lazy.t], not a hand-rolled thunk}

    Nix is call-by-need with update-in-place: an expression becomes a thunk,
    is forced at most once, and the result is written back. OCaml's [Lazy.t] is
    exactly that, so the decision record's "use each language's standard
    primitive" applies directly here.

    It also gives BLACKHOLING for free, which is the part worth noticing.
    Forcing a [Lazy.t] that is already being forced raises
    [Lazy.Undefined], and that is precisely Nix's "infinite recursion
    encountered". We do not have to detect the cycle ourselves; the standard
    library already does, because the same problem arises for [let rec] values.

    {1 Strings carry a CONTEXT}

    This is the one part of Nix's value model with no analogue in the eDSLs.
    A string knows which store paths must be built before it means anything, so
    interpolating a derivation into a string ADDS A DEPENDENCY. That mechanism
    is what the eDSLs deliberately do without, making the caller write the edge
    by hand (see `impl/*/README.md`), and it is why the front-end needs
    something the signature does not have. *)

(** One element of a string's context.

    Nix writes these as strings with a sigil, which is a serialization detail
    rather than the type: [/nix/store/...] plain, [!out!/nix/store/....drv],
    and [=/nix/store/....drv]. Writing it as a VARIANT is the honest shape,
    because the three cases mean three different things to a derivation and a
    sigil that is mis-parsed becomes the wrong kind of edge silently.

    The three cases and what each becomes in the IR:

    - [Opaque p]: a source in the store, and therefore an [inputSrcs] entry.
    - [Built (output, drv)]: one OUTPUT of a derivation, and therefore an
      [inputDrvs] edge naming that output. This is the case that carries the
      whole dependency graph.
    - [Drv_deep drv]: the derivation itself and its entire closure, which is
      what interpolating a [drvPath] means. Rare, and it exists so that
      [builtins.unsafeDiscardOutputDependency] has something to discard. *)
type ctx_elem =
  | Opaque of string
  | Built of string * string
  | Drv_deep of string

module Context = Set.Make (struct
  type t = ctx_elem

  let compare = compare
end)

type value =
  | Int of int
  | Float of float
  | Bool of bool
  | Str of string * Context.t
      (** The context is the set of store paths this string depends on. *)
  | Path of string
  | Null
  | Attrs of attrs
  | List of thunk list
  | Lambda of env * Ast.pattern * Ast.t
  | Primop of string * int * (thunk list -> value)
      (** name, arity, implementation. Applied one argument at a time, as Nix
          does, so a partially applied primop is itself a value. *)

(** Sorted by name, as Nix keeps them. *)
and attrs = (string * thunk) list

and thunk = value Lazy.t

(** An environment: static bindings, plus the [with] scopes that are consulted
    only when a name is not statically bound.

    [with] is genuinely dynamic scoping, and keeping it in a separate list is
    what makes the precedence right: a `let`-bound name always beats a `with`,
    however deeply nested the `with` is. *)
and env = {bindings : attrs; withs : thunk list}

exception Eval_error of string

let error fmt = Printf.ksprintf (fun s -> raise (Eval_error s)) fmt

let empty_env = {bindings = []; withs = []}

(** Attribute sets are kept sorted, which makes lookup a binary search in
    principle and, more importantly here, makes iteration order canonical
    without a sort at every use. *)
let attrs_of_list (l : (string * thunk) list) : attrs =
  List.sort_uniq (fun (a, _) (b, _) -> String.compare a b) l

let attrs_find (a : attrs) (k : string) : thunk option = List.assoc_opt k a

let type_name = function
  | Int _ -> "an integer"
  | Float _ -> "a float"
  | Bool _ -> "a Boolean"
  | Str _ -> "a string"
  | Path _ -> "a path"
  | Null -> "null"
  | Attrs _ -> "a set"
  | List _ -> "a list"
  | Lambda _ | Primop _ -> "a function"

(** [builtins.typeOf]. The nine names are the whole type universe; see
    `docs/nix-internals.md`. *)
let type_of = function
  | Int _ -> "int"
  | Float _ -> "float"
  | Bool _ -> "bool"
  | Str _ -> "string"
  | Path _ -> "path"
  | Null -> "null"
  | Attrs _ -> "set"
  | List _ -> "list"
  | Lambda _ | Primop _ -> "lambda"

(** Force a thunk, turning OCaml's cycle detection into Nix's error message. *)
let force (t : thunk) : value =
  try Lazy.force t
  with Lazy.Undefined -> error "infinite recursion encountered"

(** {1 The context is a monoid homomorphism, and that is the mechanism}

    A Nix string is not an element of the free monoid over characters. It is an
    element of

    {v Sigma* x P_fin(ctx_elem) v}

    the PRODUCT of the free monoid on characters with the free join-semilattice
    on context elements. Concatenation is the product operation, componentwise,
    so [context] is a monoid homomorphism:

    {v context (a ^ b) = context a UNION context b v}

    and that homomorphism IS the mechanism by which interpolating a derivation
    into a string adds a dependency. The user never writes the edge; it is
    computed, and it is computed by a structure-preserving map, which is why it
    cannot be forgotten by any path through the evaluator that builds a string.

    This is exactly what the four eDSLs do NOT have. There, the caller passes
    [input_drvs] by hand, so the edge is data the user supplies. Here the edge
    is a consequence of the string algebra. That difference is the reason the
    front-end needs something [docs/spec/signature.md] does not contain, and
    the reason a signature that only describes derivations cannot describe a
    Nix evaluator. *)
