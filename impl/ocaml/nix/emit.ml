(** Print an AST as valid Nix SOURCE.

    Not to be confused with {!Printer}, which reproduces
    [nix-instantiate --parse]'s debug form for differential testing. This one
    emits `.nix` a human can read and Nix can evaluate, and it is the
    transpiler: the arrow [EXPR -> .nix] in [docs/architecture.md].

    {1 Fully parenthesised, on purpose}

    Every compound expression is wrapped. That is uglier than necessary and it
    is the right first move: extra parentheses cannot change the parse, so the
    emitted file is correct by construction rather than correct if the
    precedence table was transcribed properly. `docs/nix-internals.md` records
    two precedence levels that surprise everyone ([!] binds looser than [+],
    [//] tighter than the comparisons); a minimal-parenthesis printer has to
    get both right, and this one cannot get them wrong.

    Making the output pretty is a separate, later job with its own test: emit,
    re-parse, and compare the ASTs. *)

open Ast

let buf_add = Buffer.add_string

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
      (* `${` in a literal must be escaped or Nix reads an interpolation. *)
      | '$' -> Buffer.add_string b "\\$"
      | c -> Buffer.add_char b c)
    s ;
  Buffer.contents b

let op_text = function
  | Add -> "+"
  | Sub -> "-"
  | Mul -> "*"
  | Div -> "/"
  | Update -> "//"
  | Concat -> "++"
  | Eq -> "=="
  | Neq -> "!="
  | Lt -> "<"
  | Gt -> ">"
  | Le -> "<="
  | Ge -> ">="
  | And -> "&&"
  | Or -> "||"
  | Impl -> "->"

let rec pp b (e : t) =
  match e with
  | Int n -> buf_add b (string_of_int n)
  | Float f -> buf_add b (Printf.sprintf "%g" f)
  | Var x -> buf_add b x
  | Path p -> buf_add b p
  | Search_path p -> buf_add b ("<" ^ p ^ ">")
  | Uri u -> buf_add b ("\"" ^ escape u ^ "\"")
  | Path_interp parts ->
      (* The leading path is absolute after parsing, so this emits an absolute
         interpolated path, which is valid Nix and denotes the same file. *)
      List.iter
        (function
          | Lit s -> buf_add b s
          | Anti (Path p) -> buf_add b p
          | Anti e ->
              buf_add b "${" ;
              pp b e ;
              buf_add b "}")
        parts
  | Str parts -> pp_string b parts
  | Ind_str parts -> pp_string b parts
  | Not e ->
      buf_add b "(!" ;
      pp b e ;
      buf_add b ")"
  | Neg e ->
      buf_add b "(-" ;
      pp b e ;
      buf_add b ")"
  | Op (o, x, y) ->
      buf_add b "(" ;
      pp b x ;
      buf_add b (" " ^ op_text o ^ " ") ;
      pp b y ;
      buf_add b ")"
  | Has_attr (e, path) ->
      buf_add b "(" ;
      pp b e ;
      buf_add b " ? " ;
      pp_attrpath b path ;
      buf_add b ")"
  | Apply (f, a) ->
      buf_add b "(" ;
      pp b f ;
      buf_add b " " ;
      pp b a ;
      buf_add b ")"
  | Select (e, path, dflt) ->
      buf_add b "(" ;
      pp b e ;
      buf_add b "." ;
      pp_attrpath b path ;
      Option.iter
        (fun d ->
          buf_add b " or " ;
          pp b d)
        dflt ;
      buf_add b ")"
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
          pp b i ;
          buf_add b " ")
        items ;
      buf_add b "]"
  | Attr_set {recursive; binds} ->
      if recursive then buf_add b "rec " ;
      buf_add b "{ " ;
      List.iter (pp_bind b) binds ;
      buf_add b "}"
  | Let (binds, body) ->
      buf_add b "(let " ;
      List.iter (pp_bind b) binds ;
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
      buf_add b "(assert " ;
      pp b c ;
      buf_add b "; " ;
      pp b body ;
      buf_add b ")"
  | If (c, t, f) ->
      buf_add b "(if " ;
      pp b c ;
      buf_add b " then " ;
      pp b t ;
      buf_add b " else " ;
      pp b f ;
      buf_add b ")"

and pp_string b parts =
  buf_add b "\"" ;
  List.iter
    (fun p ->
      match p with
      | Lit s -> buf_add b (escape s)
      | Anti e ->
          buf_add b "${" ;
          pp b e ;
          buf_add b "}")
    parts ;
  buf_add b "\""

and pp_attr b = function
  | Aid x -> buf_add b x
  | Adyn e ->
      buf_add b "${" ;
      pp b e ;
      buf_add b "}"
  | Astr [Lit s] -> buf_add b ("\"" ^ escape s ^ "\"")
  | Astr parts ->
      buf_add b "${" ;
      pp_string b parts ;
      buf_add b "}"

and pp_attrpath b path =
  List.iteri
    (fun i a ->
      if i > 0 then buf_add b "." ;
      pp_attr b a)
    path

and pp_bind b = function
  | Bind (path, e) ->
      pp_attrpath b path ;
      buf_add b " = " ;
      pp b e ;
      buf_add b "; "
  | Inherit (from, attrs) ->
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

(** The AST as Nix source. *)
let to_string (e : t) : string =
  let b = Buffer.create 512 in
  pp b e ;
  Buffer.contents b
