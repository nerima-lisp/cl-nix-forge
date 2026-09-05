{ lib, pkgs }:
let
  checkRuntime = import ../core/check-runtime.nix { inherit lib pkgs; };

  # Written into the build tree, then installed, rather than written straight
  # to `$out`: `$out` must not exist until installPhase, and a report the
  # build can inspect before publishing is what lets this derivation assert
  # its own result instead of exporting an empty directory.
  reportDirectory = "cl-nix-forge-coverage-report";
in
{
  # An sb-cover HTML coverage report for a `lispDerivation`, as a derivation
  # whose `$out` IS the report (`$out/cover-index.html` and friends).
  #
  # SBCL ONLY. sb-cover is an SBCL contrib with no counterpart in ECL or any
  # other implementation, so this throws during evaluation for a derivation
  # built with anything else. Producing an empty report, or silently skipping,
  # would leave a green check attesting to nothing.
  #
  # Instrument the target system before compiling the test suite:
  #
  #   (declaim (optimize sb-cover:store-coverage-data))
  #   (asdf:load-system "<sys>" :force t)
  #   (declaim (optimize (sb-cover:store-coverage-data 0)))
  #
  # Coverage is recorded at compile time. Force the target system to compile
  # under sb-cover, reuse dependency FASLs, then restore the default before
  # compiling the test suite.
  #
  # No coverage threshold is enforced. `sb-cover:report` returns only the
  # report pathname, so a percentage gate would require parsing generated
  # HTML. Projects that need a threshold can calculate it in Lisp and use
  # `mkCommandCheck`.
  #
  #   drv             :: a `lispDerivation` result built with SBCL.
  #   systems         :: [ String ] ? drv.lispSystems -- which ASDF systems to
  #                      instrument, i.e. what the report is ABOUT. Narrow it
  #                      to keep an `/examples` or `/test` system out.
  #   entryPoint      :: String ? "run-tests.lisp" -- how to exercise the
  #                      instrumented code, same convention as
  #                      `mkScriptCheck`.
  #   entryPointText  :: String ? null -- inline Lisp instead; mutually
  #                      exclusive with `entryPoint`. Use it to drive the
  #                      suite through `asdf:test-system` where that works.
  #   timeoutSeconds  :: Int ? null, killAfterSeconds :: Int ? 30 -- see
  #                      core/check-runtime.nix.
  #   name            :: String ? null -- pname; defaults to the built
  #                      system's pname suffixed with `-coverage`.
  #
  # The result asserts its own report is non-empty before installing it, so
  # it is directly usable as `checks.coverage` -- no separate `test -f
  # "$coverage/cover-index.html"` wrapper derivation is needed.
  mkCoverageReport =
    {
      drv,
      systems ? drv.lispSystems,
      entryPoint ? "run-tests.lisp",
      entryPointText ? null,
      timeoutSeconds ? null,
      killAfterSeconds ? 30,
      name ? null,
    }@args:
    let
      entryPointGiven = args ? entryPoint;

      lispImplementation =
        drv.clNixForgeLispImplementation
          or (throw "cl-nix-forge mkCoverageReport: `drv` must be a cl-nix-forge lispDerivation result");

      lisp = drv.args.lisp or pkgs.sbcl;

      # `(load ...)` of a relative namestring resolves against the process's
      # working directory, which is the build tree -- the same place the
      # entry point's own `run-tests.lisp` conventions expect to be run from.
      loadForm =
        if entryPointText != null then
          "(load ${builtins.toJSON (toString (builtins.toFile "cl-nix-forge-coverage-entry-point.lisp" entryPointText))})"
        else
          "(load ${builtins.toJSON entryPoint})";

      runner = builtins.toFile "cl-nix-forge-coverage-runner.lisp" ''
        (require "asdf")
        (require :sb-cover)

        ;; Instrumentation only applies to code compiled while this
        ;; proclamation is active, hence the :force t below.
        (declaim (optimize sb-cover:store-coverage-data))
        ${lib.concatMapStringsSep "\n" (
          system: "(asdf:load-system ${builtins.toJSON system} :force t)"
        ) systems}
        (declaim (optimize (sb-cover:store-coverage-data 0)))

        ;; The org-standard run-tests.lisp ends in (uiop:quit N), which on
        ;; SBCL is (sb-ext:exit :abort nil): it UNWINDS the stack, so this
        ;; cleanup still runs and the report is written whether the suite
        ;; passed or failed. Without unwind-protect a failing suite would
        ;; produce no report at all, which is precisely when the coverage
        ;; numbers are most worth looking at.
        (unwind-protect
             ${loadForm}
          (sb-cover:report
           (uiop:ensure-directory-pathname
            (merge-pathnames ${builtins.toJSON reportDirectory} (uiop:getcwd)))))
      '';
    in
    if lispImplementation != "sbcl" then
      throw "cl-nix-forge mkCoverageReport: sb-cover is an SBCL contrib, but `drv` is built with ${lispImplementation}. Coverage is unavailable for that implementation -- drop the coverage report or build the system with SBCL."
    else if entryPointGiven && entryPointText != null then
      throw "cl-nix-forge mkCoverageReport: pass exactly one of `entryPoint` or `entryPointText`"
    else if !builtins.isList systems || systems == [ ] || !lib.all builtins.isString systems then
      throw "cl-nix-forge mkCoverageReport: `systems` must be a non-empty list of ASDF system name strings"
    else
      drv.enableCheck.overrideAttrs (
        old:
        let
          resolvedName = if name != null then name else "${old.pname}-coverage";
        in
        {
          pname = resolvedName;
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ checkRuntime.packages;

          checkPhase = ''
            runHook preCheck
            ${checkRuntime.isolateHome}
            ${checkRuntime.withTimeLimit {
              label = resolvedName;
              # Spelled out rather than routed through asdf-derivation.nix's
              # `invoke`, because coverage is SBCL-only by construction (see
              # above) and has no implementation to look up. The
              # `escapeShellArg` is the same discipline `invoke` uses, and for
              # the same reason: it quotes only when it must and preserves the
              # generated script's string context, which is the only thing
              # making that file an input of this derivation.
              command = "${lib.getExe lisp} --script ${lib.escapeShellArg runner}";
              inherit timeoutSeconds killAfterSeconds;
            }}
            if [ ! -s ${lib.escapeShellArg "${reportDirectory}/cover-index.html"} ]; then
              echo "cl-nix-forge: ${resolvedName}: sb-cover produced no report -- nothing was instrumented." >&2
              echo "cl-nix-forge: check that ${lib.escapeShellArg (lib.concatStringsSep ", " systems)} are the systems the entry point actually exercises." >&2
              exit 1
            fi
            runHook postCheck
          '';

          # `$out` is the report itself, so it can be published as a docs-like
          # artifact and gated on directly.
          installPhase = ''
            runHook preInstall
            mkdir -p "$out"
            cp -R -- ${lib.escapeShellArg reportDirectory}/. "$out"
            runHook postInstall
          '';
        }
      );
}
