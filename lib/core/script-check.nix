{
  lib,
  pkgs,
  invoke,
}:
let
  checkRuntime = import ./check-runtime.nix { inherit lib pkgs; };
in
{
  # Runs a check through an arbitrary Lisp entry point instead of through
  # `asdf:test-system`.
  #
  # Why this is not just `doCheck`/`mkTestCheck`: an enclosing `test-op` is
  # not neutral. cl-weave is its own test subject, and its suite contains a
  # test that performs `test-op` on cl-weave/test directly in order to assert
  # the ASDF integration's failure path -- driving that suite from an
  # enclosing `test-op` puts the same operation on the plan twice and ASDF
  # rejects it as a circular dependency. Such a system is untestable through
  # `asdf:test-system` by construction, not by oversight.
  #
  # Why `run-tests.lisp` is the default: nerima-lisp's PACKAGE_STANDARD.md
  # mandates that every package expose `run-tests.lisp` at its repository
  # root as the universal test entry point, precisely so that tooling never
  # has to know how a package loads its suite. Defaulting to it means the
  # command a developer runs by hand (`sbcl --script run-tests.lisp`) and the
  # gate CI runs cannot drift apart.
  #
  # Implementation note: this is `drv.enableCheck` with its `checkPhase`
  # replaced, NOT a fresh derivation. Everything that makes the entry point
  # work -- the resolved CL_SOURCE_REGISTRY including
  # `lispCheckDependencies`, the transitive native-library environment, the
  # identity output translations, a writable working tree that already holds
  # the compiled FASLs from `buildPhase` -- is exactly what `lispDerivation`
  # computed for itself. Recomputing any of it here would be a second,
  # silently divergent copy of `resolvedSearchPath`.
  #
  #   drv             :: a `lispDerivation` result. Its `lispCheckDependencies`
  #                      are pulled in, because this runs as a check.
  #   entryPoint      :: String ? "run-tests.lisp" -- path of a Lisp file
  #                      inside the source tree, relative to its root.
  #   entryPointText  :: String ? null -- inline Lisp source instead of a
  #                      file in the tree. Mutually exclusive with
  #                      `entryPoint`; use it for a one-off assertion that
  #                      does not deserve a committed file.
  #   timeoutSeconds  :: Int ? null -- see core/check-runtime.nix. Default is no
  #                      limit.
  #   killAfterSeconds:: Int ? 30 -- SIGKILL grace period after the SIGTERM
  #                      deadline.
  #   name            :: String ? null -- derivation pname; defaults to the
  #                      built system's pname suffixed with `-script-check`,
  #                      so a `mkTestCheck` and a `mkScriptCheck` over the
  #                      same system are distinguishable in a build log.
  mkScriptCheck =
    {
      drv,
      entryPoint ? "run-tests.lisp",
      entryPointText ? null,
      timeoutSeconds ? null,
      killAfterSeconds ? 30,
      name ? null,
    }@args:
    let
      # `entryPoint` has a default, so "was it passed?" is the only way to
      # detect the ambiguous call -- the same test `lispDerivation` applies
      # to `lispSystem`/`lispSystems`.
      entryPointGiven = args ? entryPoint;

      lispImplementation =
        drv.clNixForgeLispImplementation
          or (throw "cl-nix-forge mkScriptCheck: `drv` must be a cl-nix-forge lispDerivation result");

      # `lispDerivation` records its full argument set in `passthru.args`;
      # a `lisp` absent from it means the caller took the default.
      lisp = drv.args.lisp or pkgs.sbcl;

      # An inline entry point becomes a store file; a tree entry point stays
      # a relative path, resolved against the build directory at run time so
      # the script sees the same working tree the suite lives in.
      scriptPath =
        if entryPointText != null then
          builtins.toFile "cl-nix-forge-entry-point-${lib.strings.sanitizeDerivationName (if name != null then name else drv.pname or "check")}.lisp" entryPointText
        else
          entryPoint;

      # asdf-derivation.nix's `lispImplementations` table is the ONE place
      # that knows how to run a script non-interactively under a given
      # implementation; `invoke` is reused rather than rebuilt so this cannot
      # drift from what `lispDerivation`'s own build phase does.
      lispCommand = invoke "mkScriptCheck" lispImplementation lisp scriptPath;
    in
    if entryPointGiven && entryPointText != null then
      throw "cl-nix-forge mkScriptCheck: pass exactly one of `entryPoint` or `entryPointText`"
    else if entryPointText == null && (!builtins.isString entryPoint || entryPoint == "") then
      throw "cl-nix-forge mkScriptCheck: `entryPoint` must be a non-empty path relative to the source root"
    else if entryPointText == null && lib.hasPrefix "/" entryPoint then
      throw "cl-nix-forge mkScriptCheck: `entryPoint` is resolved inside the build tree, so it must be relative, got \"${entryPoint}\""
    else
      # `invoke`'s unsupported-implementation `throw` fires only when the
      # command string is forced, and `checkPhase` is forced far too late for
      # that: `builtins.tryEval` on the result would report success and a
      # negative test would silently pass while catching nothing. Forcing it
      # here surfaces the error while the caller's own expression evaluates --
      # the same guarantee `lispDerivation` and `lispScript` give.
      builtins.seq lispCommand (
        drv.enableCheck.overrideAttrs (
          old:
          let
            resolvedName = if name != null then name else "${old.pname}-script-check";
          in
          {
            pname = resolvedName;
            nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ checkRuntime.packages;
            checkPhase = ''
              runHook preCheck
              ${checkRuntime.isolateHome}
              ${checkRuntime.withTimeLimit {
                label = resolvedName;
                command = lispCommand;
                inherit timeoutSeconds killAfterSeconds;
              }}
              runHook postCheck
            '';
          }
        )
      );
}
