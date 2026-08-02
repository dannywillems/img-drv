(* The Nix grammar, for menhir.

   Transcribed from NixOS/nix src/libexpr/parser.y at commit a86a3638. The
   precedence block below is the same twelve levels in the same order as
   parser.y:208-219, which is the part most worth copying exactly: two of the
   levels surprise everyone, and getting either wrong changes what real files
   mean rather than failing to parse them.

     - `!` sits BELOW `+`, so `!a + b` is `!(a + b)`;
     - `//` sits ABOVE the comparisons, so `a // b == c` is `(a // b) == c`.

   Both are checked against nix-instantiate --parse in the test suite. *)

%{
open Ast

let with_alias p x =
  match p with
  | Pset f -> Pset {f with alias = Some x}
  | p -> p

(* Drop empty literals, which would otherwise print as `"" + ...`.

   Note what this does NOT do: merge adjacent literals. Nix does not merge them
   either. Its lexer matches a MAXIMAL run so the pieces arrive already joined,
   and the pieces it keeps separate (a two-quote escape, a trailing `$`) stay
   separate in the printed tree. Our lexer now draws the same boundaries, so
   merging here would over-join. *)
let drop_empty (parts : part list) : part list =
  match List.filter (function Lit "" -> false | _ -> true) parts with
  | [] -> [Lit ""]
  | ps -> ps

(* Nix STRIPS the common indentation from an indented string at PARSE time, so
   the AST holds the dedented text and `--parse` prints one plain string.
   Transcribed from `stripIndentation` in NixOS/nix src/libexpr/parser.y.

   Two passes. The first finds the minimum indentation over all lines that
   actually have content: a line that is entirely spaces does not count, and an
   interpolation counts as content. The second removes that many leading spaces
   from each line, and then drops a final line that is nothing but spaces. *)
let strip_indentation (parts : (part * bool) list) : part list =
  let min_indent = ref max_int and at_start = ref true and cur = ref 0 in
  let saw c =
    if !at_start then
      if c = ' ' then incr cur
      else if c = '\n' then cur := 0
      else begin
        at_start := false ;
        if !cur < !min_indent then min_indent := !cur
      end
    else if c = '\n' then begin
      at_start := true ;
      cur := 0
    end
  in
  (* A chunk that does not carry indentation is not scanned at all; it only
     ends the current start-of-line whitespace, like an antiquotation. *)
  let ends_line () =
    if !at_start then begin
      at_start := false ;
      if !cur < !min_indent then min_indent := !cur
    end
  in
  List.iter
    (function Lit s, true -> String.iter saw s | _ -> ends_line ())
    parts ;
  let min_indent = if !min_indent = max_int then 0 else !min_indent in
  let at_start = ref true and dropped = ref 0 in
  let n = List.length parts in
  let out =
    List.mapi
      (fun i (part, indented) ->
        match part with
        | _ when not indented ->
            at_start := false ;
            dropped := 0 ;
            part
        | Anti _ -> part
        | Lit s ->
            let b = Buffer.create (String.length s) in
            String.iter
              (fun c ->
                if !at_start then
                  if c = ' ' then begin
                    if !dropped >= min_indent then Buffer.add_char b c ;
                    incr dropped
                  end
                  else if c = '\n' then begin
                    dropped := 0 ;
                    Buffer.add_char b c
                  end
                  else begin
                    at_start := false ;
                    dropped := 0 ;
                    Buffer.add_char b c
                  end
                else begin
                  Buffer.add_char b c ;
                  if c = '\n' then begin
                    at_start := true ;
                    dropped := 0
                  end
                end)
              s ;
            let s2 = Buffer.contents b in
            (* The closing delimiter usually sits on its own indented line, and
               that trailing run of spaces is not part of the value. *)
            if i = n - 1 then
              match String.rindex_opt s2 '\n' with
              | Some p
                when String.for_all
                       (fun c -> c = ' ')
                       (String.sub s2 (p + 1) (String.length s2 - p - 1)) ->
                  Lit (String.sub s2 0 (p + 1))
              | _ -> Lit s2
            else Lit s2)
      parts
  in
  drop_empty out

let str_or_lit parts =
  (* An attribute path element written as a string is an Astr; the printer
     folds it back to a plain name when it is constant, which is what Nix
     does. *)
  Astr parts
%}

%token <int> INT
%token <float> FLOAT
%token <string> ID STR ESTR PATH SPATH URI PATH_START PATH_STR
%token PATH_END
%token IF THEN ELSE ASSERT WITH LET IN REC INHERIT OR_KW
%token DQUOTE IND_OPEN IND_CLOSE DOLLAR_CURLY
%token LCURLY RCURLY LPAREN RPAREN LBRACK RBRACK
%token SEMI COMMA COLON AT DOT ELLIPSIS ASSIGN
%token QUESTION EQ NEQ LEQ GEQ LT GT AND OR IMPL UPDATE CONCAT
%token PLUS MINUS TIMES SLASH NOT
%token EOF

(* parser.y:208-219, lowest binding first. *)
%right IMPL
%left OR
%left AND
%nonassoc EQ NEQ
%nonassoc LT GT LEQ GEQ
%right UPDATE
%left NOT
%left PLUS MINUS
%left TIMES SLASH
%right CONCAT
%nonassoc QUESTION
%nonassoc NEGATE

%start <Ast.t> main

%%

main: e = expr EOF { e }

expr: e = expr_function { e }

expr_function:
  | x = ID COLON body = expr_function { Lambda (Pvar x, body) }
  | p = formal_set COLON body = expr_function { Lambda (p, body) }
  | p = formal_set AT x = ID COLON body = expr_function
      { Lambda (with_alias p x, body) }
  | x = ID AT p = formal_set COLON body = expr_function
      { Lambda (with_alias p x, body) }
  (* `{}` is the ONE genuinely ambiguous prefix: it is an empty attribute set
     in expression position and an empty formal set before a `:`. Factoring it
     into its own nonterminal defers the decision to the token AFTER the brace,
     which is what makes the grammar LR(1). Nix's own parser.y has the same
     shape and declares %expect 0.

     Every other brace is decidable at the first token inside it: `{ a = ...`
     and `{ inherit ...` are binds, `{ a,`, `{ a ?`, `{ a }` and `{ ...` are
     formals. *)
  | empty_braces COLON body = expr_function
      { Lambda (Pset {formals = []; ellipsis = false; alias = None}, body) }
  | empty_braces AT x = ID COLON body = expr_function
      { Lambda (Pset {formals = []; ellipsis = false; alias = Some x}, body) }
  | x = ID AT empty_braces COLON body = expr_function
      { Lambda (Pset {formals = []; ellipsis = false; alias = Some x}, body) }
  | ASSERT c = expr SEMI body = expr_function { Assert (c, body) }
  | WITH e = expr SEMI body = expr_function { With (e, body) }
  | LET b = binds IN body = expr_function { Let (b, body) }
  | e = expr_if { e }

expr_if:
  | IF c = expr THEN t = expr ELSE f = expr { If (c, t, f) }
  | e = expr_op { e }

expr_op:
  | NOT e = expr_op { Not e }
  | MINUS e = expr_op %prec NEGATE { Neg e }
  | a = expr_op EQ b = expr_op { Op (Eq, a, b) }
  | a = expr_op NEQ b = expr_op { Op (Neq, a, b) }
  | a = expr_op LT b = expr_op { Op (Lt, a, b) }
  | a = expr_op GT b = expr_op { Op (Gt, a, b) }
  | a = expr_op LEQ b = expr_op { Op (Le, a, b) }
  | a = expr_op GEQ b = expr_op { Op (Ge, a, b) }
  | a = expr_op AND b = expr_op { Op (And, a, b) }
  | a = expr_op OR b = expr_op { Op (Or, a, b) }
  | a = expr_op IMPL b = expr_op { Op (Impl, a, b) }
  | a = expr_op UPDATE b = expr_op { Op (Update, a, b) }
  | a = expr_op CONCAT b = expr_op { Op (Concat, a, b) }
  | a = expr_op PLUS b = expr_op { Op (Add, a, b) }
  | a = expr_op MINUS b = expr_op { Op (Sub, a, b) }
  | a = expr_op TIMES b = expr_op { Op (Mul, a, b) }
  | a = expr_op SLASH b = expr_op { Op (Div, a, b) }
  | e = expr_op QUESTION p = attrpath { Has_attr (e, p) }
  | e = expr_app { e }

expr_app:
  | f = expr_app a = expr_select { Apply (f, a) }
  | e = expr_select { e }

expr_select:
  | e = expr_simple DOT p = attrpath { Select (e, p, None) }
  | e = expr_simple DOT p = attrpath OR_KW d = expr_select
      { Select (e, p, Some d) }
  | e = expr_simple { e }

expr_simple:
  | x = ID { Var x }
  | n = INT { Int n }
  | f = FLOAT { Float f }
  | p = PATH { Path (resolve_path p) }
  (* The lexer hands over the prefix having ALREADY consumed the opening
     `${`, so the first interpolation is spelled out here rather than coming
     from `path_parts`. *)
  | p = PATH_START e = expr RCURLY rest = path_parts
      { Path_interp (Anti (Path (resolve_path_prefix p)) :: Anti e :: rest) }
  | p = SPATH { Search_path p }
  | u = URI { Uri u }
  | DQUOTE parts = string_parts DQUOTE { Str (drop_empty (List.map fst parts)) }
  (* After dedenting, an indented string with a single literal part IS a plain
     string: Nix does not wrap a one-element concatenation, so `''a''` prints
     as `"a"` and not as `("a")`. *)
  | IND_OPEN parts = string_parts IND_CLOSE
      { match strip_indentation parts with
        | [Lit s] -> Str [Lit s]
        | ps -> Ind_str ps }
  | LPAREN e = expr RPAREN { e }
  | REC LCURLY b = binds RCURLY { Attr_set {recursive = true; binds = b} }
  | LCURLY b = binds1 RCURLY { Attr_set {recursive = false; binds = b} }
  | empty_braces { Attr_set {recursive = false; binds = []} }
  | LBRACK items = list_items RBRACK { List items }

path_parts:
  | PATH_END { [] }
  | s = PATH_STR rest = path_parts { Lit s :: rest }
  | DOLLAR_CURLY e = expr RCURLY rest = path_parts { Anti e :: rest }

string_parts:
  | { [] }
  | s = STR rest = string_parts { (Lit s, true) :: rest }
  | s = ESTR rest = string_parts { (Lit s, false) :: rest }
  | DOLLAR_CURLY e = expr RCURLY rest = string_parts { (Anti e, false) :: rest }

list_items:
  | { [] }
  | e = expr_select rest = list_items { e :: rest }

empty_braces: LCURLY RCURLY { () }

binds:
  | { [] }
  | b = binds1 { b }

binds1:
  | p = attrpath ASSIGN e = expr SEMI rest = binds { Bind (p, e) :: rest }
  | INHERIT attrs = inherit_attrs SEMI rest = binds
      { Inherit (None, attrs) :: rest }
  | INHERIT LPAREN e = expr RPAREN attrs = inherit_attrs SEMI rest = binds
      { Inherit (Some e, attrs) :: rest }

inherit_attrs:
  | { [] }
  | a = attr rest = inherit_attrs { a :: rest }

attrpath:
  | a = attr { [a] }
  | a = attr DOT rest = attrpath { a :: rest }

attr:
  | x = ID { Aid x }
  | OR_KW { Aid "or" }
  | DQUOTE parts = string_parts DQUOTE { str_or_lit (drop_empty (List.map fst parts)) }
  | DOLLAR_CURLY e = expr RCURLY { Adyn e }

(* Non-empty only; the empty case is `empty_braces` above. This mirrors
   parser.y:570-583, where `formals` is likewise non-nullable and `'{' '}'` is
   spelled out separately. *)
formal_set:
  | LCURLY ELLIPSIS RCURLY
      { Pset {formals = []; ellipsis = true; alias = None} }
  | LCURLY f = formals RCURLY
      { Pset {formals = f; ellipsis = false; alias = None} }
  | LCURLY f = formals COMMA RCURLY
      { Pset {formals = f; ellipsis = false; alias = None} }
  | LCURLY f = formals COMMA ELLIPSIS RCURLY
      { Pset {formals = f; ellipsis = true; alias = None} }

(* LEFT recursive, as parser.y:578-583 is. The right-recursive form creates a
   shift/reduce conflict on `,`: after `{ a` with `,` ahead, the parser cannot
   tell a trailing comma from another formal until it sees what follows the
   comma. Left recursion moves that decision one token later, where it is
   decidable. *)
formals:
  | f = formal { [f] }
  | rest = formals COMMA f = formal { rest @ [f] }

formal:
  | x = ID { (x, None) }
  | x = ID QUESTION e = expr { (x, Some e) }
