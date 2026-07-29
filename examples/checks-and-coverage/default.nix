{
  cl,
  pkgs,
  lib,
}:
let
  version = cl.fromAsdSystem ./forge-checks.asd;

  forgeChecks = cl.lispDerivation {
    lispSystem = "forge-checks";
    inherit version;
    src = ./.;
  };

  # An ECL build of the same source, only ever evaluated -- never built -- to
  # prove that `mkCoverageReport` rejects a non-SBCL implementation during
  # evaluation instead of producing an empty report at build time.
  forgeChecksEcl = cl.lispDerivation {
    lispSystem = "forge-checks";
    inherit version;
    src = ./.;
    lisp = pkgs.ecl;
  };

  # Proving a FAILURE path in Nix takes care. A derivation that fails is not a
  # check that passes, and `builtins.tryEval` (which the sibling examples use)
  # only sees evaluation errors, never build-time ones. So take the derivation
  # the library actually produced and invert nothing but its `checkPhase`: the
  # real phase runs verbatim in a subshell, and the check passes only when that
  # phase failed with one of the expected statuses.
  #
  # The `set +e` / bare subshell / `$?` shape is load-bearing, and the obvious
  # `( set -e; ... ) || status=$?` is WRONG. POSIX says errexit is ignored for
  # any command of an AND-OR list but the last, and bash extends that
  # suppression into the subshell so thoroughly that an explicit `set -e`
  # inside does not restore it:
  #
  #   $ ( set -e; false; echo REACHED ) || echo "status=$?"
  #   REACHED
  #
  # A mid-phase failure would therefore not abort the phase, and the subshell
  # would report the status of `runHook postCheck` -- i.e. 0 -- turning this
  # into a check that passes whether or not the failure it exists to detect
  # ever happened. Keeping the subshell out of any AND-OR list is what makes
  # its inner `set -e` real.
  expectCheckFailure =
    {
      check,
      name,
      statuses,
      minimumSeconds ? null,
    }:
    check.overrideAttrs (old: {
      pname = name;
      checkPhase = ''
        clNixForgeStart=$SECONDS
        set +e
        ( set -e
        ${old.checkPhase}
        )
        clNixForgeExpected=$?
        set -e
        clNixForgeElapsed=$(( SECONDS - clNixForgeStart ))
        echo "cl-nix-forge example: inner check exited $clNixForgeExpected after ''${clNixForgeElapsed}s"
        if [ "$clNixForgeExpected" -eq 0 ]; then
          echo "cl-nix-forge example: expected ${name} to FAIL, but it succeeded" >&2
          exit 1
        fi
        case "$clNixForgeExpected" in
          ${lib.concatMapStringsSep "|" toString statuses}) ;;
          *)
            echo "cl-nix-forge example: expected ${name} to exit ${
              lib.concatMapStringsSep " or " toString statuses
            }, got $clNixForgeExpected" >&2
            exit 1
            ;;
        esac
        ${lib.optionalString (minimumSeconds != null) ''
          if [ "$clNixForgeElapsed" -lt ${toString minimumSeconds} ]; then
            echo "cl-nix-forge example: ${name} failed after only ''${clNixForgeElapsed}s; a time limit of ${toString minimumSeconds}s cannot have been what stopped it" >&2
            exit 1
          fi
        ''}
      '';
      # The inner check's own install step may publish artifacts; this
      # derivation only attests that the failure happened.
      installPhase = ''
        runHook preInstall
        mkdir -p "$out"
        runHook postInstall
      '';
    });

  # The org-standard entry point. forge-checks.asd's test-op errors on
  # purpose, so this check passing is itself proof that it did not route
  # through `asdf:test-system`.
  runTests = cl.mkScriptCheck {
    drv = forgeChecks;
    name = "forge-checks-run-tests";
    timeoutSeconds = 300;
  };

  # An inline entry point, for a one-off assertion that does not deserve a
  # committed file. The full dependency CL_SOURCE_REGISTRY is in place here
  # too -- that is the whole point.
  inlineEntryPoint = cl.mkScriptCheck {
    drv = forgeChecks;
    name = "forge-checks-inline-entry-point";
    timeoutSeconds = 300;
    entryPointText = ''
      (require "asdf")
      (asdf:load-system "forge-checks")
      (unless (= 6 (uiop:symbol-call :forge-checks :tally '(1 2 3)))
        (error "forge-checks was not loadable from the derivation's registry"))
      (format t "~&inline entry point resolved forge-checks through CL_SOURCE_REGISTRY.~%")
    '';
  };

  failingEntryPoint = cl.mkScriptCheck {
    drv = forgeChecks;
    name = "forge-checks-failing-entry-point";
    entryPoint = "run-tests-failing.lisp";
  };

  # 5s deadline, 5s SIGKILL grace. 124 means SIGTERM was enough; 137 means the
  # escalation had to fire. Both are accepted because which one wins depends
  # on where SBCL's next safepoint falls -- the guarantee being tested is that
  # the build dies at the deadline with a status that names a timeout, not
  # which signal got there first.
  runawayEntryPoint = cl.mkScriptCheck {
    drv = forgeChecks;
    name = "forge-checks-runaway";
    entryPoint = "run-tests-runaway.lisp";
    timeoutSeconds = 5;
    killAfterSeconds = 5;
  };

  artifactTool = cl.lispScript {
    name = "forge-emit-artifacts";
    dependencies = [ forgeChecks ];
    src = ./emit-artifacts.lisp;
  };

  # One artifact of each shape: a JSON file validated with jq, a text file
  # validated by a shell assertion, and a directory. The text file's name
  # contains a space on purpose -- it only survives because `command` is an
  # argv LIST run through `lib.escapeShellArgs`, never a concatenated string.
  artifacts = cl.mkCommandCheck {
    drv = forgeChecks;
    name = "forge-checks-artifacts";
    timeoutSeconds = 120;
    nativeBuildInputs = [ pkgs.jq ];
    command = [
      "${artifactTool}/bin/forge-emit-artifacts"
      "forge-report.json"
      "forge report.txt"
      "forge-report-parts"
    ];
    artifacts = [
      "forge-report.json"
      "forge report.txt"
      "forge-report-parts/"
    ];
    validationCommands = [
      ''jq -e '.schemaVersion == 1 and .kind == "forge-report" and .tally == 6' forge-report.json >/dev/null''
      ''grep -qx 'forge-report ok' "forge report.txt"''
    ];
  };

  coverage = cl.mkCoverageReport {
    drv = forgeChecks;
    name = "forge-checks-coverage";
    timeoutSeconds = 300;
  };

  coverageUnderEcl = cl.mkCoverageReport { drv = forgeChecksEcl; };
in
{
  packages.forge-checks = forgeChecks;
  packages.forge-emit-artifacts = artifactTool;
  packages.forge-checks-coverage = coverage;

  checks.forge-checks-run-tests = runTests;
  checks.forge-checks-inline-entry-point = inlineEntryPoint;

  checks.forge-checks-failing-entry-point-is-detected = expectCheckFailure {
    check = failingEntryPoint;
    name = "forge-checks-failing-entry-point-is-detected";
    # run-tests-failing.lisp exits 1 through `uiop:quit`.
    statuses = [ 1 ];
  };

  checks.forge-checks-timeout-kills-runaway = expectCheckFailure {
    check = runawayEntryPoint;
    name = "forge-checks-timeout-kills-runaway";
    statuses = [
      124
      137
    ];
    minimumSeconds = 5;
  };

  checks.forge-checks-artifacts = artifacts;

  # `$out` of a command check is the artifacts and nothing else: a full copy
  # of the source tree plus its FASLs would bury exactly what CI came for.
  checks.forge-checks-artifacts-land-in-out =
    pkgs.runCommand "forge-checks-artifacts-land-in-out" { inherit artifacts; }
      ''
        test -s "$artifacts/forge-report.json"
        test -s "$artifacts/forge report.txt"
        test -s "$artifacts/forge-report-parts/part-1.txt"
        test ! -e "$artifacts/forge-checks.lisp"
        touch "$out"
      '';

  checks.forge-checks-coverage-report = coverage;

  # The report derivation already fails when cover-index.html is empty. This
  # additionally proves the instrumentation reached the library's own source
  # rather than reporting on an empty set of files.
  checks.forge-checks-coverage-is-populated =
    pkgs.runCommand "forge-checks-coverage-is-populated" { report = coverage; }
      ''
        test -s "$report/cover-index.html"
        grep -q "forge-checks.lisp" "$report/cover-index.html"
        touch "$out"
      '';

  # Paired with a positive control for the same reason as the negatives in
  # examples/simple-library: `tryEval` yields only `success`, so a subject
  # that fails to evaluate for an unrelated reason is indistinguishable from
  # the rejection under test. Asserting that `forgeChecksEcl` itself
  # evaluates AND is an ECL build leaves `mkCoverageReport`'s SBCL-only
  # guard as the only thing the failure below can be attributed to.
  checks.forge-checks-coverage-rejects-ecl =
    assert forgeChecksEcl.clNixForgeLispImplementation == "ecl";
    assert !(builtins.tryEval coverageUnderEcl).success;
    pkgs.runCommand "forge-checks-coverage-rejects-ecl" { } "touch $out";

  devShells.forge-checks = cl.mkDevShell { drv = forgeChecks; };
}
