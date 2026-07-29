{ lib, pkgs }:
{
  # Declarative multi-implementation test matrix, replacing the scattered
  # `meta.broken` predicate lists every piece of prior art falls back to
  # once it needs to run the same test suite under more than one Lisp.
  #
  #   lispDerivation :: the module's own `lispDerivation` function (passed
  #                      in rather than imported, so this file has no
  #                      dependency on asdf-derivation.nix and can't create
  #                      an import cycle).
  #   args           :: the exact attrset you'd pass to `lispDerivation`
  #                      (lispSystem/lispSystems, src, lispDependencies,
  #                      ...) -- WITHOUT `lisp`/`lispImplementation`/
  #                      `doCheck`, which this function sets per entry.
  #   lisps          :: [ String ] ? [ "sbcl" ] -- which implementations to
  #                      run the check under. Each name must be a key of
  #                      `lispPackages`.
  #   lispPackages   :: { <name> = derivation; } the Lisp implementation
  #                      package for each name in `lisps` (e.g.
  #                      `{ sbcl = pkgs.sbcl; ecl = pkgs.ecl; }`). Kept
  #                      separate from the `lisps` name list so the same
  #                      name set can point at different package sources
  #                      (nixpkgs stable vs. a nightly override) without
  #                      touching call sites.
  #   externalBins   :: [ derivation ] ? [ ] -- non-Lisp interpreters or
  #                      tools a test suite shells out to (e.g. several
  #                      real-world shells for a shell-completion test
  #                      matrix); added to every implementation's
  #                      `nativeBuildInputs`.
  #   expect         :: { <name> = { skip ? false; expectedFailure ? false; }; }
  #                      per-implementation overrides. `skip` omits that
  #                      implementation's check entirely (with a
  #                      `builtins.trace` so a skip is never silent).
  #                      `expectedFailure` still runs the check -- so a
  #                      regression to *passing* stays visible in the
  #                      build log -- but does not fail `nix flake check`
  #                      if it fails.
  #
  # Three different things can keep an implementation out of the result, and
  # collapsing any two of them would let a real regression hide behind a
  # bookkeeping decision. In precedence order:
  #
  #   1. "the caller asked to skip it" -- `expect.<impl>.skip`. A deliberate,
  #      per-call-site choice; checked first precisely because it is the one
  #      the caller wrote down, so its trace is the one they want to see.
  #   2. "this implementation cannot run here" -- a PLATFORM SKIP. Automatic,
  #      expected, and not a defect: nixpkgs says the package is unavailable
  #      on the evaluating system, so there is nothing to run and nothing to
  #      have regressed. Deciding this from `lib.meta.availableOn` (i.e. the
  #      package's own `meta.platforms`/`meta.badPlatforms` against
  #      `pkgs.stdenv.hostPlatform`) rather than from a platform list kept
  #      here is what lets the same matrix be written once and used on every
  #      system: nixpkgs is the authority on where CCL builds, and it changes.
  #   3. "this implementation is expected to fail this suite" --
  #      `expect.<impl>.expectedFailure`. NOT a skip: the check is still
  #      built and still runs, so the day the underlying bug is fixed the
  #      log says so. It only stops a known failure from failing the build.
  #
  # Note what (2) deliberately does NOT cover: a package that is available
  # here but broken, unfree or insecure still throws, loudly, exactly as it
  # would anywhere else in nixpkgs. Swallowing those would turn a packaging
  # problem into a silently missing check, which is the failure mode this
  # whole function exists to prevent.
  #
  # Returns `{ "<name>-check-<lisp>" = derivation; }`, one entry per
  # implementation that is neither skipped nor unavailable here, meant to be
  # spliced into `checks.<system>`.
  mkCheckMatrix =
    {
      lispDerivation,
      args,
      lisps ? [ "sbcl" ],
      lispPackages,
      externalBins ? [ ],
      expect ? { },
    }:
    let
      baseName = args.pname or (lib.concatStringsSep "-" (args.lispSystems or [ args.lispSystem ]));

      mkEntry =
        implementation:
        let
          settings = expect.${implementation} or { };
          skip = settings.skip or false;
          expectedFailure = settings.expectedFailure or false;
          name = "${baseName}-check-${implementation}";

          lispPackage =
            lispPackages.${implementation}
              or (throw "cl-nix-forge mkCheckMatrix: no package given for lisp \"${implementation}\" in `lispPackages`");

          # Reads `meta` only. That matters: for a package nixpkgs refuses to
          # build here, forcing the DERIVATION throws ("Package ... is not
          # available on the requested hostPlatform"), which is what makes a
          # cross-platform matrix impossible to write without this check --
          # but `meta` itself stays evaluable, so asking the question is
          # safe even when acting on the answer would not be.
          availableHere = lib.meta.availableOn pkgs.stdenv.hostPlatform lispPackage;

          built = lispDerivation (
            (removeAttrs args [
              "lisp"
              "lispImplementation"
              "doCheck"
            ])
            // {
              lispImplementation = implementation;
              lisp = lispPackage;
              doCheck = true;
              nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ externalBins;
            }
          );

          tolerant = built.overrideAttrs (old: {
            # Still runs the real check -- so a fix that makes it start
            # passing shows up in the log -- but a failure doesn't fail
            # `nix flake check`.
            #
            # Getting "tolerate a failure" right in a build phase is fiddlier
            # than it looks, and the obvious spelling is wrong twice over.
            # `${old.checkPhase} || echo ...` binds the `||` to the phase's
            # LAST command (`runHook postCheck`), not to the Lisp invocation
            # in the middle, so errexit still aborts the phase at the
            # invocation and the tolerance never applies -- which is what
            # this code did until an example finally pointed it at a suite
            # that genuinely fails. And `if ( set -e; ... )` does not fix it
            # either: bash ignores `-e` inside an `if` condition "even if -e
            # is set", so the phase would run past the failure to postCheck
            # and report zero. A plain subshell with errexit merely OFF in
            # the parent is the spelling that behaves.
            checkPhase = ''
              set +e
              ( set -e; ${old.checkPhase} )
              checkStatus=$?
              set -e
              if [ "$checkStatus" -ne 0 ]; then
                echo "cl-nix-forge mkCheckMatrix: expected failure on ${implementation} (exit $checkStatus), continuing"
              else
                echo "cl-nix-forge mkCheckMatrix: ${implementation} PASSED a check marked expect.${implementation}.expectedFailure -- drop that flag so a future regression fails the build again"
              fi
            '';
          });
        in
        if skip then
          builtins.trace "cl-nix-forge mkCheckMatrix: skipping ${name} (expect.${implementation}.skip = true)" null
        else if !availableHere then
          # Traced, never silent -- same reason as the `skip` branch above:
          # a check that vanishes without saying so is indistinguishable
          # from a check that was never written. The wording names the
          # platform and the authority, so a missing entry can be told apart
          # from a caller skip at a glance.
          builtins.trace
            "cl-nix-forge mkCheckMatrix: skipping ${name} -- nixpkgs reports ${implementation} unavailable on ${pkgs.stdenv.hostPlatform.system} (platform skip, not a failure)"
            null
        else
          lib.nameValuePair name (if expectedFailure then tolerant else built);
    in
    lib.listToAttrs (lib.filter (e: e != null) (map mkEntry lisps));
}
