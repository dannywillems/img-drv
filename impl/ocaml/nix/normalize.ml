(** What {!Emit} forgets, named precisely.

    {!Emit} and {!Nix.parse_string} are the two arrows between EXPR and source
    text. Their law is a RETRACTION, [parse (emit e) = e], but it does not hold
    on the nose, and the two things it holds only up to are worth naming rather
    than hiding, because both say something about Nix.

    {1 Literal CHUNKING carries no meaning}

    Nix's lexer splits a string into chunks at boundaries that depend on the
    ESCAPES used, not on the value: an escaped dollar between two words gives
    three parts, and the same characters written plainly give one.
    [nix-instantiate --parse] shows that difference, printing
    [("a" + "$" + "b")] for the first and ["a$b"] for the second, and Nix
    EVALUATES both identically.

    So the debug form our differential oracle compares against is FINER than
    semantic equality. That is exactly what we want for testing a parser, since
    it pins more; it means a round-trip law has to be stated in the quotient,
    because {!Emit} writes the characters and cannot write the chunking.

    {1 An indented string stops existing at parse time}

    Nix has no indented-string node: [''a''] is an [ExprString] once the dedent
    has run, and the indentation is gone for good. {!Ast.Ind_str} is our
    invention, kept only for the multi-part case, and it holds nothing that
    could be used to write the original back. {!Emit} therefore prints one as
    an ordinary quoted string, and re-parsing gives {!Ast.Str}.

    {1 A URI literal is a string}

    Same story once more: [x:x] is a URI to the LEXER, which is why it is not a
    lambda, and [nix-instantiate --parse] prints it as ["x:x"]. Nix keeps no
    URI node either. {!Emit} writes one as a quoted string, which is both safe
    and preferable, since URI literals are deprecated.

    All three quotients are semantic no-ops, and each one names a node WE
    invented that Nix does not keep. Normalising by them is the honest
    statement of the law, not a way of making a failing test pass; the fact
    that all three are our own inventions is itself the finding. *)

open Ast

let rec merge_parts (parts : part list) : part list =
  match parts with
  | Lit a :: Lit b :: rest -> merge_parts (Lit (a ^ b) :: rest)
  | Anti e :: rest -> Anti (expr e) :: merge_parts rest
  | p :: rest -> p :: merge_parts rest
  | [] -> []

and attr (a : attr) : attr =
  match a with
  | Aid x -> Aid x
  | Astr parts -> Astr (merge_parts parts)
  | Adyn e -> Adyn (expr e)

and bind (b : bind) : bind =
  match b with
  | Bind (path, e) -> Bind (List.map attr path, expr e)
  | Inherit (from, attrs) -> Inherit (Option.map expr from, List.map attr attrs)

and pattern (p : pattern) : pattern =
  match p with
  | Pvar x -> Pvar x
  | Pset f ->
      Pset
        {
          f with
          formals = List.map (fun (n, d) -> (n, Option.map expr d)) f.formals;
        }

(** The normal form: adjacent literals joined, indented strings folded into
    ordinary ones. *)
and expr (e : t) : t =
  match e with
  | Str parts -> Str (merge_parts parts)
  (* Nix keeps no indented-string node past parsing, so neither does the
     normal form. *)
  | Ind_str parts -> Str (merge_parts parts)
  | Path_interp parts -> Path_interp (merge_parts parts)
  (* Nix keeps no URI node either: `x:x` parses to a string. *)
  | Uri u -> Str [Lit u]
  | Int _ | Float _ | Path _ | Search_path _ | Var _ -> e
  | Lambda (p, body) -> Lambda (pattern p, expr body)
  | Apply (f, a) -> Apply (expr f, expr a)
  | Select (e, path, d) -> Select (expr e, List.map attr path, Option.map expr d)
  | Has_attr (e, path) -> Has_attr (expr e, List.map attr path)
  | List items -> List (List.map expr items)
  | Attr_set {recursive; binds} ->
      Attr_set {recursive; binds = List.map bind binds}
  | Let (binds, body) -> Let (List.map bind binds, expr body)
  | With (e, body) -> With (expr e, expr body)
  | Assert (c, body) -> Assert (expr c, expr body)
  | If (c, t, f) -> If (expr c, expr t, expr f)
  | Op (o, a, b) -> Op (o, expr a, expr b)
  | Not e -> Not (expr e)
  | Neg e -> Neg (expr e)
