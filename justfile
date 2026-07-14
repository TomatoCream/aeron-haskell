# Haskell + Nix project commands

# Cabal must run under the flake's GHC, never the system one: a system GHC with
# a newer base silently fails dependency resolution, and the error names some
# innocent package that caps `base` rather than the real cause. So re-enter the
# dev shell unless we are already inside one.
nixdev := if env_var_or_default("IN_NIX_SHELL", "") == "" { "nix develop --accept-flake-config --command" } else { "" }

# List available commands
default:
  @just --list

# Build the project
build:
  {{nixdev}} cabal build all

# Run the executable
run:
  {{nixdev}} cabal run my-project

# Run tests
test:
  {{nixdev}} cabal test all

# Format all files (Haskell + Nix + Cabal)
fmt:
  nix fmt

# Check formatting without modifying files
fmt-check:
  nix flake check

# Open a Haskell REPL
repl:
  {{nixdev}} cabal repl lib:my-project

# Clean build artifacts
clean:
  cabal clean
  rm -rf dist-newstyle .stack-work result result-*

# Update cabal dependencies
update:
  cabal update

# Build with Nix (produces a derivation)
build-nix:
  nix build

# Enter the Nix development shell
shell:
  nix develop --accept-flake-config

# Run hlint
lint:
  {{nixdev}} hlint src/ app/ test/

# Run hlint with automatic fixes
lint-fix:
  {{nixdev}} hlint --refactor --refactor-options="--inplace" src/ app/ test/

# Show project info
info:
  @{{nixdev}} bash -c 'echo "GHC:      $(ghc --version)"; \
    echo "Cabal:    $(cabal --version | head -1)"; \
    echo "HLS:      $(haskell-language-server --version 2>/dev/null || echo N/A)"; \
    echo "Fourmolu: $(fourmolu --version 2>/dev/null || echo N/A)"; \
    echo "HLint:    $(hlint --version 2>/dev/null || echo N/A)"'
