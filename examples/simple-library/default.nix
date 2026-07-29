{
  cl,
  pkgs,
  lib,
}:
let
  version = cl.fromAsdSystem ./greeter.asd;

  greeter = cl.lispDerivation {
    lispSystem = "greeter";
    inherit version;
    src = ./.;
  };

  greeterLisp = cl.lispWithSystems { systems = [ greeter ]; };

  greeterEclWithSbclSystem = cl.lispWithSystems {
    systems = [ greeter ];
    lisp = pkgs.ecl;
  };

  greeterEcl = cl.lispDerivation {
    lispSystem = "greeter";
    inherit version;
    src = ./.;
    lisp = pkgs.ecl;
  };

  greeterSbclWithEclImplementation = cl.lispDerivation {
    lispSystem = "greeter";
    inherit version;
    src = ./.;
    lispImplementation = "ecl";
  };

  greeterBuildTest = cl.lispDerivation {
    lispSystem = "greeter";
    inherit version;
    src = ./.;
    lispBuildOp = [ "asdf:test-system" ];
  };

  greeterScript = cl.lispScript {
    name = "greeter-script";
    dependencies = [ greeter ];
    src = pkgs.writeText "greeter-script.lisp" ''
      (require "asdf")
      (asdf:load-system "greeter")
      (unless (string= "Hello, Nix, from cl-nix-forge!" (greeter:greet "Nix"))
        (error "greeter dependency was not available"))
    '';
  };

  greeterEclScript = cl.lispScript {
    name = "greeter-ecl-script";
    dependencies = [ greeterEcl ];
    lisp = pkgs.ecl;
    src = pkgs.writeText "greeter-ecl-script.lisp" ''
      (require "asdf")
      (asdf:load-system "greeter")
      (unless (string= "Hello, ECL, from cl-nix-forge!" (greeter:greet "ECL"))
        (error "greeter dependency was not available through ECL"))
    '';
  };

  # Stands in for a Lisp implementation `lib/core/asdf-derivation.nix`'s
  # `lispImplementations` table has no row for. A stub rather than a real
  # nixpkgs package, so the negative test below stays valid on hosts where
  # that package does not exist -- nothing is ever built from it, both entry
  # points reject it during evaluation.
  #
  # The name is deliberately one no implementation will ever have. It used
  # to be `ccl-1.13`, which quietly stopped testing anything the moment CCL
  # got a row: adding a row is a routine, expected change, and this check
  # must survive every one of them.
  unsupportedLisp = pkgs.runCommand "no-such-lisp-0.0" { } "mkdir -p $out/bin";

  unsupportedLispDerivation = cl.lispDerivation {
    lispSystem = "greeter";
    inherit version;
    src = ./.;
    lisp = unsupportedLisp;
  };

  unsupportedLispScript = cl.lispScript {
    name = "unsupported-lisp-script";
    lisp = unsupportedLisp;
    src = pkgs.writeText "unsupported-lisp-script.lisp" ''(require "asdf")'';
  };

  greeterApp = cl.mkExecutable {
    args = {
      pname = "greeter-cli";
      version = cl.fromAsdSystem ./greeter-app.asd;
      src = ./.;
      lispSystem = "greeter-app";
      lispDependencies = [ greeter ];
    };
  };
in
{
  packages.greeter = greeter;
  packages.greeter-script = greeterScript;
  packages.greeter-ecl-script = greeterEclScript;
  packages.greeter-app = greeterApp;

  checks.greeter-test = cl.mkTestCheck greeter;
  checks.greeter-build-op = greeterBuildTest;
  # Each negative test below pairs `tryEval` with a POSITIVE control asserted
  # in the same check, because `tryEval` reports only `success`, never the
  # message: a typo in the subject expression fails exactly like the defect
  # under test, and a check that asserts nothing but `!success` would then be
  # green while proving nothing. The control is chosen to be the narrowest
  # fact that must hold if the subject is well formed, so a failure can only
  # be the rejection the check is named for.
  checks.greeter-ecl-rejects-sbcl-system =
    assert greeter.clNixForgeLispImplementation == "sbcl";
    assert !(builtins.tryEval greeterEclWithSbclSystem).success;
    pkgs.runCommand "greeter-ecl-rejects-sbcl-system" { } "touch $out";
  checks.greeter-sbcl-rejects-ecl-implementation =
    assert greeterEcl.clNixForgeLispImplementation == "ecl";
    assert !(builtins.tryEval greeterSbclWithEclImplementation).success;
    pkgs.runCommand "greeter-sbcl-rejects-ecl-implementation" { } "touch $out";

  # One table, two consumers: an implementation with no row must be refused
  # by `lispDerivation` and `lispScript` alike. Before they shared a table
  # it was possible for one of them to keep working -- which is exactly how
  # a half-supported implementation would slip through.
  #
  # The control is the stub's own package name: `unsupportedLisp` is
  # referenced by nothing but these two negatives, so without it a typo in
  # the stub itself would satisfy both `tryEval`s. Asserting the name is
  # what `lispImplementation` defaults to proves the rejection came from the
  # missing table row and not from a malformed subject.
  checks.unsupported-lisp-implementation-rejected =
    assert lib.getName unsupportedLisp == "no-such-lisp";
    assert !(builtins.tryEval unsupportedLispDerivation).success;
    assert !(builtins.tryEval unsupportedLispScript).success;
    pkgs.runCommand "unsupported-lisp-implementation-rejected" { } "touch $out";

  # `fromNixpkgsLisp` has exactly one calling form. Passing a bare
  # derivation used to mean "no implementation boundary"; now it means
  # "evaluation error".
  checks.from-nixpkgs-lisp-requires-implementation =
    assert
      (cl.fromNixpkgsLisp {
        drv = pkgs.sbcl.pkgs.alexandria;
        lispImplementation = "sbcl";
      }).clNixForgeLispImplementation == "sbcl";
    assert !(builtins.tryEval (cl.fromNixpkgsLisp pkgs.sbcl.pkgs.alexandria)).success;
    pkgs.runCommand "from-nixpkgs-lisp-requires-implementation" { } "touch $out";

  # The other half of that decision: `fromDerivation` keeps
  # `lispImplementation` optional, because it also wraps outputs with no
  # Lisp in them. That is only safe while wrapping something cl-nix-forge
  # built inherits its implementation unasked, and naming a different one
  # is an error rather than a relabel.
  checks.from-derivation-implementation-boundary =
    assert (cl.fromDerivation { drv = greeter; }).clNixForgeLispImplementation == "sbcl";
    assert
      !(builtins.tryEval (
        cl.fromDerivation {
          drv = greeter;
          lispImplementation = "ecl";
        }
      )).success;
    pkgs.runCommand "from-derivation-implementation-boundary" { } "touch $out";

  checks.greeter-runtime =
    pkgs.runCommand "greeter-runtime"
      {
        nativeBuildInputs = [
          greeterLisp
          greeterScript
        ];
        CL_SOURCE_REGISTRY = "/tmp/cl-nix-forge-extra-registry";
      }
      ''
        sbcl --non-interactive \
          --eval '(require "asdf")' \
          --eval '(asdf:load-system "greeter")' \
          --eval '(unless (search "/tmp/cl-nix-forge-extra-registry" (uiop:getenv "CL_SOURCE_REGISTRY")) (error "caller CL_SOURCE_REGISTRY was not preserved"))' \
          --eval '(unless (string= "Hello, Nix, from cl-nix-forge!" (greeter:greet "Nix")) (error "greeter dependency was not loaded"))'
        greeter-script
        touch "$out"
      '';

  checks.greeter-executable =
    pkgs.runCommand "greeter-executable"
      {
        nativeBuildInputs = [ greeterApp ];
      }
      ''
        test "$(greeter-cli)" = "Hello, executable, from cl-nix-forge!"
        touch "$out"
      '';

  checks.greeter-ecl-script =
    pkgs.runCommand "greeter-ecl-script"
      {
        nativeBuildInputs = [ greeterEclScript ];
      }
      ''
        # Both halves of the ECL row in `lispImplementations`, from one
        # build: greeterEcl's build phase ran the compile through it, and
        # this wrapper has the very same flag baked in by lispScript.
        grep -q -- --shell ${greeterEclScript}/bin/greeter-ecl-script
        greeter-ecl-script
        touch "$out"
      '';

  checks.greeter-docs = cl.mkDocsSite { root = ./docs; };

  devShells.greeter = cl.mkDevShell { drv = greeter; };
}
