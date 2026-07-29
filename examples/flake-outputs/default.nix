{
  cl,
  pkgs,
  lib,
}:
let
  version = cl.fromAsdSystem ./forge-demo.asd;

  # The common case, in one line: everything an ASDF build reads, and nothing
  # a local `sbcl --script run-tests.lisp` leaves lying around afterwards.
  src = cl.mkLispSource { root = ./.; };

  # Both escape hatches, exercised so they cannot quietly rot. `include` opts
  # in a tree the build genuinely reads (here the docs a `mkDocsSite` rooted
  # at the repo would need); `exclude` subtracts last, for a delivery that
  # should not carry its own test sources.
  srcWithDocs = cl.mkLispSource {
    root = ./.;
    include = [ ./docs ];
  };
  srcWithoutTests = cl.mkLispSource {
    root = ./.;
    exclude = [ ./t ];
  };

  demo = cl.lispDerivation {
    lispSystem = "forge-demo";
    inherit version src;
  };

  cli = cl.mkExecutable {
    args = {
      pname = "forge-demo-cli";
      lispSystem = "forge-demo-cli";
      inherit version src;
      lispDependencies = [ demo ];
      meta.description = "forge-demo command line interface";
    };
    # 2048 MB instead of SBCL's compiled-in 1024, and sb-cover loaded into the
    # image -- between them the two knobs cl-weave's hand-written
    # save-lisp-and-die installPhase needs before it can migrate here.
    dynamicSpaceSize = 2048;
    imageRequires = [ "sb-cover" ];
  };

  docs = cl.mkDocsSite {
    root = ./docs;
    pname = "forge-demo-docs";
    inherit version;
    meta = {
      description = "Rendered documentation for forge-demo";
      homepage = "https://github.com/nerima-lisp/cl-nix-forge";
      license = lib.licenses.mit;
    };
  };

  # A dependency that has a dependency of its own, so `mkTestApp`'s registry
  # has to carry a whole closure and not just the systems named directly.
  cliLibrary = cl.lispDerivation {
    lispSystem = "forge-demo-cli";
    inherit version src;
    lispDependencies = [ demo ];
  };

  testApp = cl.mkTestApp {
    pname = "forge-demo";
    inherit src;
    lispDependencies = [ cliLibrary ];
    timeoutSeconds = 120;
  };

  # Same runner, pointed at a suite that fails, so the check below can prove
  # `nix run .#test` reports red rather than swallowing it.
  failingTestApp = cl.mkTestApp {
    pname = "forge-demo-red";
    inherit src;
    runner = "run-tests-failing.lisp";
    timeoutSeconds = 120;
  };

  cliApp = cl.mkApp { drv = cli; };

  overlay = cl.mkOverlay { packages.${pkgs.stdenv.hostPlatform.system}.default = cli; };
in
{
  packages.forge-demo = demo;
  packages.forge-demo-cli = cli;
  packages.forge-demo-docs = docs;

  # Not built by `nix flake check` -- mkShell derivations refuse to build --
  # so the CL_SOURCE_REGISTRY fix in mkDevShell is verified with `nix develop`
  # rather than by a check. The `sbcl.withPackages` entry mirrors
  # cl-json-kit's benchmark shell, which is the case that had to compose.
  devShells.forge-demo = cl.mkDevShell {
    drv = demo;
    extraPackages = [ (pkgs.sbcl.withPackages (ps: [ ps.alexandria ])) ];
  };

  checks.forge-demo-test = cl.mkTestCheck demo;

  # Assert on the CONTENTS of the filtered source, not on the filter's code.
  checks.forge-demo-source-filter =
    pkgs.runCommand "forge-demo-source-filter"
      {
        plain = src;
        withDocs = srcWithDocs;
        withoutTests = srcWithoutTests;
      }
      ''
        # Kept: system definitions and Lisp source anywhere under the root --
        # including t/, which needs no clause of its own here, unlike the
        # hand-written re-inclusion cl-prolog's denylist required.
        test -f "$plain/forge-demo.asd"
        test -f "$plain/forge-demo.lisp"
        test -f "$plain/forge-demo-cli.lisp"
        test -f "$plain/t/forge-demo-test.lisp"
        test -f "$plain/run-tests.lisp"

        # Dropped: the artefacts a local test run leaves behind.
        # lib.cleanSourceFilter keeps every one of these, which is how they
        # end up changing a derivation hash after an unrelated test run.
        test ! -e "$plain/stale-build-artifact.fasl"
        test ! -e "$plain/stale-image.core"
        test ! -e "$plain/coverage-report-local"

        # Dropped: everything else that is not Lisp source, tracked or not.
        test ! -e "$plain/NOTES.md"
        test ! -e "$plain/docs"

        # `include` adds a tree back without re-admitting the junk beside it.
        test -f "$withDocs/docs/mkdocs.yml"
        test -f "$withDocs/forge-demo.asd"
        test ! -e "$withDocs/stale-image.core"

        # `exclude` is applied after everything else.
        test ! -e "$withoutTests/t"
        test -f "$withoutTests/forge-demo.lisp"

        touch "$out"
      '';

  checks.forge-demo-test-app =
    pkgs.runCommand "forge-demo-test-app"
      {
        runner = testApp.program;
        directDependency = cliLibrary;
        transitiveDependency = demo;
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        "$runner"

        # The registry the runner exports carries the whole dependency
        # closure, not just the systems named in `lispDependencies` --
        # registering only the roots works for a leaf and breaks as soon as
        # one of them loads a system of its own.
        grep -q "$directDependency" "$runner"
        grep -q "$transitiveDependency" "$runner"

        touch "$out"
      '';

  checks.forge-demo-test-app-reports-failure =
    pkgs.runCommand "forge-demo-test-app-reports-failure" { }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        if ${failingTestApp.program}; then
          echo "cl-nix-forge: mkTestApp reported success for a failing suite" >&2
          exit 1
        fi
        touch "$out"
      '';

  # One check for the whole delivered-binary contract: the app entry point
  # resolves through meta.mainProgram, the .asd's :entry-point ran, the
  # arguments arrived untouched, and both image options took effect.
  checks.forge-demo-executable-app = pkgs.runCommand "forge-demo-executable-app" { } ''
    printed="$(${cliApp.program} alpha beta)"
    echo "$printed"
    test "$(echo "$printed" | sed -n 1p)" = "forge-demo greets executable"
    test "$(echo "$printed" | sed -n 2p)" = "args=alpha beta"
    test "$(echo "$printed" | sed -n 3p)" = "dynamic-space-size=2048"
    test "$(echo "$printed" | sed -n 4p)" = "sb-cover=present"
    touch "$out"
  '';

  # A leading --dynamic-space-size belongs to the application, not to SBCL's
  # runtime. On the program-op path uiop's :save-runtime-options t guarantees
  # that; the Darwin fallback needs --end-runtime-options to match, and
  # without it this argument is swallowed (or crashes the image outright).
  checks.forge-demo-executable-argument-passthrough =
    pkgs.runCommand "forge-demo-executable-argument-passthrough" { }
      ''
        printed="$(${cliApp.program} --dynamic-space-size 99)"
        test "$(echo "$printed" | sed -n 2p)" = "args=--dynamic-space-size 99"
        test "$(echo "$printed" | sed -n 3p)" = "dynamic-space-size=2048"
        touch "$out"
      '';

  checks.forge-demo-overlay =
    pkgs.runCommand "forge-demo-overlay" { exposed = (pkgs.extend overlay).forge-demo-cli; }
      ''
        test -x "$exposed/bin/forge-demo-cli"
        test "$("$exposed/bin/forge-demo-cli" | sed -n 1p)" = "forge-demo greets executable"
        touch "$out"
      '';

  checks.forge-demo-docs =
    assert lib.assertMsg (docs.pname == "forge-demo-docs") "mkDocsSite ignored `pname`";
    assert lib.assertMsg (docs.version == version) "mkDocsSite ignored `version`";
    assert lib.assertMsg (
      docs.meta.homepage == "https://github.com/nerima-lisp/cl-nix-forge"
    ) "mkDocsSite ignored `meta`";
    pkgs.runCommand "forge-demo-docs" { site = docs; } ''
      test -f "$site/index.html"
      # The caller's identity really reaches the store path, rather than the
      # docs-site/unstable this builder used to hardcode.
      case "$site" in
        *-forge-demo-docs-${version}) ;;
        *)
          echo "cl-nix-forge: docs derivation is named $site" >&2
          exit 1
          ;;
      esac
      touch "$out"
    '';
}
