(** Partial application of a primop.

    Nix applies functions one argument at a time, so a primop of arity 2 given
    one argument is itself a value. Kept in its own module to break the
    recursion between {!Eval} and {!Value}. *)

let partial name arity impl args =
  if List.length args >= arity then impl (List.rev args)
  else
    Value.Primop
      (name, arity - List.length args, fun more -> impl (List.rev args @ more))
