(** The surface: build Nix expressions in OCaml.

    This is what a developer writes instead of learning the Nix language, and
    it is the layer [docs/architecture.md] calls the SURFACE. It hands back
    {!Ast.t}, the inspectable core, so everything downstream (printing to
    `.nix`, evaluating, checking) works on data rather than on host closures.

    {1 Binders are HOAS here and named underneath}

    A lambda is written with an OCaml function:

    {[
      lam (fun x -> attrs [("name", x)])
    ]}

    which is what makes it composable and frees the caller from inventing
    names. {!lam} lowers that to a NAMED binder immediately, with a fresh
    supply, because the printer needs a name to print. That two-layer split is
    the recommendation in [docs/theory.md] section 8, and it is the only place
    in the library that ever sees a host closure. *)

open Ast

(* A fresh-name supply. Names are prefixed so they cannot collide with anything
   a caller wrote, and the counter is per-term rather than global so the same
   term prints the same way twice, which the round-trip law needs. *)
let counter = ref 0

let reset () = counter := 0

let fresh base =
  incr counter ;
  Printf.sprintf "%s%d" base !counter

(** {1 Literals} *)

let int n = Int n

let float f = Float f

let str s = Str [Lit s]

let path p = Path p

let var x = Var x

let bool b = Var (if b then "true" else "false")

let null = Var "null"

(** An interpolated string: [istr [`S "a"; `E e; `S "c"]] is ["a${e}c"]. *)
let istr parts =
  Str (List.map (function `S s -> Lit s | `E e -> Anti e) parts)

(** {1 Structure} *)

let list items = List items

(** An attribute set from (name, value) pairs. *)
let attrs pairs =
  Attr_set
    {
      recursive = false;
      binds = List.map (fun (k, v) -> Bind ([Aid k], v)) pairs;
    }

(** A recursive attribute set: bindings can refer to each other by name. *)
let rec_attrs pairs =
  Attr_set
    {recursive = true; binds = List.map (fun (k, v) -> Bind ([Aid k], v)) pairs}

let select e path = Select (e, List.map (fun p -> Aid p) path, None)

let select_or e path d = Select (e, List.map (fun p -> Aid p) path, Some d)

let apply f args = List.fold_left (fun acc a -> Apply (acc, a)) f args

(** {1 Binders} *)

(** A lambda, written with an OCaml function.

    The bound variable is materialised as a fresh NAME, so the result is
    ordinary inspectable syntax rather than a closure. *)
let lam ?(name = "x") (f : t -> t) : t =
  let n = fresh name in
  Lambda (Pvar n, f (Var n))

(** A lambda taking an attribute set, [{ a, b ? d }: body].

    The body receives a lookup function rather than a record, because the
    formals are named by the caller and OCaml cannot give them back as fields. *)
let lam_attrs ?(ellipsis = false) (formals : (string * t option) list)
    (f : (string -> t) -> t) : t =
  let body = f (fun name -> Var name) in
  Lambda (Pset {formals; ellipsis; alias = None}, body)

(** [let_ [(name, value)] body], with the bindings in scope in each other and
    in the body, as Nix's [let] is. *)
let let_ pairs body =
  Let (List.map (fun (k, v) -> Bind ([Aid k], v)) pairs, body)

(** [let_in v (fun x -> ...)]: bind one value and use it, without naming it.

    This is the composable form: the caller never sees the generated name, so
    two independently written fragments cannot capture each other's variables. *)
let let_in ?(name = "v") (value : t) (f : t -> t) : t =
  let n = fresh name in
  Let ([Bind ([Aid n], value)], f (Var n))

(** {1 Operators} *)

let ( +@ ) a b = Op (Add, a, b)

let ( //@ ) a b = Op (Update, a, b)

let ( ++@ ) a b = Op (Concat, a, b)

let ( ==@ ) a b = Op (Eq, a, b)

let if_ c t f = If (c, t, f)

(** {1 Composability: overlays as mixins}

    An overlay is [final: prev: { ... }], which is Cook and Palsberg's wrapper
    over a generator ([docs/theory.md] section 8). Composition is asymmetric
    and associative with an identity, so overlays form a MONOID, and [fix] is
    the map out of it. *)

(** final, previous, additions *)
type overlay = t -> t -> t

(** The identity overlay: adds nothing. *)
let overlay_id : overlay = fun _final _prev -> attrs []

(** [compose a b] applies [a] first, then [b] on top, so [b] wins on a clash,
    matching how a later overlay in a list overrides an earlier one. *)
let compose (a : overlay) (b : overlay) : overlay =
 fun final prev ->
  let after_a = a final prev in
  Op (Update, after_a, b final (Op (Update, prev, after_a)))

let compose_all (os : overlay list) : overlay =
  List.fold_left compose overlay_id os

(** Close an overlay into a package set with the knot tied.

    Emits [(let final = base // (overlay final base); in final)], which is the
    fixed point written out in Nix rather than computed here: the point of a
    transpiler is that the OUTPUT does the work. *)
let fix (base : t) (o : overlay) : t =
  let n = fresh "final" in
  Let ([Bind ([Aid n], Op (Update, base, o (Var n) base))], Var n)

(** {1 Output} *)

let to_nix (e : t) : string = Emit.to_string e
