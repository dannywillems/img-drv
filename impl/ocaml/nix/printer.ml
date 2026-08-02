(** Print an AST the way [nix-instantiate --parse] does.

    This exists to be DIFFERENTIALLY TESTED. Nix re-prints the tree it parsed,
    fully parenthesised and partly desugared, so matching its output byte for
    byte over real files proves our tree has the same SHAPE as Nix's, which is
    a far stronger claim than "it parsed".

    The desugarings are Nix's, not ours, and each one is checked in the test
    suite against the pinned Nix:

    - [a * b] prints as [(__mul a b)], [a / b] as [(__div a b)];
    - [a - b] prints as [(__sub a b)], but [a + b] keeps its [+];
    - unary minus prints as [(__sub 0 a)];
    - an interpolated string prints as a [+] chain;
    - a constant dynamic attribute [${"c"}] folds to a plain [c].

    See [docs/nix-internals.md] for the table these came from. *)

open Ast

let buf_add = Buffer.add_string

(** Nix prints a string literal with the same five escapes the lexer undoes. *)
let escape s =
  let b = Buffer.create (String.length s + 2) in
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | c -> Buffer.add_char b c)
    s ;
  Buffer.contents b

(** A bind tree: dotted paths expanded and shared prefixes merged. *)
type entry = Value of Ast.t | Nested of item list

and item =
  | Attr of string * entry
  | Inherit_item of Ast.t option * Ast.attr list

let op_symbol = function
  | Add -> "+"
  | Update -> "//"
  | Concat -> "++"
  | Eq -> "=="
  | Neq -> "!="
  | And -> "&&"
  | Or -> "||"
  | Impl -> "->"
  | Sub | Mul | Div | Lt | Gt | Le | Ge -> assert false (* desugared; see pp *)

(** The arithmetic operators Nix rewrites to builtin calls. Note that `+` is
    NOT among them, and neither is `!=`: the desugaring is not uniform, which
    is why each one is pinned by a vector rather than inferred from a rule. *)
let builtin_of = function
  | Sub -> Some "__sub"
  | Mul -> Some "__mul"
  | Div -> Some "__div"
  | _ -> None

(** The comparisons all reduce to `__lessThan`, three of them with an argument
    swap or a negation:

    - [a < b]  is [(__lessThan a b)]
    - [a > b]  is [(__lessThan b a)]
    - [a >= b] is [(! (__lessThan a b))]
    - [a <= b] is [(! (__lessThan b a))]

    Each is pinned by a vector in [docs/spec/nix-parse/vectors.tsv]. *)
let comparison_of = function
  | Lt -> Some (false, false)
  | Gt -> Some (false, true)
  | Ge -> Some (true, false)
  | Le -> Some (true, true)
  | _ -> None

let rec pp b (e : t) =
  match e with
  | Int n -> buf_add b (string_of_int n)
  (* C's `%g`, which is what Nix uses: `3.0` prints as `3`, `0.5e10` as
     `5e+09`, `1.5` and `0.1` unchanged. Pinned by four vectors, because a
     float formatter is exactly the kind of thing that looks right and differs
     in the last digit. *)
  | Float f -> buf_add b (Printf.sprintf "%g" f)
  | Var x -> buf_add b x
  | Path p -> buf_add b p
  (* `<nixpkgs>` desugars to a lookup against the search path, which is why a
     search path expression is impure: it reads NIX_PATH at evaluation time. *)
  | Search_path p -> buf_add b ("(__findFile __nixPath \"" ^ escape p ^ "\")")
  | Uri u -> buf_add b ("\"" ^ escape u ^ "\"")
  | Str parts | Ind_str parts -> pp_string b parts
  | Not e ->
      buf_add b "(! " ;
      pp b e ;
      buf_add b ")"
  | Neg e ->
      buf_add b "(__sub 0 " ;
      pp b e ;
      buf_add b ")"
  | Op (o, x, y) when comparison_of o <> None ->
      let negated, swapped = Option.get (comparison_of o) in
      let l, r = if swapped then (y, x) else (x, y) in
      if negated then buf_add b "(! " ;
      buf_add b "(__lessThan " ;
      pp b l ;
      buf_add b " " ;
      pp b r ;
      buf_add b ")" ;
      if negated then buf_add b ")"
  | Op (o, x, y) -> (
      match builtin_of o with
      | Some name ->
          buf_add b ("(" ^ name ^ " ") ;
          pp b x ;
          buf_add b " " ;
          pp b y ;
          buf_add b ")"
      | None ->
          buf_add b "(" ;
          pp b x ;
          buf_add b (" " ^ op_symbol o ^ " ") ;
          pp b y ;
          buf_add b ")")
  | Has_attr (e, path) ->
      buf_add b "((" ;
      pp b e ;
      buf_add b ") ? " ;
      pp_attrpath b path ;
      buf_add b ")"
  | Apply (f, a) ->
      buf_add b "(" ;
      pp_apply b f ;
      buf_add b " " ;
      pp b a ;
      buf_add b ")"
  | Select (e, path, dflt) ->
      buf_add b "(" ;
      pp b e ;
      buf_add b ")." ;
      pp_attrpath b path ;
      Option.iter
        (fun d ->
          buf_add b " or (" ;
          pp b d ;
          buf_add b ")")
        dflt
  | Lambda (p, body) ->
      buf_add b "(" ;
      pp_pattern b p ;
      buf_add b ": " ;
      pp b body ;
      buf_add b ")"
  | List items ->
      buf_add b "[ " ;
      List.iter
        (fun i ->
          buf_add b "(" ;
          pp b i ;
          buf_add b ") ")
        items ;
      buf_add b "]"
  | Attr_set {recursive; binds} ->
      if recursive then buf_add b "rec " ;
      buf_add b "{ " ;
      pp_items b (group_binds binds) ;
      buf_add b "}"
  | Let (binds, body) ->
      buf_add b "(let " ;
      pp_items b (group_binds binds) ;
      buf_add b "in " ;
      pp b body ;
      buf_add b ")"
  | With (e, body) ->
      buf_add b "(with " ;
      pp b e ;
      buf_add b "; " ;
      pp b body ;
      buf_add b ")"
  | Assert (c, body) ->
      (* Nix prints assert WITHOUT wrapping parentheses. *)
      buf_add b "assert " ;
      pp b c ;
      buf_add b "; " ;
      pp b body
  | If (c, t, f) ->
      buf_add b "(if " ;
      pp b c ;
      buf_add b " then " ;
      pp b t ;
      buf_add b " else " ;
      pp b f ;
      buf_add b ")"

(* Application is printed flattened: `f 1 2` is one pair of parentheses, not
   two, even though the tree is Apply (Apply (f, 1), 2). *)
and pp_apply b = function
  | Apply (f, a) ->
      pp_apply b f ;
      buf_add b " " ;
      pp b a
  | e -> pp b e

and pp_string b parts =
  match parts with
  | [] -> buf_add b "\"\""
  | [Lit s] -> buf_add b ("\"" ^ escape s ^ "\"")
  | parts ->
      (* An interpolated string is a `+` chain of its pieces. *)
      buf_add b "(" ;
      List.iteri
        (fun i p ->
          if i > 0 then buf_add b " + " ;
          match p with
          | Lit s -> buf_add b ("\"" ^ escape s ^ "\"")
          (* No parentheses of our own: whatever the interpolated expression
             is supplies its own, so `${toString b}` prints as `(toString b)`
             and `${b}` prints as a bare `b`. *)
          | Anti e -> pp b e)
        parts ;
      buf_add b ")"

and pp_attr b = function
  | Aid x -> buf_add b x
  (* A dynamic attribute whose value is a CONSTANT string folds to a plain
     name, which is what Nix's parser does: both `a."c"` and `a.${"c"}` print
     as `(a).c`. Only a genuinely dynamic one keeps its braces. *)
  | Astr [Lit s] -> buf_add b s
  | Astr [Anti (Str [Lit s])] -> buf_add b s
  (* A genuinely dynamic attribute is printed QUOTED, with the interpolation
     inside the quotes: `a.${k}` prints as `(a)."${k}"`. *)
  | Astr [Anti e] ->
      buf_add b "\"${" ;
      pp b e ;
      buf_add b "}\""
  | Astr parts -> pp_string b parts

and pp_attrpath b path =
  List.iteri
    (fun i a ->
      if i > 0 then buf_add b "." ;
      pp_attr b a)
    path

(* Nix EXPANDS a dotted binding into nested attribute sets at parse time, and
   MERGES siblings that share a prefix:

     { a.b.c = 1; }          becomes  { a = { b = { c = 1; }; }; }
     { a.b = 1; a.c = 2; }   becomes  { a = { b = 1; c = 2; }; }

   so the printer has to do the same. Merging is by the printed key, which is
   why only static attributes merge; a genuinely dynamic one cannot be known
   to collide at parse time and is kept as its own entry. *)
and group_binds binds =
  let key_of a =
    let kb = Buffer.create 16 in
    pp_attr kb a ;
    Buffer.contents kb
  in
  let rec insert items path e =
    match path with
    | [] -> items
    | [a] -> items @ [Attr (key_of a, Value e)]
    | a :: rest ->
        let k = key_of a in
        let rec go = function
          | [] -> [Attr (k, Nested (insert [] rest e))]
          | Attr (k', Nested sub) :: tl when String.equal k k' ->
              Attr (k', Nested (insert sub rest e)) :: tl
          | hd :: tl -> hd :: go tl
        in
        go items
  in
  List.fold_left
    (fun items bind ->
      match bind with
      | Bind (path, e) -> insert items path e
      | Inherit (from, attrs) -> items @ [Inherit_item (from, attrs)])
    []
    binds

and pp_items b items = List.iter (pp_item b) items

and pp_item b = function
  | Attr (k, Value e) ->
      buf_add b (k ^ " = ") ;
      pp b e ;
      buf_add b "; "
  | Attr (k, Nested sub) ->
      buf_add b (k ^ " = { ") ;
      pp_items b sub ;
      buf_add b "}; "
  | Inherit_item (from, attrs) -> pp_inherit b from attrs

and pp_bind b = function
  | Bind (path, e) ->
      pp_attrpath b path ;
      buf_add b " = " ;
      pp b e ;
      buf_add b "; "
  | Inherit (from, attrs) -> pp_inherit b from attrs

and pp_inherit b from attrs =
  buf_add b "inherit" ;
  Option.iter
    (fun e ->
      buf_add b " (" ;
      pp b e ;
      buf_add b ")")
    from ;
  List.iter
    (fun a ->
      buf_add b " " ;
      pp_attr b a)
    attrs ;
  buf_add b "; "

and pp_pattern b = function
  | Pvar x -> buf_add b x
  | Pset {formals; ellipsis; alias} ->
      buf_add b "{ " ;
      List.iteri
        (fun i (name, dflt) ->
          if i > 0 then buf_add b ", " ;
          buf_add b name ;
          Option.iter
            (fun d ->
              buf_add b " ? " ;
              pp b d)
            dflt)
        formals ;
      if ellipsis then buf_add b (if formals = [] then "..." else ", ...") ;
      buf_add b " }" ;
      Option.iter (fun a -> buf_add b (" @ " ^ a)) alias

(** The AST, printed the way [nix-instantiate --parse] prints it. *)
let to_string (e : t) : string =
  let b = Buffer.create 256 in
  pp b e ;
  Buffer.contents b
