{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    botocore = {
      # Lock botocore until we fix https://github.com/issue/888
      url = "github:boto/botocore/f14ab129706a99198d42eed78d75350ea61c48e9";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, pre-commit-hooks, botocore }:
    flake-utils.lib.eachDefaultSystem (system:
      let

        pre-commit = pre-commit-hooks.lib.${system}.run {
          src = self;
          hooks = {
            cabal-fmt.enable = true;
            nixpkgs-fmt.enable = true;
            ormolu.enable = true;
            shellcheck.enable = true;
            shfmt.enable = true;
            prettier = {
              enable = true;
              files = "\\.json$";
            };
          };
        };

        pkgs = import nixpkgs {
          inherit system;
          config.allowBroken = true;
        };

        # The ghc compiler version patch level will be the latest that is available in nixpkgs.
        ghc810 = pkgs.haskell.packages."ghc810";
        ghc90 = pkgs.haskell.packages."ghc90";
        ghc92 = pkgs.haskell.packages."ghc92";
        ghc94 = pkgs.haskell.packages."ghc94";
        ghc96 = pkgs.haskell.packages."ghc96";
        ghc98 = pkgs.haskell.packages."ghc98";

        # The default ghc to use when entering `nix develop`.
        ghcDefault = ghc94;

        renameVersion = version: "ghc" + (pkgs.lib.replaceStrings [ "." ] [ "" ] version);

        mkDevShell = hsPkgs: pkgs.mkShell {
          name = "amazonka-${renameVersion hsPkgs.ghc.version}";

          buildInputs = [
            # Haskell Toolchain
            hsPkgs.ghc
            pkgs.cabal-install

            # Package Dependencies
            pkgs.gmp
            pkgs.ncurses
            pkgs.zlib

            # Development Tools
            pkgs.haskellPackages.cabal-fmt
            pkgs.haskell-language-server
            pkgs.hlint
            pkgs.nixpkgs-fmt
            pkgs.ormolu

            # Releases
            pkgs.gh

            pkgs.parallel
          ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            # On Linux, listing these in buildInputs is empirically required
            # for cabal's zlib hsc2hs probe to compile to a binary that
            # doesn't trip glibc's stack-protector canary. Their absence
            # changes some compile-time flag/setup-hook in a way we haven't
            # fully diagnosed; restoring them avoids the *** stack smashing
            # detected *** abort on Ubuntu CI runners.
            pkgs.zstd
            pkgs.bzip2
            pkgs.xz
          ];

          shellHook = pre-commit.shellHook + ''
            export BOTOCORE=${botocore.outPath}
            echo "botocore: $BOTOCORE"
          '' + pkgs.lib.optionalString pkgs.stdenv.isLinux ''
            # On Linux, pkgs.mkShell's NIX_LDFLAGS contributes -L flags
            # for buildInputs but no useful -rpath, so binaries linked
            # inside this shell have no DT_RUNPATH covering the nix
            # store and the loader cannot find their dependencies at
            # runtime (e.g. cabal's zlib hsc2hs probe failing with
            # "libzstd.so.1: cannot open"). LD_RUN_PATH is ignored when
            # the link line already contains any -rpath flag (which
            # cc-wrapper supplies), so we set LD_LIBRARY_PATH instead.
            # macOS uses a different mechanism (install_name / DYLD)
            # and GHC link chain there has no libdw/libelf, so this is
            # Linux-only.
            export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath [
              pkgs.gmp
              pkgs.ncurses
              pkgs.zlib
              pkgs.elfutils
              pkgs.zstd
              pkgs.bzip2
              pkgs.xz
            ]}
          '';
        };

        amazonka-gen =
          # Use ghc92 because we want hashable ==1.3.* for actual
          # generation and the ghc-bignum dep is inside a conditional,
          # so doJailbreak won't work.
          #
          # We need hashable-1.3 for generation because hashable >=1.4
          # uses a different hashing algorithm which breaks things by
          # causing the contents of `HashMap`s to be traversed in a
          # slightly different order. This matters when `Ptr`s are
          # used to resolve recursive shape references.
          ghc92.developPackage {
            root = ./gen;
            overrides = _hsFinal: hsPrev: with pkgs.haskell.lib; {
              data-fix = doJailbreak hsPrev.data-fix;
              ede = dontCheck (hsPrev.callHackageDirect
                {
                  pkg = "ede";
                  ver = "0.3.4.0";
                  sha256 = "sha256-bEYTVnVj/TigHgGiiMP/Yz3YE1gg2QYPCPrx6RrpSOo=";
                }
                { });
              hashable = hsPrev.callHackage "hashable" "1.3.5.0" { };
              pandoc = dontHaddock hsPrev.pandoc;
              semialign = doJailbreak hsPrev.semialign;
              string-qq = dontCheck hsPrev.string-qq;
              text-short = doJailbreak hsPrev.text-short;
              these = doJailbreak hsPrev.these;
              unordered-containers =
                hsPrev.callHackage "unordered-containers" "0.2.19.1" { };
            };
          };

      in
      {
        apps = {
          gen = {
            type = "app";
            program = "${amazonka-gen}/bin/gen";
          };

          gen-configs = {
            type = "app";
            program = "${amazonka-gen}/bin/gen-configs";
          };
        };

        checks = {
          inherit pre-commit;
        };

        packages = {
          default = amazonka-gen;
        };

        devShells = {
          ghc810 = mkDevShell ghc810;
          ghc90 = mkDevShell ghc90;
          ghc92 = mkDevShell ghc92;
          ghc94 = mkDevShell ghc94;
          ghc96 = mkDevShell ghc96;
          ghc98 = mkDevShell ghc98;
          default = mkDevShell ghcDefault;
        };
      });

  nixConfig.allow-import-from-derivation = "true";
}
