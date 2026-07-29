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
      # Only platforms actually exercised: x86_64-linux by CI, aarch64-darwin
      # by local development. Not advertising a platform nothing verifies.
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
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
        (mergeAttr "checks" (contributorsFor system))
        // {
          formatting = treefmtEval.${system}.config.build.check self;
          version-extractor-contract = versionExtractorContract system;
        }
      );
    };
}
