{
  cl,
  pkgs,
  lib,
}:
let
  natlib = cl.markNativeLibrary (
    pkgs.stdenv.mkDerivation {
      pname = "natlib";
      version = "0.1.0";
      src = ./natlib;
      buildPhase = ''
        runHook preBuild
        $CC -shared -fPIC -o libnatlib${pkgs.stdenv.hostPlatform.extensions.sharedLibrary} natlib.c
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/lib"
        cp libnatlib${pkgs.stdenv.hostPlatform.extensions.sharedLibrary} "$out/lib/"
        runHook postInstall
      '';
    }
  );

  cffi = cl.fromNixpkgsLisp {
    drv = pkgs.sbcl.pkgs.cffi;
    lispImplementation = "sbcl";
  };

  consumer1 = cl.lispDerivation {
    lispSystem = "consumer1";
    version = "0.1.0";
    src = ./consumer1;
    lispDependencies = [ cffi ];
    nativeLibraries = [ natlib ];
  };

  # consumer2 depends only on consumer1 -- it never mentions natlib. Its
  # own build/check environment still gets natlib's directory on
  # LD_LIBRARY_PATH/DYLD_LIBRARY_PATH, transitively, via core/native.nix.
  consumer2 = cl.lispDerivation {
    lispSystem = "consumer2";
    version = cl.fromAsdSystem ./consumer2/consumer2.asd;
    src = ./consumer2;
    lispDependencies = [ consumer1 ];
    doCheck = true;
  };

  consumer2Lisp = cl.lispWithSystems { systems = [ consumer2 ]; };

  consumerApp = cl.mkExecutable {
    args = {
      pname = "consumer-native-app";
      version = cl.fromAsdSystem ./consumer-app/consumer-app.asd;
      src = ./consumer-app;
      lispSystem = "consumer-app";
      lispDependencies = [ consumer2 ];
    };
    programPath = "consumer-native-app";
  };
in
{
  packages = {
    inherit
      natlib
      consumer1
      consumer2
      consumerApp
      ;
  };

  checks.native-library-contract =
    assert natlib.nativeLibraries == [ natlib ];
    assert natlib.passthru.nativeLibraries == [ natlib ];
    pkgs.runCommand "native-library-contract" { } "touch $out";
  checks.consumer2-sees-natlib-transitively =
    pkgs.runCommand "consumer2-sees-natlib-transitively"
      {
        nativeBuildInputs = [ consumer2Lisp ];
      }
      ''
        sbcl --non-interactive \
          --eval '(require "asdf")' \
          --eval '(asdf:test-system "consumer2")'
        touch "$out"
      '';
  checks.consumer-native-executable =
    pkgs.runCommand "consumer-native-executable"
      {
        nativeBuildInputs = [ consumerApp ];
      }
      ''
        test "$(consumer-native-app)" = "42"
        touch "$out"
      '';
  checks.lisp-dependencies-avoid-build-inputs =
    assert consumer2.buildInputs == [ ];
    pkgs.runCommand "lisp-dependencies-avoid-build-inputs" { } "touch $out";

  checks.external-lisp-implementation-contract =
    let
      incompatibleConsumer = cl.lispDerivation {
        lispSystem = "consumer1";
        version = "0.1.0";
        src = ./consumer1;
        lisp = pkgs.ecl;
        lispImplementation = "ecl";
        lispDependencies = [ cffi ];
      };

      directWrapper = cl.fromDerivation {
        drv = natlib;
        lispImplementation = "sbcl";
      };
    in
    assert cffi.clNixForgeLispImplementation == "sbcl";
    assert directWrapper.clNixForgeLispImplementation == "sbcl";
    assert !(builtins.tryEval incompatibleConsumer.drvPath).success;
    pkgs.runCommand "external-lisp-implementation-contract" { } "touch $out";
}
