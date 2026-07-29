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
  # Returns `{ "<name>-check-<lisp>" = derivation; }`, one entry per
  # non-skipped implementation, meant to be spliced into `checks.<system>`.
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
            checkPhase = "${old.checkPhase} || echo \"cl-nix-forge: expected failure on ${implementation}, continuing\"";
          });
        in
        if skip then
          builtins.trace "cl-nix-forge mkCheckMatrix: skipping ${name} (expect.${implementation}.skip = true)" null
        else
          lib.nameValuePair name (if expectedFailure then tolerant else built);
    in
    lib.listToAttrs (lib.filter (e: e != null) (map mkEntry lisps));
}
