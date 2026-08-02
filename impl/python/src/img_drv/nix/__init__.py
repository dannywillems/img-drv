"""The Nix EXPRESSION layer: write Nix in Python, print ``.nix``.

This is the second of the two term algebras in ``docs/architecture.md``. The
parent package ``img_drv`` is the FIRST-ORDER one (derivations, ATerm, store
paths); this subpackage is the SECOND-ORDER one, because Nix expressions have
binders and derivations do not.

It depends on the parent and the parent never depends on it, which is the rule
that keeps a bug in the expression layer from being able to change a store path.

Nothing here needs a parser. The transpiler is only the arrow ``EXPR -> .nix``,
so it is :mod:`ast`, :mod:`emit` and :mod:`surface` alone; the parser and its
generator arrive with the arrow the other way and are not imported by this
package.
"""

from __future__ import annotations

from . import ast, emit, surface

__all__ = ["ast", "emit", "surface"]
