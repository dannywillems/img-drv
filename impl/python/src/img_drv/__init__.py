"""img-drv: a content-addressed IR for reproducible build descriptions.

The Python reference implementation. Parse a derivation, transform it, compute
its store paths, serialize it back, and get bytes identical to what Nix emits.

    >>> from img_drv import parse, unparse
    >>> drv = parse(text)
    >>> unparse(drv) == text          # canonical text round-trips exactly
    True

Verifying a closure:

    >>> from img_drv import Corpus
    >>> corpus = Corpus.from_directory(pathlib.Path("closure"))
    >>> checked, mismatches = corpus.verify()

The public surface is everything named in ``__all__``. It is semver'd: a
change to the bytes any of these produce is a MAJOR change, because the bytes
are the artifact.
"""

from __future__ import annotations

from .aterm import ParseError, escape, parse, quote, unparse
from .corpus import Corpus, Mismatch, name_from_path
from .derivation import (
    Derivation,
    InputDrv,
    Output,
    OutputName,
    Sha256Hex,
    StorePath,
)
from .edsl import (
    Dep,
    Drv,
    FixedOutput,
    HashAlgo,
    HashMode,
    InvalidDerivationError,
    canonical,
    derivation,
    valid_name,
)
from .store import (
    BASE32_ALPHABET,
    STORE,
    base32,
    base32_decode,
    base32_length,
    compress,
    drv_path,
    fixed_output_input_hash,
    fixed_output_path,
    output_paths,
    output_store_name,
    sha256_hex,
    store_path,
)

__version__ = "0.1.0"

__all__ = [
    "BASE32_ALPHABET",
    "STORE",
    "Corpus",
    "Dep",
    "Derivation",
    "Drv",
    "FixedOutput",
    "HashAlgo",
    "HashMode",
    "InputDrv",
    "InvalidDerivationError",
    "Mismatch",
    "Output",
    "OutputName",
    "ParseError",
    "Sha256Hex",
    "StorePath",
    "__version__",
    "base32",
    "base32_decode",
    "base32_length",
    "canonical",
    "compress",
    "derivation",
    "drv_path",
    "escape",
    "fixed_output_input_hash",
    "fixed_output_path",
    "name_from_path",
    "output_paths",
    "output_store_name",
    "parse",
    "quote",
    "sha256_hex",
    "store_path",
    "unparse",
    "valid_name",
]
