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

module Context = Set.Make (String)

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
