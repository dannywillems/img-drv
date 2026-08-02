(** The Nix language AST.

    Faithful to the grammar in [NixOS/nix] [src/libexpr/parser.y] at commit
    [a86a3638], and deliberately NOT desugared: the parser records what was
    written, and {!Printer} applies the desugaring that
    [nix-instantiate --parse] applies. Keeping the two apart is what lets the
    printer be checked against Nix while the AST stays useful for anything
    else (a formatter would want the sugar back). *)

type t =
  | Int of int
  | Float of float
  | Str of part list  (** A double-quoted string, possibly interpolated. *)
  | Ind_str of part list  (** An indented [''...''] string. *)
  | Path of string
  | Search_path of string  (** [<nixpkgs>] *)
  | Uri of string
      (** [scheme:path]. Note that [x:x] lexes as THIS and not as a lambda;
          see [docs/nix-internals.md]. *)
  | Var of string
  | Lambda of pattern * t
  | Apply of t * t
  | Select of t * attrpath * t option  (** [e.a.b] with an optional [or e']. *)
  | Has_attr of t * attrpath  (** [e ? a.b] *)
  | List of t list
  | Attr_set of {recursive : bool; binds : bind list}
  | Let of bind list * t
  | With of t * t
  | Assert of t * t
  | If of t * t * t
  | Op of op * t * t
  | Not of t
  | Neg of t  (** Unary minus, which the printer desugars to [__sub 0 e]. *)

and part = Lit of string | Anti of t

and attr =
  | Aid of string  (** [a] *)
  | Astr of part list  (** [."a"] or [.${e}] *)

and attrpath = attr list

and bind =
  | Bind of attrpath * t
  | Inherit of t option * attr list  (** [inherit (from) a b;] *)

and pattern =
  | Pvar of string  (** [x: ...] *)
  | Pset of {formals : formal list; ellipsis : bool; alias : string option}

(** [a] or [a ? default] *)
and formal = string * t option

and op =
  | Add
  | Sub
  | Mul
  | Div
  | Update  (** [//] *)
  | Concat  (** [++] *)
  | Eq
  | Neq
  | Lt
  | Gt
  | Le
  | Ge
  | And
  | Or
  | Impl  (** [->] *)
