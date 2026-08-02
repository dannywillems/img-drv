%{
// The Nix grammar, for goyacc.
//
// Transcribed from NixOS/nix src/libexpr/parser.y at commit a86a3638. goyacc IS
// yacc, so this is the closest of the four to Nix's own file: the precedence
// block below is the same twelve levels, in the same order and the same syntax,
// as parser.y:208-219.
//
// Two of them surprise everyone, and getting either wrong changes what real
// files MEAN rather than failing to parse them:
//
//   - `!` sits BELOW `+`, so `!a + b` is `!(a + b)`;
//   - `//` sits ABOVE the comparisons, so `a // b == c` is `(a // b) == c`.
//
// Both are checked against nix-instantiate --parse.
//
// The generated parser is COMMITTED, because Go has no build step to run a
// generator in. That makes grammar.go the only generated table in this
// repository that a reviewer can read, and the only one that can go stale; the
// Makefile's generate-parser target and a CI check keep it honest.

package nix

%}

%union {
	num     int64
	fnum    float64
	str     string
	expr    Expr
	exprs   []Expr
	part    Part
	iparts  []indexedPart
	attr    Attr
	attrs   []Attr
	path    AttrPath
	binds   []Binding
	pattern Pattern
	formal  Formal
	formals []Formal
	parts   []Part
}

%token <num> INT
%token <fnum> FLOAT
// IDENT and URI_LIT rather than ID and URI: goyacc puts token constants in
// the package namespace, where those two would collide with the AST types of
// the same name. The generators in the other three languages keep their tokens
// in a separate type and never have to think about it.
%token <str> IDENT STR ESTR PATH SPATH URI_LIT PATH_START PATH_STR
%token PATH_END
%token IF THEN ELSE ASSERT WITH LET IN REC INHERIT OR_KW
%token DQUOTE IND_OPEN IND_CLOSE DOLLAR_CURLY
%token LCURLY RCURLY LPAREN RPAREN LBRACK RBRACK
%token SEMI COMMA COLON AT DOT ELLIPSIS ASSIGN
%token QUESTION EQ NEQ LEQ GEQ LT GT AND OR IMPL UPDATE CONCAT
%token PLUS MINUS TIMES SLASH NOT

%type <expr> expr expr_function expr_if expr_op expr_app expr_select expr_simple start
%type <exprs> list_items
%type <iparts> string_parts
%type <parts> path_parts
%type <attr> attr
%type <attrs> inherit_attrs
%type <path> attrpath
%type <binds> binds binds1
%type <pattern> formal_set
%type <formal> formal
%type <formals> formals

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

%start start

%%

start:
	expr { $$ = $1; nixlex.(*Lexer).result = $1 }

expr:
	expr_function { $$ = $1 }

expr_function:
	IDENT COLON expr_function { $$ = Lambda{Pattern: PVar{Name: $1}, Body: $3} }
|	formal_set COLON expr_function { $$ = Lambda{Pattern: $1, Body: $3} }
|	formal_set AT IDENT COLON expr_function { $$ = Lambda{Pattern: withAlias($1, $3), Body: $5} }
|	IDENT AT formal_set COLON expr_function { $$ = Lambda{Pattern: withAlias($3, $1), Body: $5} }
	/* `{}` is the ONE genuinely ambiguous prefix: an empty attribute set in
	   expression position and an empty formal set before a `:`. Factoring it
	   into its own nonterminal defers the decision to the token AFTER the
	   brace, which is what makes the grammar LR(1). Nix's parser.y does the
	   same and declares %expect 0. */
|	empty_braces COLON expr_function { $$ = Lambda{Pattern: PSet{}, Body: $3} }
|	empty_braces AT IDENT COLON expr_function { $$ = Lambda{Pattern: PSet{Alias: $3}, Body: $5} }
|	IDENT AT empty_braces COLON expr_function { $$ = Lambda{Pattern: PSet{Alias: $1}, Body: $5} }
|	ASSERT expr SEMI expr_function { $$ = Assert{Condition: $2, Body: $4} }
|	WITH expr SEMI expr_function { $$ = With{Scope: $2, Body: $4} }
|	LET binds IN expr_function { $$ = Let{Binds: $2, Body: $4} }
|	expr_if { $$ = $1 }

expr_if:
	IF expr THEN expr ELSE expr { $$ = If{Condition: $2, Then: $4, Else: $6} }
|	expr_op { $$ = $1 }

expr_op:
	NOT expr_op { $$ = Not{Expr: $2} }
|	MINUS expr_op %prec NEGATE { $$ = Neg{Expr: $2} }
|	expr_op EQ expr_op { $$ = BinOp{Op: OpEq, Left: $1, Right: $3} }
|	expr_op NEQ expr_op { $$ = BinOp{Op: OpNeq, Left: $1, Right: $3} }
|	expr_op LT expr_op { $$ = BinOp{Op: OpLt, Left: $1, Right: $3} }
|	expr_op GT expr_op { $$ = BinOp{Op: OpGt, Left: $1, Right: $3} }
|	expr_op LEQ expr_op { $$ = BinOp{Op: OpLe, Left: $1, Right: $3} }
|	expr_op GEQ expr_op { $$ = BinOp{Op: OpGe, Left: $1, Right: $3} }
|	expr_op AND expr_op { $$ = BinOp{Op: OpAnd, Left: $1, Right: $3} }
|	expr_op OR expr_op { $$ = BinOp{Op: OpOr, Left: $1, Right: $3} }
|	expr_op IMPL expr_op { $$ = BinOp{Op: OpImpl, Left: $1, Right: $3} }
|	expr_op UPDATE expr_op { $$ = BinOp{Op: OpUpdate, Left: $1, Right: $3} }
|	expr_op CONCAT expr_op { $$ = BinOp{Op: OpConcat, Left: $1, Right: $3} }
|	expr_op PLUS expr_op { $$ = BinOp{Op: OpAdd, Left: $1, Right: $3} }
|	expr_op MINUS expr_op { $$ = BinOp{Op: OpSub, Left: $1, Right: $3} }
|	expr_op TIMES expr_op { $$ = BinOp{Op: OpMul, Left: $1, Right: $3} }
|	expr_op SLASH expr_op { $$ = BinOp{Op: OpDiv, Left: $1, Right: $3} }
|	expr_op QUESTION attrpath { $$ = HasAttr{Expr: $1, Path: $3} }
|	expr_app { $$ = $1 }

expr_app:
	expr_app expr_select { $$ = Apply{Func: $1, Arg: $2} }
|	expr_select { $$ = $1 }

expr_select:
	expr_simple DOT attrpath { $$ = Select{Expr: $1, Path: $3} }
|	expr_simple DOT attrpath OR_KW expr_select { $$ = Select{Expr: $1, Path: $3, Default: $5} }
|	expr_simple { $$ = $1 }

expr_simple:
	IDENT { $$ = Var{Name: $1} }
|	INT { $$ = Int{Value: $1} }
|	FLOAT { $$ = Float{Value: $1} }
|	PATH { $$ = PathLit{Text: ResolvePath($1)} }
	/* The lexer hands over the prefix having ALREADY consumed the opening
	   `${`, so the first interpolation is spelled out here. */
|	PATH_START expr RCURLY path_parts {
		parts := []Part{Anti{Expr: PathLit{Text: ResolvePathPrefix($1)}}, Anti{Expr: $2}}
		$$ = PathInterp{Parts: append(parts, $4...)}
	}
|	SPATH { $$ = SearchPath{Text: $1} }
|	URI_LIT { $$ = URI{Text: $1} }
|	DQUOTE string_parts DQUOTE { $$ = Str{Parts: dropEmpty(plainParts($2))} }
	/* After dedenting, an indented string with a single literal part IS a
	   plain string: Nix does not wrap a one-element concatenation. */
|	IND_OPEN string_parts IND_CLOSE {
		stripped := StripIndentation($2)
		if len(stripped) == 1 {
			if _, ok := stripped[0].(Lit); ok {
				$$ = Str{Parts: stripped}
			} else {
				$$ = IndStr{Parts: stripped}
			}
		} else {
			$$ = IndStr{Parts: stripped}
		}
	}
|	LPAREN expr RPAREN { $$ = $2 }
|	REC LCURLY binds RCURLY { $$ = AttrSet{Recursive: true, Binds: $3} }
|	LCURLY binds1 RCURLY { $$ = AttrSet{Binds: $2} }
|	empty_braces { $$ = AttrSet{} }
|	LBRACK list_items RBRACK { $$ = List{Items: $2} }

path_parts:
	PATH_END { $$ = nil }
|	PATH_STR path_parts { $$ = append([]Part{Lit{Text: $1}}, $2...) }
|	DOLLAR_CURLY expr RCURLY path_parts { $$ = append([]Part{Anti{Expr: $2}}, $4...) }

string_parts:
	{ $$ = nil }
|	STR string_parts { $$ = append([]indexedPart{{Part: Lit{Text: $1}, Indented: true}}, $2...) }
|	ESTR string_parts { $$ = append([]indexedPart{{Part: Lit{Text: $1}}}, $2...) }
|	DOLLAR_CURLY expr RCURLY string_parts { $$ = append([]indexedPart{{Part: Anti{Expr: $2}}}, $4...) }

list_items:
	{ $$ = nil }
|	expr_select list_items { $$ = append([]Expr{$1}, $2...) }

empty_braces:
	LCURLY RCURLY { }

binds:
	{ $$ = nil }
|	binds1 { $$ = $1 }

binds1:
	attrpath ASSIGN expr SEMI binds { $$ = append([]Binding{Bind{Path: $1, Value: $3}}, $5...) }
|	INHERIT inherit_attrs SEMI binds { $$ = append([]Binding{Inherit{Attrs: $2}}, $4...) }
|	INHERIT LPAREN expr RPAREN inherit_attrs SEMI binds {
		$$ = append([]Binding{Inherit{Source: $3, Attrs: $5}}, $7...)
	}

inherit_attrs:
	{ $$ = nil }
|	attr inherit_attrs { $$ = append([]Attr{$1}, $2...) }

attrpath:
	attr { $$ = AttrPath{$1} }
|	attr DOT attrpath { $$ = append(AttrPath{$1}, $3...) }

attr:
	IDENT { $$ = ID{Name: $1} }
|	OR_KW { $$ = ID{Name: "or"} }
|	DQUOTE string_parts DQUOTE { $$ = StrAttr{Parts: dropEmpty(plainParts($2))} }
|	DOLLAR_CURLY expr RCURLY { $$ = DynAttr{Expr: $2} }

/* Non-empty only; the empty case is empty_braces above. This mirrors
   parser.y:570-583, where `formals` is likewise non-nullable. */
formal_set:
	LCURLY ELLIPSIS RCURLY { $$ = PSet{Ellipsis: true} }
|	LCURLY formals RCURLY { $$ = PSet{Formals: $2} }
|	LCURLY formals COMMA RCURLY { $$ = PSet{Formals: $2} }
|	LCURLY formals COMMA ELLIPSIS RCURLY { $$ = PSet{Formals: $2, Ellipsis: true} }

/* LEFT recursive, as parser.y:578-583 is. The right-recursive form makes a
   trailing comma indistinguishable from another formal one token too early. */
formals:
	formal { $$ = []Formal{$1} }
|	formals COMMA formal { $$ = append($1, $3) }

formal:
	IDENT { $$ = Formal{Name: $1} }
|	IDENT QUESTION expr { $$ = Formal{Name: $1, Default: $3} }

%%
