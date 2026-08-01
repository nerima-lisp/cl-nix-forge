{
  description = "cl-nix-forge -- crane for Common Lisp/ASDF: a Nix flake-library for building, testing, and composing ASDF systems as Nix derivations.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
      ...
    }:
    let
      # Only platforms actually exercised, and CI exercises exactly one:
      # x86_64-linux. aarch64-darwin was dropped in the 2026-08-01 revision of
      # PACKAGE_STANDARD.md -- it was verified only by local development, which
      # nothing enforces, so it advertised a platform nothing gated.
      #
      # This list is this repository's own, for its examples and docs outputs.
      # It is NOT the list an adopter passes to `mkPackageFlake`: that one
      # belongs to the adopter's flake, and `mkPackageFlake` iterates whatever
      # it is given.
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      pkgsFor = system: import nixpkgs { inherit system; };

      clFor =
        system:
        import ./lib/default.nix {
          inherit (pkgsFor system) lib;
          pkgs = pkgsFor system;
        };

      # Each entry contributes `packages`/`checks`/`devShells`. Almost all of
      # them are examples, which double as this library's test suite; `docs`
      # is not an example but has the same shape deliberately, so this
      # repository's own documentation site is built by this repository's own
      # `mkDocsSite` and is gated by the same duplicate-name guard.
      contributorsFor =
        system:
        let
          pkgs = pkgsFor system;
          cl = clFor system;
          call =
            path:
            import path {
              inherit cl pkgs;
              inherit (pkgs) lib;
            };
        in
        {
          docs = call ./docs;
          simple-library = call ./examples/simple-library;
          multi-system-repo = call ./examples/multi-system-repo;
          native-library-consumer = call ./examples/native-library-consumer;
          multi-lisp-matrix = call ./examples/multi-lisp-matrix;
          asd-search-path = call ./examples/asd-search-path;
          check-only-dependencies = call ./examples/check-only-dependencies;
          checks-and-coverage = call ./examples/checks-and-coverage;
          flake-outputs = call ./examples/flake-outputs;
          org-preset = call ./examples/org-preset;
        };

      # Reject duplicate names rather than allowing a later contributor to
      # shadow an earlier one silently.
      mergeAttr =
        attrName: contributors:
        nixpkgs.lib.foldl' (
          acc: contributorName:
          let
            contribution = contributors.${contributorName}.${attrName} or { };
            duplicateNames = nixpkgs.lib.intersectLists (builtins.attrNames acc) (
              builtins.attrNames contribution
            );
          in
          assert nixpkgs.lib.assertMsg (duplicateNames == [ ])
            "flake.nix: duplicate ${attrName} entries from ${contributorName}: ${nixpkgs.lib.concatStringsSep ", " duplicateNames}";
          acc // contribution
        ) { } (builtins.attrNames contributors);

      treefmtEval = forAllSystems (system: treefmt-nix.lib.evalModule (pkgsFor system) ./treefmt.nix);

      versionExtractorContract =
        system:
        let
          pkgs = pkgsFor system;
          results = import ./lib/batteries/version.test.nix { inherit (pkgs) lib; };
        in
        assert pkgs.lib.all (result: result) (builtins.attrValues results);
        pkgs.runCommand "version-extractor-contract" { } "touch $out";
    in
    {
      lib = forAllSystems clFor;

      packages = forAllSystems (system: mergeAttr "packages" (contributorsFor system));

      devShells = forAllSystems (system: mergeAttr "devShells" (contributorsFor system));

      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          contributors = contributorsFor system;

          # This repository's own test suite. `contributorsFor` says the
          # examples double as it: `examples/*/default.nix` drive `mkPackage`,
          # `mkTestCheck`, `mkCoverageReport`, `mkPackageFlake` and the org
          # preset against real ASDF trees, several of them by asserting that a
          # deliberately broken input *fails*. `version-extractor-contract`
          # covers the one piece of pure evaluation no example can reach, since
          # `fromAsdSystem` parses a string and never builds anything.
          suite = (mergeAttr "checks" contributors) // {
            version-extractor-contract = versionExtractorContract system;
          };
        in
        suite
        // {
          formatting = treefmtEval.${system}.config.build.check self;

          # `mkPackageFlake` hands its adopters `checks.default = <the
          # package's test suite>`. This repository is the library that
          # generates that attribute and had none of its own, because its
          # `checks` are assembled by merging contributors rather than by a
          # single generator call. Being the library is not an exemption from
          # being gated by it.
          #
          # `default` depends on every member of `suite`, so it is the same
          # statement `mkPackageFlake` makes for an adopter: "this package's
          # tests pass". `nix build .#checks.<system>.default` fails if any one
          # of them fails.
          #
          # `formatting` is deliberately not a member. treefmt over the whole
          # tree is not a statement about whether the library works, which is
          # why `mkPackageFlake` also keeps it as a sibling of `default` rather
          # than a component.
          default = pkgs.runCommand "cl-nix-forge-suite" { } ''
            # Each member is named in the build script so that it enters this
            # derivation's input closure and is built before this command runs.
            # Recording the paths rather than discarding them keeps the output
            # a readable manifest of what was actually gated.
            ${nixpkgs.lib.concatMapStringsSep "\n" (
              name: "printf '%s %s\\n' ${nixpkgs.lib.escapeShellArg name} ${suite.${name}} >> $out"
            ) (builtins.attrNames suite)}
          '';

          # Restated here rather than left to `mergeAttr`. docs/default.nix
          # already contributes this exact derivation, but only at evaluation
          # time, so nothing reading flake.nix -- a reviewer or
          # check-conformance.sh -- could see that the `mkdocs build --strict`
          # gate was wired at all. Same derivation, no second build.
          docs = contributors.docs.checks.docs;
        }
      );
    };
}
