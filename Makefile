# img-drv.
#
# Every target runs in a PINNED container (see scripts/pins.env), so nothing
# needs to be installed on the host and a laptop runs exactly what CI runs.
# Targets are declared ahead of the code on purpose: the conformance target is
# the point of the project, and naming it now keeps the phases honest.

.DEFAULT_GOAL := help

.PHONY: help
help: ## Ask for help!
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; \
		{printf "\033[36m%-24s\033[0m %s\n", $$1, $$2}'

.PHONY: conformance
conformance: ## Assert every eDSL emits byte-identical IR (the whole point)
	./scripts/conformance.sh

.PHONY: transpile-check
transpile-check: ## Our .nix, through real Nix, must give the golden .drv
	./scripts/transpile-check.sh

.PHONY: differential
differential: ## Recompute a real Nix closure's store paths and compare
	./scripts/differential.sh

.PHONY: build
build: python-build rust-build go-build ocaml-build ## Build every implementation

.PHONY: test
test: python-test rust-test go-test ocaml-test ## Run every test suite

.PHONY: lint
lint: python-lint rust-lint go-lint ocaml-lint lint-shell ## Run every linter

.PHONY: python-test
python-test: ## Test the Python implementation
	./scripts/py-check.sh test

.PHONY: python-lint
python-lint: ## Lint and type-check the Python implementation
	./scripts/py-check.sh lint

.PHONY: python-build
python-build: ## Build the Python wheel and sdist
	./scripts/py-build.sh

.PHONY: rust-test
rust-test: ## Test the Rust implementation
	./scripts/rs-check.sh test

.PHONY: rust-lint
rust-lint: ## Lint and check formatting of the Rust implementation
	./scripts/rs-check.sh lint

.PHONY: rust-build
rust-build: ## Build the Rust crate in release mode
	./scripts/rs-check.sh build

.PHONY: go-test
go-test: ## Test the Go implementation
	./scripts/go-check.sh test

.PHONY: go-lint
go-lint: ## gofmt and go vet the Go implementation
	./scripts/go-check.sh lint

.PHONY: go-build
go-build: ## Build the Go implementation
	./scripts/go-check.sh build

.PHONY: ocaml-test
ocaml-test: ## Test the OCaml implementation
	./scripts/ml-check.sh test

.PHONY: ocaml-lint
ocaml-lint: ## Check OCaml formatting with ocamlformat
	./scripts/ml-check.sh lint

.PHONY: ocaml-build
ocaml-build: ## Build the OCaml implementation
	./scripts/ml-check.sh build

.PHONY: fmt
fmt: format ## Alias for format

.PHONY: format
format: ## Format code
	./scripts/py-check.sh format
	./scripts/rs-check.sh format
	./scripts/go-check.sh format
	./scripts/ml-check.sh format

.PHONY: clean
clean: ## Remove build artifacts
	rm -rf target _build build impl/python/dist impl/python/*.egg-info
	find . -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true

.PHONY: spec-check
spec-check: ## Recompute every golden store path from derivation text alone
	./scripts/py.sh verify docs/spec/examples

.PHONY: aterm-roundtrip
aterm-roundtrip: ## Parse then re-serialize every .drv; must be byte-identical
	./scripts/py.sh roundtrip $(DIR)

.PHONY: drvpath-check
drvpath-check: ## Recompute each .drv's own store path from its bytes
	./scripts/py.sh drvpaths $(DIR)

.PHONY: canonical-check
canonical-check: ## Canonicalizing a real derivation must change nothing
	./scripts/py.sh canonical $(DIR)

.PHONY: corpus
corpus: ## Pull N random nixpkgs packages and verify against them (needs docker)
	./scripts/fetch-corpus.sh $(N)

.PHONY: lib-check
lib-check: ## Real nixpkgs lib, through our evaluator, vs nix-instantiate
	./scripts/lib-check.sh $(IMPLS)

.PHONY: eval-check
eval-check: ## Evaluate real .nix source; the .drv must match nix-instantiate
	./scripts/eval-check.sh $(IMPLS)

.PHONY: nar-check
nar-check: ## Source store paths, via our own NAR, vs nix-store --add
	./scripts/nar-check.sh $(IMPLS)

.PHONY: worked-example
worked-example: ## A real package through the surface, vs hand-written Nix
	./scripts/worked-example.sh $(IMPLS)

.PHONY: generate-parser
generate-parser: ## Regenerate the Go parser from grammar.y (goyacc)
	./scripts/go-generate-parser.sh

.PHONY: check-parser
check-parser: ## Fail if the committed Go parser is stale
	./scripts/go-generate-parser.sh --check

.PHONY: nixpkgs-parse
nixpkgs-parse: ## Parse N random real nixpkgs files, diff the tree vs Nix
	./scripts/nixpkgs-parse.sh $(N) $(IMPLS)

.PHONY: lint-shell
lint-shell: ## Lint shell scripts
	docker run --rm -v "$$PWD:/w" -w /w \
		koalaman/shellcheck-alpine:stable shellcheck -x scripts/*.sh
