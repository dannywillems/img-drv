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

let str_or_lit parts =
  (* An attribute path element written as a string is an Astr; the printer
     folds it back to a plain name when it is constant, which is what Nix
     does. *)
  Astr parts
%}

%token <int> INT
%token <float> FLOAT
%token <string> ID STR PATH SPATH URI
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
  | p = PATH { Path p }
  | p = SPATH { Search_path p }
  | u = URI { Uri u }
  | DQUOTE parts = string_parts DQUOTE { Str parts }
  | IND_OPEN parts = string_parts IND_CLOSE { Ind_str parts }
  | LPAREN e = expr RPAREN { e }
  | REC LCURLY b = binds RCURLY { Attr_set {recursive = true; binds = b} }
  | LCURLY b = binds1 RCURLY { Attr_set {recursive = false; binds = b} }
  | empty_braces { Attr_set {recursive = false; binds = []} }
  | LBRACK items = list_items RBRACK { List items }

string_parts:
  | { [] }
  | s = STR rest = string_parts { Lit s :: rest }
  | DOLLAR_CURLY e = expr RCURLY rest = string_parts { Anti e :: rest }

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
  | DQUOTE parts = string_parts DQUOTE { str_or_lit parts }
  | DOLLAR_CURLY e = expr RCURLY { Astr [Anti e] }

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
