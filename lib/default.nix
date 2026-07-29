{ lib, pkgs }:
let
  dedup = import ./core/dedup.nix { inherit lib; };
  native = import ./core/native.nix { inherit lib pkgs; };
  external = import ./core/external.nix { inherit lib; };
  source = import ./core/source.nix { inherit lib; };
  asdfDerivation = import ./core/asdf-derivation.nix {
    inherit
      lib
      pkgs
      dedup
      native
      ;
  };
  matrix = import ./core/matrix.nix { inherit lib pkgs; };
  # `invoke` rather than a locally rebuilt command string: asdf-derivation.nix
  # owns the single implementation table, and reconstructing an invocation
  # from it here would recreate the very duplication that table exists to
  # remove.
  scriptCheck = import ./core/script-check.nix {
    inherit lib pkgs;
    inherit (asdfDerivation) invoke;
  };

  version = import ./batteries/version.nix { inherit lib; };
  checks = import ./batteries/checks.nix { inherit lib pkgs; };
  coverage = import ./batteries/coverage.nix { inherit lib pkgs; };
  docs = import ./batteries/docs.nix { inherit lib pkgs; };
  devshell = import ./batteries/devshell.nix { inherit lib pkgs; };
  app = import ./batteries/app.nix {
    inherit lib pkgs native;
    inherit (asdfDerivation) invoke;
  };
  siblings = import ./batteries/siblings.nix { inherit lib; };
  # `lib` only: this is the one module that spans systems rather than
  # living inside one, so it obtains its own `pkgs` per declared system.
  packageFlake = import ./batteries/package-flake.nix { inherit lib; };
  outputs = import ./batteries/outputs.nix {
    inherit lib pkgs;
    inherit (asdfDerivation) invoke registryPathOf;
  };
in
{
  # core/ -- the actual differentiators (see lib/core/*.nix doc comments).
  inherit (dedup) ancestryWalker unionAttrsBy;
  inherit (native)
    nativeLibraryPath
    nativeLibraryEnv
    nativeLibraryWrapperArgs
    markNativeLibrary
    libraryPathVar
    ;
  inherit (external) fromDerivation fromNixpkgsLisp;
  inherit (source) mkLispSource;
  inherit (asdfDerivation)
    lispDerivation
    lispMultiDerivation
    lispWithSystems
    lispScript
    ;
  inherit (scriptCheck) mkScriptCheck;
  mkCheckMatrix = args: matrix.mkCheckMatrix (args // { inherit (asdfDerivation) lispDerivation; });

  # batteries/ -- optional, clearly-secondary conveniences.
  inherit (version) fromAsdSystem asdSystemVersions;
  inherit (checks) mkTestCheck mkCommandCheck;
  inherit (coverage) mkCoverageReport;
  inherit (docs) mkDocsSite;
  inherit (devshell) mkDevShell;
  inherit (siblings) collect;
  inherit (packageFlake) mkPackageFlake;
  inherit (outputs) mkApp mkTestApp mkOverlay;
  mkExecutable = args: app.mkExecutable (args // { inherit (asdfDerivation) lispDerivation; });
}
