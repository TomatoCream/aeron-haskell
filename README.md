# Haskell + Nix Template

A modern Haskell project template using **haskell.nix**, **treefmt-nix**, **flake-parts**, and binary caches.

## What's Included

- **haskell.nix** — IOHK's Haskell package management for Nix
- **treefmt-nix** — Fourmolu, cabal-fmt, hlint, nixfmt via `nix fmt`
- **flake-parts** — Modular flake structure
- **Binary cache** — IOG (pre-built GHC and dependencies)
- **GHC 9.12** — Latest stable with full HLS support
- **Dev tools** — HLS, cabal, hlint, fourmolu, cabal-fmt
- **direnv** — Automatic shell activation via `.envrc`
- **just** — Project command runner

## Quick Start

```bash
mkdir my-project && cd my-project
nix flake init -t ~/projects/nix-templates#haskell-four

# Rename the project (edit my-project.cabal, flake.nix, justfile)

# Enter the development shell
nix develop --accept-flake-config
# Or with direnv: direnv allow

# Every just recipe enters the dev shell for you if you are not in one
just build
just run
just test
just fmt
just lint
```

## Project Structure

```
.
├── flake.nix          # Nix flake with haskell.nix + treefmt-nix + IOG cache
├── my-project.cabal   # Cabal project file (GHC2021, common extensions)
├── justfile           # Project commands (build, test, fmt, lint)
├── fourmolu.yaml      # Formatter config — must stay in the repo root
├── .envrc             # direnv integration
├── .hlint.yaml        # HLint configuration
├── src/
│   └── MyLib.hs       # Library source
├── app/
│   └── Main.hs        # Executable entry point
└── test/
    └── Main.hs        # Test suite
```

## Dev Shell Tools

When you enter `nix develop`, you get:

| Tool | Purpose |
|------|---------|
| `ghc` | Glasgow Haskell Compiler 9.12 |
| `cabal` | Build tool and package manager |
| `haskell-language-server` | LSP server for editors |
| `fourmolu` | Haskell formatter |
| `hlint` | Haskell linter |
| `cabal-fmt` | .cabal file formatter |
| `just` | Command runner |

## Editor Integration

### VS Code

1. Install the [Haskell](https://marketplace.visualstudio.com/items?itemName=haskell.haskell) extension
1. Install [direnv](https://marketplace.visualstudio.com/items?itemName=mkhl.direnv) extension
1. Open the project directory — HLS starts automatically

### Neovim

With `nvim-lspconfig` and direnv:

```lua
require('lspconfig').hls.setup {}
```

HLS auto-starts when you open a `.hs` file in the project.

## Binary Cache

`flake.nix` configures **cache.iog.io** — IOG's pre-built GHC and Haskell packages.

Entering the shell needs `--accept-flake-config` (or the equivalent in
`~/.config/nix/nix.conf`), otherwise the substituter is ignored and GHC is built
from source. First `nix develop` may take a few minutes; later entries are instant.

## Gotchas This Template Already Handles

Three things that cost real debugging time, baked in so you don't rediscover them:

- **Never run bare `cabal` outside the dev shell.** It picks up whatever system
  GHC is on `PATH`. If that GHC has a newer `base`, resolution fails and the
  error blames the first dependency that caps `base` — so it reads as a bad
  dependency choice when the real fault is the wrong compiler. Every `just`
  recipe re-enters the shell automatically when `IN_NIX_SHELL` is unset.
- **The executable sets `-threaded`.** Warp (and anything else wanting the
  threaded RTS) starts but accepts *zero connections* without it, failing with
  `getSystemTimerManager: ... requires linking against the threaded runtime`.
  In-process WAI tests do not catch this — only launching the binary does.
- **`fourmolu.yaml` is committed at the repo root.** Fourmolu searches *parent*
  directories, so without an in-repo config it may find one above your project
  while the Nix sandbox falls back to fourmolu's defaults — making `nix fmt` and
  `nix flake check` disagree on formatting forever.

## Customization

### Change GHC version

Edit `flake.nix`:

```nix
compiler-nix-name = "ghc9103";  # or ghc984, ghc9141
```

### Add dependencies

Edit `my-project.cabal`:

```cabal
build-depends:
  , base >=4.17 && <5
  , aeson >=2.0
  , text >=2.0
```

### Disable a formatter

Edit `flake.nix` treefmt section:

```nix
programs.hlint.enable = false;  # disable hlint
```

## License

MIT
