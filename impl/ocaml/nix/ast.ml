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
  | Path_interp of part list
      (** A path containing an interpolation, [./x/${v}.nix].

          NOT a string: Nix models it as a concatenation whose first element is
          a path, and prints it as [(/abs/x/ + v + ".nix")]. The parts follow
          the same [Lit]/[Anti] shape as a string's, with the leading path
          carried as an [Anti (Path ...)] so it prints bare. *)
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
  | Astr of part list  (** [."a"], an attribute named by a STRING literal. *)
  | Adyn of t
      (** [.${e}], an attribute named by an expression DIRECTLY.

          Distinct from [Astr [Anti e]], which is [."${e}"], because Nix keeps
          them distinct and prints them differently: [a.${k}] prints as
          [(a)."${k}"] while [{ "${k}" = 1; }] prints as [{ "${(k)}" = 1; }].
          The parenthesised form is the string wrapper showing through. The two
          were conflated here until the nixpkgs corpus separated them. *)

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

(** The directory relative paths are resolved against.

    Nix resolves a relative path at PARSE time, against the directory of the
    file being parsed, so `./common/x11.nix` in
    `nixos/tests/xautolock.nix` becomes `/abs/path/nixos/tests/common/x11.nix`
    in the AST and `nix-instantiate --parse` prints the absolute form. A parser
    that keeps the relative text produces a different tree, which is why this
    exists.

    A ref rather than a parameter because menhir's generated entry point takes
    only a lexer; {!Nix.parse_string} sets it. Empty means "leave paths alone",
    which is what the transpiler and the unit vectors want. *)
let base_dir = ref ""

(** Canonicalise a path the way Nix's [absPath] does: fold away [.] and [..],
    collapse repeated separators, and drop a trailing one. *)
let canonicalise (p : string) : string =
  let parts = String.split_on_char '/' p in
  let stack =
    List.fold_left
      (fun acc part ->
        match part with
        | "" | "." -> acc
        | ".." -> ( match acc with [] -> [] | _ :: tl -> tl)
        | c -> c :: acc)
      []
      parts
  in
  "/" ^ String.concat "/" (List.rev stack)

(** The home directory a leading [~] expands to.

    Nix expands [~/x] at PARSE time, so a tilde path becomes absolute in the
    tree. That makes a parse depend on the environment, which is Nix's choice
    rather than ours; reproducing it is what the differential test needs, and
    keeping it in a ref lets a caller who wants a machine-independent parse
    leave it empty. *)
let home_dir = ref ""

(** Resolve a path literal against {!base_dir}, or {!home_dir} for a tilde. *)
let resolve_path (p : string) : string =
  if String.length p > 0 && p.[0] = '~' then
    if String.equal !home_dir "" then p
    else canonicalise (!home_dir ^ String.sub p 1 (String.length p - 1))
  else if String.equal !base_dir "" then p
  else if String.length p > 0 && p.[0] = '/' then canonicalise p
  else canonicalise (!base_dir ^ "/" ^ p)

(** Resolve the literal PREFIX of an interpolated path.

    Same as {!resolve_path} except that a trailing separator is kept, because
    it is meaningful here: [./x/${v}] denotes [/abs/x/] concatenated with [v],
    and dropping the separator would silently glue the two segments together.
    Canonicalising removes it, so it is put back. *)
let resolve_path_prefix (p : string) : string =
  let resolved = resolve_path p in
  if
    String.length p > 0
    && p.[String.length p - 1] = '/'
    && not (String.equal resolved "/")
  then resolved ^ "/"
  else resolved
