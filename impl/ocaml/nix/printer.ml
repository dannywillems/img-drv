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

(** Nix prints a string literal with the same five escapes the lexer undoes,
    plus a sixth that only fires in context: a [$] is escaped ONLY when it
    begins an interpolation, so ["a$b"] prints unescaped and a literal [${]
    prints as [\${]. Escaping every dollar would still be valid Nix; it would
    not be what [--parse] emits, and being byte-identical to that is this
    printer's entire job. *)
let escape s =
  let b = Buffer.create (String.length s + 2) in
  let n = String.length s in
  String.iteri
    (fun i c ->
      match c with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | '$' when i + 1 < n && s.[i + 1] = '{' -> Buffer.add_string b "\\$"
      | c -> Buffer.add_char b c)
    s ;
  Buffer.contents b

(** A bind tree: dotted paths expanded and shared prefixes merged. *)
type entry = Value of Ast.t | Nested of item list

and item =
  (* The flag says whether the name is DYNAMIC. Nix keeps static and dynamic
     attributes in two different containers, a sorted map and a source-order
     vector, and prints the map first, so the distinction has to survive into
     the printer:

       { "${k}" = 1; a = 2; }  =>  { a = 2; "${(k)}" = 1; }  *)
  | Attr of string * bool * entry
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
  | Path_interp parts -> pp_string b parts
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

(* An attribute NAME is printed bare when it is a valid Nix identifier and
   QUOTED otherwise. Established against the pinned Nix rather than assumed:

     { "c" = 1; }      =>  { c = 1; }
     { "a-b" = 1; }    =>  { a-b = 1; }      -- `-` and `'` are identifier chars
     { "0.92" = 1; }   =>  { "0.92" = 1; }   -- cannot start with a digit
     { "a b" = 1; }    =>  { "a b" = 1; }

   The grammar is [a-zA-Z_][a-zA-Z0-9_'-]* (NixOS/nix src/libexpr/lexer.l).
   Getting this wrong was invisible until the nixpkgs corpus, because no
   hand-written vector used a version number as an attribute name, and
   `release = { "0.92" = ...; }` is ordinary in nixpkgs. *)
and is_identifier s =
  let ok_first c =
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'
  in
  let ok_rest c = ok_first c || (c >= '0' && c <= '9') || c = '\'' || c = '-' in
  String.length s > 0
  && ok_first s.[0]
  &&
  let rec go i = i >= String.length s || (ok_rest s.[i] && go (i + 1)) in
  go 1

(* A keyword is quoted even though it looks like an identifier, because a bare
   one would not parse back. `or` is the exception: Nix's grammar admits it as
   an attribute name, and Nix prints it bare. Checked one keyword at a time
   against the pinned Nix rather than reasoned about. *)
and is_keyword = function
  | "if" | "then" | "else" | "assert" | "with" | "let" | "in" | "rec"
  | "inherit" ->
      true
  | _ -> false

and pp_name b s =
  if is_identifier s && not (is_keyword s) then buf_add b s
  else pp_string b [Lit s]

and pp_attr b = function
  | Aid x -> pp_name b x
  (* A dynamic attribute whose value is a CONSTANT string folds to a plain
     name, which is what Nix's parser does: both `a."c"` and `a.${"c"}` print
     as `(a).c`. Only a genuinely dynamic one keeps its braces. *)
  | Astr [Lit s] -> pp_name b s
  (* `a.${"c"}`: a dynamic attribute whose expression is a CONSTANT string
     folds to a plain name, exactly as `a."c"` does. *)
  | Adyn (Str [Lit s]) -> pp_name b s
  (* `a.${k}`: the expression is the attribute name directly, so it is printed
     directly, and a bare variable stays bare. *)
  | Adyn e ->
      buf_add b "\"${" ;
      pp b e ;
      buf_add b "}\""
  (* A genuinely dynamic attribute becomes ONE interpolation wrapping the
     whole string expression, and the expression is parenthesised by the
     ordinary rules. Checked against the pinned Nix:

       { "${m}" = 1; }      =>  { "${(m)}" = 1; }
       { "${m.x}" = 1; }    =>  { "${((m).x)}" = 1; }
       { "a${m}b" = 1; }    =>  { "${("a" + m + "b")}" = 1; }

     so the literal pieces move INSIDE the interpolation as a concatenation,
     rather than staying outside it as they do in an ordinary string. *)
  | Astr parts ->
      buf_add b "\"${" ;
      pp b (Str parts) ;
      buf_add b "}\""

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
and group_binds binds = add_binds [] binds

and add_binds items binds =
  List.fold_left
    (fun items bind ->
      match bind with
      | Bind (path, e) -> insert_bind items path e
      | Inherit (from, attrs) -> items @ [Inherit_item (from, attrs)])
    items
    binds

(* The key is the RAW name, not the printed one, because Nix merges and sorts
   by SYMBOL. Sorting by the printed form puts every quoted name before every
   bare one, since a quote sorts below a letter, so
   `{ "vmware/bootstrap" = ...; vmware-installer = ...; }` came out in the
   wrong order until the nixpkgs corpus said so. Quoting is applied at print
   time instead. *)
and key_of a =
  match a with
  | Aid x -> x
  | Astr [Lit s] -> s
  | Adyn (Str [Lit s]) -> s
  | a ->
      let kb = Buffer.create 16 in
      pp_attr kb a ;
      Buffer.contents kb

(* A name is STATIC when it is known at parse time: an identifier, or a string
   or interpolation with no antiquotation left in it. *)
and dynamic = function
  | Aid _ -> false
  | Astr parts -> List.exists (function Anti _ -> true | Lit _ -> false) parts
  | Adyn (Str [Lit _]) -> false
  | Adyn _ -> true

and set_binds = function
  | Attr_set {recursive = false; binds} -> Some binds
  | _ -> None

and insert_bind items path e =
  match path with
  | [] -> items
  | [a] ->
      (* A leaf whose value is an attribute set MERGES into an entry the dotted
         bindings already opened, which is the mirror of the deeper case below.
         Nix joins them in either order:
           { a.b = 1; a = { c = 2; }; }  =>  { a = { b = 1; c = 2; }; }
           { a = { c = 2; }; a.b = 1; }  =>  the same
         and having only one direction leaves two entries with the same name,
         which prints as two attribute sets side by side. *)
      let k = key_of a and dyn = dynamic a in
      let rec go = function
        | [] -> [Attr (k, dyn, Value e)]
        | Attr (k', d, Nested sub) :: tl when String.equal k k' -> (
            match set_binds e with
            | Some binds -> Attr (k', d, Nested (add_binds sub binds)) :: tl
            | None -> Attr (k', d, Nested sub) :: tl)
        (* TWO attribute-set bindings with the same name also merge. Nix
           REJECTS a duplicate scalar (`{ a = 1; a = 2; }` is an error) and
           quietly joins duplicate SETS, which real modules rely on:
           wg-quick.nix writes `serviceConfig = { ... }` twice, thirteen lines
           apart, and means one set. *)
        | Attr (k', d, Value v) :: tl when String.equal k k' -> (
            match (set_binds v, set_binds e) with
            | Some vb, Some eb ->
                Attr (k', d, Nested (add_binds (group_binds vb) eb)) :: tl
            | _ -> Attr (k', d, Value v) :: tl)
        | hd :: tl -> hd :: go tl
      in
      go items
  | a :: rest ->
      let k = key_of a and dyn = dynamic a in
      let rec go = function
        | [] -> [Attr (k, dyn, Nested (insert_bind [] rest e))]
        | Attr (k', d, Nested sub) :: tl when String.equal k k' ->
            Attr (k', d, Nested (insert_bind sub rest e)) :: tl
        (* The other direction: a leaf already holding a set has to be REOPENED
           rather than shadowed, so a later dotted binding lands inside it. *)
        | Attr (k', d, Value v) :: tl when String.equal k k' -> (
            match set_binds v with
            | Some binds ->
                Attr (k', d, Nested (insert_bind (group_binds binds) rest e))
                :: tl
            | None -> Attr (k', d, Value v) :: tl)
        | hd :: tl -> hd :: go tl
      in
      go items

(* Nix stores an attribute set as a SORTED map keyed by symbol, so
   `--parse` prints the bindings in name order rather than source order, and
   the same holds for a `let`. The ordering was established against the pinned
   Nix, because it is not what a reader would guess:

     { b = 1; a = 2; }                    =>  { a = 2; b = 1; }
     { inherit b; inherit a; c = 3; }     =>  { inherit a b; c = 3; }
     { inherit (z) b; inherit (z) a; }    =>  unchanged

   so: every PLAIN inherit merges into one statement with its names sorted and
   is emitted FIRST; each `inherit (e)` group keeps its own identity, its own
   name order, and its source position among the other from-groups; and the
   ordinary bindings follow, sorted.

   This is the single largest correction the nixpkgs corpus forced. Source
   order is what a hand-written vector preserves by accident, so all 59 of them
   passed while essentially every real file failed. *)
and order_items items =
  let plain_inherits =
    List.concat_map
      (function Inherit_item (None, attrs) -> attrs | _ -> [])
      items
  in
  let key_of a =
    let kb = Buffer.create 16 in
    pp_attr kb a ;
    Buffer.contents kb
  in
  let merged =
    match plain_inherits with
    | [] -> []
    | attrs ->
        [
          Inherit_item
            (None, List.sort (fun x y -> compare (key_of x) (key_of y)) attrs);
        ]
  in
  (* Each `inherit (e)` group keeps its own identity and its source position
     among the other from-groups, but its NAMES are sorted:

       { inherit (z) b; inherit (z) a; }  =>  unchanged
       { inherit (z) c a b; }             =>  { inherit (z) a b c; }  *)
  let from_inherits =
    List.filter_map
      (function
        | Inherit_item (Some e, attrs) ->
            Some
              (Inherit_item
                 ( Some e,
                   List.sort (fun x y -> compare (key_of x) (key_of y)) attrs ))
        | _ -> None)
      items
  in
  let attrs =
    List.filter (function Attr (_, false, _) -> true | _ -> false) items
    |> List.stable_sort (fun x y ->
        match (x, y) with
        | Attr (a, _, _), Attr (b, _, _) -> compare a b
        | _ -> 0)
  in
  (* Dynamic names keep SOURCE order and come last; they are a separate
     container in Nix and are not part of the sorted map. *)
  let dynamics =
    List.filter (function Attr (_, true, _) -> true | _ -> false) items
  in
  merged @ from_inherits @ attrs @ dynamics

and pp_items b items = List.iter (pp_item b) (order_items items)

and pp_item b = function
  (* The key held here is the RAW name, so quoting happens now: a dynamic key
     is already printed syntax and goes out verbatim, a static one is bare when
     it is an identifier and quoted otherwise. *)
  | Attr (k, dyn, Value e) ->
      if dyn then buf_add b k else pp_name b k ;
      buf_add b " = " ;
      pp b e ;
      buf_add b "; "
  | Attr (k, dyn, Nested sub) ->
      if dyn then buf_add b k else pp_name b k ;
      buf_add b " = { " ;
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
      (* Formals are a sorted map too: `({ b, a ? 1, ... }: a)` prints as
         `({ a ? 1, b, ... }: a)`. Same reason, same discovery. *)
      let formals =
        List.stable_sort (fun (a, _) (c, _) -> compare a c) formals
      in
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
