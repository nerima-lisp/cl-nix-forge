{
  lib,
  pkgs,
  # `invoke` and `registryPathOf` rather than the whole asdf-derivation.nix
  # module: that file owns the single implementation table and the single
  # rule for turning a dependency into a registry entry, and this module
  # needs exactly those two. Taking the module wholesale would hand it
  # `lispDerivation` as well, which it has no business calling.
  invoke,
  registryPathOf,
}:
let
  # A dependency's own output plus everything already in its closure --
  # the same rule asdf-derivation.nix applies when it builds
  # CL_SOURCE_REGISTRY for a build. Registering only the root would work
  # for a leaf and break the moment that dependency loads one of its own.
  registryPathsFor = drv: map registryPathOf ([ drv ] ++ (drv.ancestry.deps or [ ]));
in
{
  # A flake `apps.<system>.<name>` entry for a derivation that already
  # knows which of its binaries is the interesting one.
  #
  # Every downstream flake spells this out by hand, and every one of them
  # repeats the program name three times: in `program`, in
  # `meta.mainProgram`, and in the `bin/` path. `mkExecutable` and
  # `lispScript` both already set `meta.mainProgram`, and `lib.getExe`
  # exists to read it, so the derivation stays the single source of truth
  # for its own entry point.
  #
  #   drv         :: any derivation with `meta.mainProgram` (or whose
  #                  `pname` is its binary name).
  #   description :: String ? the derivation's own `meta.description`.
  mkApp =
    {
      drv,
      description ? drv.meta.description or null,
    }:
    {
      type = "app";
      program = lib.getExe drv;
      meta = {
        mainProgram = drv.meta.mainProgram or (lib.getName drv);
      }
      // lib.optionalAttrs (description != null) { inherit description; };
    };

  # `nix run .#test` -- the org-standard entry point that runs the repo's
  # own `run-tests.lisp` (see PACKAGE_STANDARD.md in nerima-lisp/.github).
  #
  # This deliberately drives the script rather than `asdf:test-system`, so
  # the plain `sbcl --script run-tests.lisp` path a contributor uses in a
  # REPL-less shell is the same path CI exercises; `mkTestCheck` covers the
  # `test-system` route. The script is run from the source tree in place,
  # because a `run-tests.lisp` locates its own systems relative to
  # `*load-truename*` -- copying it elsewhere would silently test whichever
  # copy of the project happened to be on the registry first.
  #
  #   pname            :: String -- project name; the runner is installed
  #                        as `<pname>-test`.
  #   src              :: the source tree containing `runner`. Its own
  #                        systems shadow anything else on the registry.
  #   lispDependencies :: [ derivation ] ? [ ] -- other cl-nix-forge or
  #                        `fromDerivation`-wrapped systems the suite needs
  #                        (a test framework, typically).
  #   timeoutSeconds   :: Int ? 600, killAfterSeconds :: Int ? 30 -- SBCL
  #                        defers signals to safepoints, so a tight
  #                        compiled loop (a runaway backtracking bug is
  #                        exactly this) outlives a bare SIGTERM and falls
  #                        through to the enclosing CI job timeout instead
  #                        of failing here with an attributable error.
  #                        `timeout -k` escalates to SIGKILL.
  mkTestApp =
    {
      pname,
      src,
      runner ? "run-tests.lisp",
      lisp ? pkgs.sbcl,
      lispImplementation ? lib.getName lisp,
      lispDependencies ? [ ],
      timeoutSeconds ? 600,
      killAfterSeconds ? 30,
      description ? "Run the ${pname} test suite",
    }:
    let
      # No trailing ":" -- that is ASDF's spelling of "and then inherit
      # whatever is configured", which would let a developer's
      # ~/.config/common-lisp make `nix run .#test` pass locally and fail
      # in CI. An explicitly exported CL_SOURCE_REGISTRY is still honoured,
      # appended so it cannot shadow the tree under test.
      registry = lib.concatStringsSep ":" (
        [ "${src}//" ] ++ lib.concatMap registryPathsFor lispDependencies
      );

      runnerApp = pkgs.writeShellApplication {
        name = "${pname}-test";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          # `src` is a read-only store path, so ASDF's default output
          # translations (under $HOME/.cache) are what make compiling the
          # suite possible at all. Respect a real HOME; invent a throwaway
          # one only when there is none, as on a bare CI runner.
          export HOME="''${HOME:-$(mktemp -d)}"
          export CL_SOURCE_REGISTRY="${registry}''${CL_SOURCE_REGISTRY:+:$CL_SOURCE_REGISTRY}"
          exec timeout -k ${toString killAfterSeconds}s ${toString timeoutSeconds}s ${
            invoke "mkTestApp" lispImplementation lisp "${src}/${runner}"
          } "$@"
        '';
      };
    in
    {
      type = "app";
      program = lib.getExe runnerApp;
      meta = {
        inherit description;
        mainProgram = "${pname}-test";
      };
    };

  # `overlays.default` -- expose this flake's packages in the `pkgs`
  # namespace under their own names.
  #
  # The name a package takes in `pkgs` is its `pname`, read off the
  # derivation rather than spelled a second time in the overlay: a flake
  # whose `packages.default` is built by `lispDerivation` already named it
  # once, in `lispSystem` or `pname`, and an overlay that repeats the name
  # is one rename away from exporting `pkgs.cl-weave` from a package called
  # something else.
  #
  #   packages :: the flake's own `self.packages` (keyed by system).
  #   names    :: [ String ] ? [ "default" ] -- which entries of
  #               `packages.<system>` to publish. Not "all of them":
  #               `packages.docs` must not become `pkgs.docs`.
  mkOverlay =
    {
      packages,
      names ? [ "default" ],
    }:
    _final: prev:
    let
      # `prev`, not `final`. The attribute NAMES here are computed (from
      # each package's own `pname`), so evaluating this attrset's key set
      # forces `system` -- and `final.stdenv` cannot be forced while the
      # overlay that produces it is still being evaluated. That is an
      # infinite recursion, reproduced before this comment was written. A
      # hand-written overlay with literal keys, `{ cl-weave = ...; }`, gets
      # away with `final` because its names are known without evaluating
      # anything; the moment it grows a second package and starts
      # generating names, it does not. `prev` is the fixpoint from before
      # this overlay and cannot depend on it.
      system = prev.stdenv.hostPlatform.system;
      forSystem =
        packages.${system}
          or (throw "cl-nix-forge mkOverlay: this flake exports no packages for ${system}");
    in
    lib.listToAttrs (
      map (
        name:
        let
          drv =
            forSystem.${name} or (throw "cl-nix-forge mkOverlay: no `packages.${system}.${name}` to publish");
        in
        lib.nameValuePair (lib.getName drv) drv
      ) names
    );
}
