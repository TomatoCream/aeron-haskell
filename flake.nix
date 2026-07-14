{
  description = "Haskell project with haskell.nix, treefmt-nix, and dev tools";

  nixConfig = {
    extra-substituters = [
      "https://cache.iog.io"
    ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
    ];
    allow-import-from-derivation = true;
  };

  inputs = {
    haskellNix.url = "github:input-output-hk/haskell.nix";
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    systems.url = "github:nix-systems/default";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      haskellNix,
      systems,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import systems;

      imports = [
        inputs.treefmt-nix.flakeModule
      ];

      perSystem =
        {
          config,
          pkgs,
          system,
          lib,
          ...
        }:
        let
          projectName = "my-project";

          project = pkgs.haskell-nix.project' {
            src = lib.cleanSourceWith {
              src = ./.;
              name = projectName;
              filter =
                path: _type:
                let
                  baseName = builtins.baseNameOf path;
                in
                !(builtins.elem baseName [
                  ".git"
                  "dist-newstyle"
                  ".stack-work"
                  "result"
                  "result-*"
                  ".direnv"
                  ".envrc"
                  "flake.nix"
                  "flake.lock"
                  "treefmt.nix"
                ]);
            };

            compiler-nix-name = "ghc9124";

            shell = {
              tools = {
                cabal = { };
                haskell-language-server = { };
                hlint = { };
                fourmolu = { };
              };

              # cabal-fmt is not built via haskell.nix `tools`: 0.1.12 caps at
              # base <4.20, so it cannot be compiled against GHC 9.12's base-4.21.
              # nixpkgs builds it against a compiler it supports.
              buildInputs = with pkgs; [
                just
                zlib
                pkg-config
                haskellPackages.cabal-fmt
              ];

              shellHook = ''
                export PS1="\n\[\033[1;32m\][${projectName}:\w]\$\[\033[0m\] "
                echo "Haskell development shell for ${projectName}"
                echo "  GHC:      $(ghc --version)"
                echo "  Cabal:    $(cabal --version | head -1)"
                echo "  HLS:      $(haskell-language-server --version 2>/dev/null || echo 'available')"
                echo "  Fourmolu: $(fourmolu --version 2>/dev/null | head -1 || echo 'available')"
                echo "  cabal-fmt: $(cabal-fmt --version 2>/dev/null || echo 'available')"
                echo ""
              '';
            };
          };

          projectFlake = project.flake { };
        in
        {
          _module.args.pkgs = import nixpkgs {
            inherit system;
            overlays = [ haskellNix.overlay ];
            inherit (haskellNix) config;
          };

          packages.default = projectFlake.packages."${projectName}:exe:${projectName}";

          devShells.default = project.shell;

          treefmt = {
            projectRootFile = "flake.nix";

            programs.fourmolu.enable = true;
            programs.fourmolu.ghcOpts = [
              "BangPatterns"
              "PatternSynonyms"
              "TypeApplications"
              "ImportQualifiedPost"
            ];

            programs.cabal-fmt.enable = true;

            programs.hlint.enable = true;

            programs.nixfmt.enable = true;

            settings.global.excludes = [
              "dist-newstyle/*"
              ".stack-work/*"
              "result"
              "result-*"
              "*.lock"
            ];

            settings.formatter.hlint = {
              options = [ "-j" ];
            };
          };

          checks = {
            formatting = config.treefmt.build.check self;
          };
        };
    };
}
