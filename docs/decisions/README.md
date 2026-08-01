# decisions

One file per decision that would otherwise be re-litigated, kept here rather
than in a personal notebook so that the reasoning travels with the code it
justifies. If the repo is the signature of the fleet, this is the part that
records WHY the signature looks like this.

Name them `YYYY-MM-DD-<topic>.md`. Do not renumber, do not rewrite history: a
decision that turns out wrong gets a new file that supersedes it, and a line
added to the old one pointing forward. What was believed at the time is the
useful part.

Each file answers, in this order:

1. **Motivation.** What we are trying to achieve.
2. **Problems.** What is actually wrong, specifically, with the alternative or
   the current state. Written honestly enough that someone who prefers the
   alternative would recognise their own argument in it.
3. **Decision and reasons.** What was chosen and why, with the reasons in the
   order they actually weighed rather than the order that sounds best.
4. **Costs accepted.** What this choice makes worse, stated plainly, with
   whatever mitigates each. A decision log with no costs section is marketing.
5. **Revisit if.** The conditions under which the answer should change.
   Without this a decision calcifies into an assumption nobody remembers
   making.

`docs/theory.md` is the other normative document: it says what the mathematics
forces. A decision that contradicts it is a bug in one of the two, and which
one should be argued explicitly.

## index

Nothing yet. The decisions that led to this repository existing live in
`iso-img/docs/decisions/`, specifically the two dated 2026-08-01 on not
adopting NixOS and on not building a standalone DSL.
