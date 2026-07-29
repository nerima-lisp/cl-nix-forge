{
  cl,
  pkgs,
  lib,
}:
let
  matrixProbe = pkgs.writeShellScriptBin "matrix-probe" ''
    printf '%s\n' 'matrix-probe: ready'
  '';

  # Every implementation `lib/core/asdf-derivation.nix`'s
  # `lispImplementations` table has a row for. Written once and reused by
  # every matrix below, so "we added a row but forgot to exercise it" is not
  # a state this example can be in.
  #
  # The attribute names are the row keys, which are also what `lib.getName`
  # returns for the corresponding package -- note `clasp-common-lisp`, whose
  # nixpkgs ATTRIBUTE differs from its `pname`.
  lispPackages = {
    sbcl = pkgs.sbcl;
    ecl = pkgs.ecl;
    abcl = pkgs.abcl;
    ccl = pkgs.ccl;
    clisp = pkgs.clisp;
    clasp = pkgs.clasp-common-lisp;
  };

  allLisps = builtins.attrNames lispPackages;

  system = pkgs.stdenv.hostPlatform.system;

  # What `mkCheckMatrix`'s platform skip is expected to leave behind on each
  # system this flake builds for, spelled out rather than recomputed from
  # `lib.meta.availableOn` -- recomputing it with the same predicate the
  # implementation uses would assert nothing at all.
  #
  # This is therefore a record of what nixpkgs (at the revision in
  # flake.lock) says today. If a nixpkgs bump changes where an
  # implementation builds, the contract check below fails and names the
  # difference: update this table, and the platform coverage claimed for
  # cl-nix-forge, together.
  #
  #   ccl   -- Linux only upstream; no darwin build in nixpkgs.
  #   clasp -- x86_64-linux only; it is an LLVM-based implementation and
  #            nixpkgs builds it for exactly one platform.
  expectedLisps = {
    x86_64-linux = [
      "abcl"
      "ccl"
      "clasp"
      "clisp"
      "ecl"
      "sbcl"
    ];
    aarch64-darwin = [
      "abcl"
      "clisp"
      "ecl"
      "sbcl"
    ];
  };

  expectedHere =
    expectedLisps.${system}
      or (throw "examples/multi-lisp-matrix: no expected implementation set recorded for ${system}");

  sortNames = builtins.sort (a: b: a < b);

  # The suite that must PASS everywhere. One source tree, one system, every
  # implementation available here.
  passing = cl.mkCheckMatrix {
    args = {
      lispSystem = "matrix-demo";
      version = cl.fromAsdSystem ./matrix-demo.asd;
      src = ./.;
    };
    lisps = allLisps;
    inherit lispPackages;
    externalBins = [ matrixProbe ];
  };

  # The suite that must FAIL everywhere, inverted below. Without this, a row
  # whose invocation runs the script but always exits 0 -- ABCL's obvious
  # `--batch --load` does exactly that -- would make every check above look
  # green while testing nothing.
  failing = cl.mkCheckMatrix {
    args = {
      pname = "matrix-demo-mustfail";
      lispSystem = "matrix-demo-fail";
      version = cl.fromAsdSystem ./matrix-demo-fail.asd;
      src = ./.;
    };
    lisps = allLisps;
    inherit lispPackages;
  };

  # Runs the real `checkPhase` and succeeds only if it FAILS.
  #
  # The `set +e` / subshell / `$?` dance is not idiomatic decoration, it is
  # the only shape of this that works. `checkPhase` ends in `runHook
  # postCheck`, so the phase's own exit status is postCheck's -- zero --
  # unless errexit aborts the phase at the Lisp invocation. And bash
  # documents that in a context where `-e` is being ignored (the condition
  # of an `if`, either side of `||`), NO command inside the compound
  # command is affected by `-e` "even if -e is set" -- so the obvious
  # `if ( set -e; ... )` reports success no matter what the Lisp did.
  #
  # Running the subshell as a plain command with errexit merely OFF in the
  # parent is different: `set -e` inside it genuinely takes effect. That
  # distinction was found by this check reporting a green result while SBCL
  # was visibly printing "unhandled condition in --disable-debugger mode,
  # quitting" three lines above -- i.e. the negative check had precisely the
  # always-exits-0 bug it exists to detect.
  mustFail =
    drv:
    drv.overrideAttrs (old: {
      checkPhase = ''
        echo "cl-nix-forge example: the suite below is SUPPOSED to fail"
        set +e
        ( set -e; ${old.checkPhase} )
        checkStatus=$?
        set -e
        if [ "$checkStatus" -eq 0 ]; then
          echo "NEGATIVE CHECK FAILED: a failing test suite exited 0 under this implementation."
          echo "Its row in lib/core/asdf-derivation.nix runs the script but does not propagate failure."
          exit 1
        fi
        echo "cl-nix-forge example: failure propagated as exit $checkStatus, as required"
      '';
    });

  # `expectedFailure` is NOT a skip: the check is still built and still runs
  # the failing suite, it just does not fail the build. Pointing it at a
  # suite that genuinely fails is the only way to show the difference -- the
  # same suite is proven to fail by `matrix-demo-mustfail-check-sbcl`, so
  # this derivation building at all is the "does not fail the build" half of
  # the claim, and `matrix-demo-expected-failure-ran` below is the "still
  # runs the check" half.
  expectedFailureDemo = cl.mkCheckMatrix {
    args = {
      pname = "matrix-demo-expected-failure";
      lispSystem = "matrix-demo-fail";
      version = cl.fromAsdSystem ./matrix-demo-fail.asd;
      src = ./.;
    };
    lisps = [ "sbcl" ];
    inherit lispPackages;
    expect.sbcl.expectedFailure = true;
  };

  # Evaluated, never built: `mkCheckMatrix` returns a lazy attrset, so
  # asking for its attribute NAMES costs nothing even for implementations
  # that cannot be built here. That is what makes these assertions cheap
  # enough to state as facts rather than eyeball in a trace.
  callerSkipProbe = cl.mkCheckMatrix {
    args = {
      pname = "matrix-demo-caller-skip-probe";
      lispSystem = "matrix-demo";
      version = cl.fromAsdSystem ./matrix-demo.asd;
      src = ./.;
    };
    lisps = allLisps;
    inherit lispPackages;
    expect.ecl.skip = true;
  };

  namesFor = prefix: implementations: sortNames (map (i: "${prefix}-check-${i}") implementations);

  # Three separate claims, because conflating any two of them is exactly the
  # bug: a platform skip, a caller skip and an expected failure must not be
  # able to stand in for one another.
  matrixContract =
    let
      platformSkip = {
        what = "platform skip on ${system}";
        actual = builtins.attrNames passing;
        want = namesFor "matrix-demo" expectedHere;
      };
      callerSkip = {
        what = "expect.ecl.skip on ${system}";
        actual = builtins.attrNames callerSkipProbe;
        want = namesFor "matrix-demo-caller-skip-probe" (builtins.filter (i: i != "ecl") expectedHere);
      };
      expectedFailureIsNotASkip = {
        what = "expect.sbcl.expectedFailure still yields an entry";
        actual = builtins.attrNames expectedFailureDemo;
        want = [ "matrix-demo-expected-failure-check-sbcl" ];
      };
      claims = [
        platformSkip
        callerSkip
        expectedFailureIsNotASkip
      ];
      broken = builtins.filter (c: c.actual != c.want) claims;
    in
    assert lib.assertMsg (broken == [ ]) (
      "examples/multi-lisp-matrix: mkCheckMatrix returned the wrong checks.\n"
      + lib.concatMapStringsSep "\n" (c: ''
        ${c.what}:
          expected: ${lib.concatStringsSep ", " c.want}
          actual:   ${lib.concatStringsSep ", " c.actual}
      '') broken
    );
    pkgs.runCommand "matrix-demo-attrs-contract" { } ''
      echo "mkCheckMatrix on ${system} yielded: ${lib.concatStringsSep " " (builtins.attrNames passing)}"
      touch "$out"
    '';
in
{
  checks =
    passing
    // (lib.mapAttrs (_name: mustFail) failing)
    // expectedFailureDemo
    // {
      matrix-demo-attrs-contract = matrixContract;

      # The suite marked `expectedFailure` really executed: this marker is
      # written by the test file itself, in checkPhase, and only reaches
      # $out because installPhase runs afterwards.
      matrix-demo-expected-failure-ran = pkgs.runCommand "matrix-demo-expected-failure-ran" { } ''
        marker="${expectedFailureDemo.matrix-demo-expected-failure-check-sbcl}/matrix-demo-fail-ran"
        if [ ! -f "$marker" ]; then
          echo "expectedFailure did not run the check: $marker is missing"
          exit 1
        fi
        echo "expectedFailure ran the (failing) suite under: $(cat "$marker")"
        touch "$out"
      '';
    };
}
