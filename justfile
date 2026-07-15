# Aeron Haskell bindings — project commands

# Cabal must run under the flake's GHC, never the system one: a system GHC with
# a newer base silently fails dependency resolution, and the error names some
# innocent package that caps `base` rather than the real cause. So re-enter the
# dev shell unless we are already inside one.
nixdev := if env_var_or_default("IN_NIX_SHELL", "") == "" { "nix develop --accept-flake-config --command" } else { "" }

# List available commands
default:
  @just --list

# Build everything (library, demo, tests, benchmark)
build:
  {{nixdev}} cabal build all

# Run a media driver in the foreground (leave it running; Ctrl-C to stop)
driver:
  @echo "Media driver — Aeron does nothing without this. Leave it running."
  {{nixdev}} aeronmd

# Run the demo. Requires a driver (`just driver`) in another terminal.
run:
  {{nixdev}} cabal run aeron-haskell

# Run the integration tests (self-driving — no `just driver` needed)
test:
  {{nixdev}} cabal test all

# Run the poll-path benchmark (spawns its own driver, like the tests).
bench:
  {{nixdev}} cabal run -v0 bench:aeron-haskell-bench

# Format all files (Haskell + Nix + Cabal)
fmt:
  nix fmt

# Check formatting and the flake without modifying files
fmt-check:
  nix flake check

# Open a REPL on the library
repl:
  {{nixdev}} cabal repl lib:aeron-haskell

# Clean build artifacts
clean:
  cabal clean
  rm -rf dist-newstyle .stack-work result result-*

# Build with Nix (hermetic; produces ./result)
build-nix:
  nix build

# Enter the Nix development shell
shell:
  nix develop --accept-flake-config

# Run hlint over all Haskell sources
lint:
  {{nixdev}} hlint src/ app/ test/ bench/

# Run hlint with automatic fixes
lint-fix:
  {{nixdev}} hlint --refactor --refactor-options="--inplace" src/ app/ test/ bench/

# Show the real linked Aeron path (its reported version string lies)
aeron-info:
  @{{nixdev}} bash -c 'echo "aeronmd: $(command -v aeronmd)"; \
    echo "libaeron: $(dirname $(dirname $(command -v aeronmd)))/lib/libaeron.so"'
