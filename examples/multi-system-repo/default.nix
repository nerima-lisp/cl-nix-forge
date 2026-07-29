{
  cl,
  pkgs,
  lib,
}:
let
  # Keep core-b's build tree free of core-a.  That makes this fixture prove
  # that ASDF resolves core-a through the declared lispDependencies edge,
  # rather than finding it incidentally in the repository source tree.
  coreBSrc = pkgs.runCommand "core-b-source" { } ''
    mkdir -p "$out"
    cp ${./core-b.asd} "$out/core-b.asd"
    cp ${./core-b.lisp} "$out/core-b.lisp"
    cp ${./core-b-test.lisp} "$out/core-b-test.lisp"
  '';

  outputs = rec {
    core-a = cl.lispDerivation {
      src = ./.;
      lispSystem = "core-a";
      version = cl.fromAsdSystem ./core-a.asd;
    };
    core-b = cl.lispDerivation {
      src = coreBSrc;
      lispSystem = "core-b";
      version = cl.fromAsdSystem ./core-b.asd;
      lispDependencies = [ core-a ];
      doCheck = true;
    };
  };

  multiOutputs = cl.lispMultiDerivation {
    src = ./.;
    systems = {
      core-a.version = cl.fromAsdSystem ./core-a.asd;
      core-b = {
        version = cl.fromAsdSystem ./core-b.asd;
        lispDependencies = [ multiOutputs.core-a ];
        doCheck = true;
      };
    };
  };

  # `outputs`/`multiOutputs` above never reach dedup.nix's merge: core-b
  # declares core-a as a lispDependencies edge, which puts core-a in
  # core-b's dedupKey and so gives the two systems different keys. The pair
  # below is the shape that DOES merge -- same source tree, same (empty)
  # dependency closure, ASDF finding core-a next to core-b in $PWD -- so
  # both systems hash to one key and anything depending on both collapses
  # them into a single derivation.
  mergingSystems =
    extraArgs:
    cl.lispMultiDerivation {
      src = ./.;
      # Shared at the top level rather than per system: two systems that
      # merge become one derivation, so they must agree here anyway, and
      # arguments written once cannot disagree.
      version = "0.1.0";
      systems = {
        core-a = extraArgs.core-a or { };
        core-b = extraArgs.core-b or { };
      };
    };

  mergingPair = mergingSystems { };

  mergeConsumer = cl.lispDerivation {
    src = ./merge-consumer;
    lispSystem = "merge-consumer";
    version = "0.1.0";
    lispDependencies = [
      mergingPair.core-a
      mergingPair.core-b
    ];
  };

  # The same pair, except that the two systems disagree about an argument
  # the merged derivation could only keep one of.
  conflictingPair = mergingSystems {
    core-a.buildInputs = [ pkgs.hello ];
    core-b.buildInputs = [ pkgs.cowsay ];
  };

  conflictingMergeConsumer = cl.lispDerivation {
    src = ./merge-consumer;
    lispSystem = "merge-consumer";
    version = "0.1.0";
    lispDependencies = [
      conflictingPair.core-a
      conflictingPair.core-b
    ];
  };

  foreignCoreB = cl.lispDerivation {
    src = coreBSrc;
    lispSystem = "core-b";
    version = cl.fromAsdSystem ./core-b.asd;
    lispDependencies = [ (cl.fromDerivation { drv = outputs.core-a; }) ];
    doCheck = true;
  };
in
{
  packages = {
    core-a = outputs.core-a;
    core-b = outputs.core-b;
  };

  checks.core-b-loads-core-a = outputs.core-b;
  checks.multi-derivation-core-b = multiOutputs.core-b;
  checks.from-derivation-core-b = foreignCoreB;

  # Positive merge path: the two systems really did collapse into ONE
  # dependency carrying both of them (asserted, so a future change that
  # stops merging can't leave this passing for the wrong reason), and that
  # single derivation still builds and loads.
  checks.merged-systems-build =
    assert lib.length mergeConsumer.ancestry.deps == 1;
    assert
      builtins.sort (a: b: a < b) (lib.head mergeConsumer.ancestry.deps).lispSystems == [
        "core-a"
        "core-b"
      ];
    mergeConsumer;

  # Negative merge path: identical systems except for `buildInputs`, which
  # the merged derivation could only keep one of. `tryEval` stops at weak
  # head normal form and a derivation attrset reaches that long before its
  # dependency walk runs, so forcing `drvPath` is what makes dedup.nix
  # actually attempt (and refuse) the merge.
  checks.merged-systems-reject-conflicting-args =
    assert !(builtins.tryEval conflictingMergeConsumer.drvPath).success;
    pkgs.runCommand "merged-systems-reject-conflicting-args" { } "touch $out";

  checks.core-b-requires-core-a =
    pkgs.runCommand "core-b-requires-core-a"
      {
        nativeBuildInputs = [ pkgs.sbcl ];
      }
      ''
        mkdir registry
        cp ${coreBSrc}/core-b.asd ${coreBSrc}/core-b.lisp registry/
        if CL_SOURCE_REGISTRY="$PWD/registry" sbcl --non-interactive \
          --eval '(require "asdf")' \
          --eval '(asdf:load-system "core-b")'; then
          echo "core-b unexpectedly loaded without its core-a dependency" >&2
          exit 1
        fi
        touch "$out"
      '';
}
