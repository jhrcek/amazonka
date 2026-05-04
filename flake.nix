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
          ];

          shellHook = pre-commit.shellHook + ''
            export BOTOCORE=${botocore.outPath}
            echo "botocore: $BOTOCORE"
          '' + pkgs.lib.optionalString pkgs.stdenv.isLinux ''
            # Why this is needed only when running Nix as a package
            # manager on a stock Linux distro (e.g. Ubuntu, Fedora) and
            # NOT on NixOS:
            #
            # The Hackage `zlib` package declares `pkgconfig-depends:
            # zlib`, so Cabal calls `pkg-config --cflags/--libs zlib`
            # when building it and uses whatever paths pkg-config
            # returns to compile and link the hsc2hs probe.
            #
            # On NixOS there is no /usr/include/zlib.h or
            # /usr/lib/x86_64-linux-gnu/libz.so on the system, and the
            # system-wide pkg-config search path is configured to point
            # at nix-store .pc files. So pkg-config returns nix-store
            # paths for both cflags and libs, and the probe compiles
            # and links against a single coherent zlib.
            #
            # On a stock distro the system *does* have zlib1g-dev (or
            # equivalent) installed by apt, with its own zlib.pc on
            # pkg-config's default search path. pkgs.mkShell does not
            # reliably propagate buildInputs' .dev outputs into
            # PKG_CONFIG_PATH the way a real stdenv build does, so
            # without this export pkg-config finds the system zlib.pc
            # first. The probe then gets compiled with system zlib.h
            # but linked against the nix-store libz that cc-wrapper's
            # NIX_LDFLAGS adds — and any disagreement on the size or
            # layout of `z_stream` between the two trips glibc's
            # stack-protector with *** stack smashing detected ***.
            #
            # This is also why `ghcWithPackages` would not help: the
            # mismatch is at the C-level pkg-config layer, not in
            # GHC's package database. macOS uses install_name / DYLD
            # and has no equivalent system/nix zlib clash, so this is
            # Linux-only.
            export PKG_CONFIG_PATH=${pkgs.lib.makeSearchPath "lib/pkgconfig" [
              pkgs.zlib.dev
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
