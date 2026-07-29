#  The org preset, end to end: one `mkPackageFlake` call standing in for the
#  hand-copied flake.nix that every nerima-lisp package currently carries.
#
#  Everything here is built from ONE package derivation. The instances below
#  differ only in the arguments under test (docs shape, runner, escape
#  hatches, declared systems), so `lispDerivation` resolves them all to the
#  same store path and the extra instances cost only the outputs they add.
{
  cl,
  pkgs,
  lib,
}:
let
  system = pkgs.stdenv.hostPlatform.system;

  common = {
    self = ./.;
    pname = "forge-preset";
    asd = ./forge-preset.asd;
    systems = [ system ];
    # Required, not defaulted from `self`: a real flake's `self` is an attrset
    # with an `outPath`, which `lib.fileset` rejects. See the argument's own
    # comment in lib/batteries/package-flake.nix.
    root = ./.;
    # flake.nix hands each example the `pkgs` and `cl` it built. Feeding them
    # straight back in is what makes this example test THAT library rather
    # than a second copy `mkPackageFlake` would otherwise re-import for
    # itself -- and it is why those two arguments exist at all, since an
    # example is never given a `nixpkgs` flake input.
    pkgsFor = _: pkgs;
    forgeFor = _: cl;
    timeoutSeconds = 300;
    meta = {
      description = "Package exercising cl-nix-forge's org flake preset end to end";
      license = lib.licenses.mit;
    };
  };

  preset = args: cl.mkPackageFlake (common // args);

  # treefmt-nix is not among the arguments flake.nix passes an example
  # (`{ cl, pkgs, lib }`), and `mkPackageFlake` takes `evalModule` rather than
  # closing over cl-nix-forge's own treefmt-nix input precisely so a consumer
  # picks its own version. So the property under test here is the WIRING, not
  # treefmt: this stub echoes the module it was handed into both the wrapper
  # and the check, and the check below asserts both carry the same marker.
  # A preset that evaluated the module twice, or that fed `formatter` and
  # `checks.formatting` different modules -- the one way `nix fmt` and the CI
  # gate can disagree about what "formatted" means -- would fail it.
  treefmtStub = {
    module = {
      projectRootFile = "flake.nix";
      programs.nixfmt.enable = true;
      marker = "forge-preset-treefmt-marker";
    };
    evalModule = evalPkgs: module: {
      config.build = {
        wrapper = evalPkgs.runCommand "forge-preset-treefmt-wrapper" { inherit (module) marker; } ''
          mkdir -p "$out/bin"
          echo "$marker" > "$out/bin/treefmt"
          chmod +x "$out/bin/treefmt"
        '';
        check =
          checked:
          evalPkgs.runCommand "forge-preset-treefmt-check"
            {
              inherit (module) marker;
              tree = checked;
            }
            ''
              # The gate must see the UNFILTERED tree: `mkLispSource` drops
              # every non-Lisp file, and a formatting gate that never sees
              # flake.nix is not a gate.
              test -f "$tree/CHANGELOG.md"
              echo "$marker" > "$out"
            '';
      };
    };
  };

  # The canonical instance: the whole standard output table, docs in their
  # own directory (cl-prolog / cl-json-kit's shape).
  flake = preset {
    docs.root = ./docs;
    treefmt = treefmtStub;
  };

  # cl-weave's shape: the site is rooted at the repository because its
  # changelog page snippet-includes the top-level CHANGELOG.md, and
  # `pymdownx.snippets` resolves against the directory mkdocs runs in. Only
  # `mkDocsSite`'s own arguments change -- the preset needs no second code
  # path for it, which is the point.
  repoRootedDocs = preset {
    docs = {
      root = ./.;
      fileset = lib.fileset.unions [
        ./docs-repo-rooted
        ./CHANGELOG.md
      ];
      mkdocsYmlName = "docs-repo-rooted/mkdocs.yml";
    };
  };

  # No `docs`, no `treefmt`: the outputs they would have produced must be
  # ABSENT, not empty or broken.
  bare = preset { };

  # Same generated `checks.default`, pointed at a suite that fails.
  failing = preset { runner = "run-tests-failing.lisp"; };

  extraMarker = pkgs.runCommand "forge-preset-extra-marker" { } ''
    mkdir -p "$out"
    echo added > "$out/added"
  '';

  # Both escape hatches, in the shapes the three real repositories need.
  hatches = preset {
    docs.root = ./docs;

    # ADD: cl-weave's ten artifact checks and cl-prolog's examples check are
    # this. A name that collided with a generated one would be rejected --
    # see the negative below.
    extraOutputs = _: {
      checks.artifact = extraMarker;
      packages.artifact = extraMarker;
    };

    # REPLACE: `checks.default` here wraps what it replaces rather than
    # discarding it, which is the reason the context carries `generated` at
    # all. `apps.default` is cl-weave's real case -- its default app is the
    # CLI, not the test runner the preset generates.
    overrideOutputs = ctx: {
      checks.default =
        pkgs.runCommand "forge-preset-overridden-default" { generated = ctx.generated.checks.default; }
          ''
            # The generated check really is reachable from the override: its
            # $out is the built source tree, run-tests.lisp included.
            test -f "$generated/run-tests.lisp"
            touch "$out"
          '';
      # `pkgs.hello` stands in for a delivered CLI. Only its metadata is
      # asserted below, so nothing here builds it.
      apps.default = cl.mkApp { drv = pkgs.hello; };
    };
  };

  # Never an output for an undeclared system. Only the KEY SETS are forced
  # below, so naming a system this host cannot build costs nothing.
  twoSystems = preset {
    systems = [
      "aarch64-darwin"
      "x86_64-linux"
    ];
  };

  # `tryEval` stops at weak head normal form, and a flake's outermost attrset
  # is already there. Every guard below is reached by forcing the merged
  # output set's KEY SET -- which is exactly what a name collision changes.
  checkNamesEvaluate =
    candidate: (builtins.tryEval (builtins.attrNames candidate.checks.${system})).success;
  packageVersionEvaluates =
    candidate: (builtins.tryEval candidate.packages.${system}.default.version).success;

  # Proving a BUILD failure takes care: a derivation that fails is not a check
  # that passes, and `tryEval` sees only evaluation errors. This runs the real
  # check phase verbatim in a subshell and passes only when it failed. The
  # `set +e` / bare-subshell / `$?` shape is load-bearing and the obvious
  # `( set -e; ... ) || status=$?` is wrong; examples/checks-and-coverage's
  # copy carries the full explanation, which is not repeated here so the two
  # cannot drift into disagreeing about it.
  expectCheckFailure =
    {
      check,
      name,
      statuses,
    }:
    check.overrideAttrs (old: {
      pname = name;
      checkPhase = ''
        set +e
        ( set -e
        ${old.checkPhase}
        )
        clNixForgeExpected=$?
        set -e
        echo "cl-nix-forge example: inner check exited $clNixForgeExpected"
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
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p "$out"
        runHook postInstall
      '';
    });
in
{
  packages.forge-preset = flake.packages.${system}.default;
  packages.forge-preset-docs = flake.packages.${system}.docs;
  packages.forge-preset-repo-rooted-docs = repoRootedDocs.packages.${system}.docs;

  devShells.forge-preset = flake.devShells.${system}.default;

  # The generated suite check, verbatim. Building it IS the assertion that
  # `checks.default` drives the package's own run-tests.lisp.
  checks.org-preset-generated-test = flake.checks.${system}.default;

  # ... and that it goes red when the suite does.
  checks.org-preset-generated-test-detects-failure = expectCheckFailure {
    check = failing.checks.${system}.default;
    name = "org-preset-generated-test-detects-failure";
    # run-tests-failing.lisp exits 1 through `uiop:quit`.
    statuses = [ 1 ];
  };

  checks.org-preset-generated-docs-check = flake.checks.${system}.docs;

  # The repo-rooted docs really read a file from outside docs/: the changelog
  # page is a snippet include, and `check_paths: true` in that site's
  # mkdocs.yml turns a missing target into a build failure rather than an
  # empty section.
  checks.org-preset-repo-rooted-docs =
    pkgs.runCommand "org-preset-repo-rooted-docs" { site = repoRootedDocs.packages.${system}.docs; }
      ''
        test -f "$site/index.html"
        grep -q FORGE-PRESET-CHANGELOG-MARKER "$site/changelog/index.html"
        touch "$out"
      '';

  # Absence, asserted as absence. A docs package that is merely broken, or a
  # `checks.docs` that trivially succeeds, would both slip past a test that
  # only looked at the instance which HAS docs.
  #
  # Paired with positive controls in the same check, for the reason
  # examples/simple-library states: an assertion whose subject is misspelled
  # fails identically to the defect under test.
  checks.org-preset-omits-undeclared-outputs =
    assert lib.assertMsg (builtins.hasAttr "docs"
      flake.packages.${system}
    ) "control failed: the docs-declaring instance has no packages.docs";
    assert lib.assertMsg (builtins.hasAttr "docs"
      flake.checks.${system}
    ) "control failed: the docs-declaring instance has no checks.docs";
    assert lib.assertMsg (builtins.hasAttr "formatting"
      flake.checks.${system}
    ) "control failed: the treefmt-declaring instance has no checks.formatting";
    assert lib.assertMsg (
      flake ? formatter
    ) "control failed: the treefmt-declaring instance has no formatter";
    assert lib.assertMsg (
      !(builtins.hasAttr "docs" bare.packages.${system})
    ) "a package declaring no docs still got packages.docs";
    assert lib.assertMsg (
      !(builtins.hasAttr "docs" bare.checks.${system})
    ) "a package declaring no docs still got checks.docs";
    assert lib.assertMsg (
      !(builtins.hasAttr "formatting" bare.checks.${system})
    ) "a package declaring no treefmt still got checks.formatting";
    assert lib.assertMsg (!(bare ? formatter)) "a package declaring no treefmt still got a formatter";
    pkgs.runCommand "org-preset-omits-undeclared-outputs" { } "touch $out";

  # `nix run .#test`, actually run -- and `apps.default` aliasing it, which is
  # what the org template declares.
  checks.org-preset-generated-test-app =
    assert lib.assertMsg (
      flake.apps.${system}.default.program == flake.apps.${system}.test.program
    ) "apps.default is not an alias of apps.test";
    pkgs.runCommand "org-preset-generated-test-app" { runner = flake.apps.${system}.test.program; } ''
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      "$runner"
      touch "$out"
    '';

  # ONE treefmt evaluation reaches both consumers, carrying the caller's own
  # module: `nix fmt` and the gate cannot be pointed at different rules.
  checks.org-preset-formatter-and-gate-share-one-treefmt-eval =
    pkgs.runCommand "org-preset-formatter-and-gate-share-one-treefmt-eval"
      {
        wrapper = flake.formatter.${system};
        gate = flake.checks.${system}.formatting;
      }
      ''
        test "$(cat "$wrapper/bin/treefmt")" = forge-preset-treefmt-marker
        test "$(cat "$gate")" = forge-preset-treefmt-marker
        touch "$out"
      '';

  # An added output and a replaced one, both built.
  checks.org-preset-extra-check = hatches.checks.${system}.artifact;

  checks.org-preset-overridden-check =
    assert lib.assertMsg (
      flake.checks.${system}.default.pname == "forge-preset-test"
    ) "control failed: the generated checks.default is not the one this override replaces";
    assert lib.assertMsg (
      hatches.apps.${system}.default.meta.mainProgram == "hello"
    ) "overrideOutputs did not replace apps.default";
    assert lib.assertMsg (
      hatches.apps.${system}.test.meta.mainProgram == "forge-preset-test"
    ) "overrideOutputs replaced apps.test as well as apps.default";
    assert lib.assertMsg (builtins.hasAttr "artifact"
      hatches.packages.${system}
    ) "extraOutputs did not add packages.artifact";
    hatches.checks.${system}.default;

  # A generated name and a caller-supplied name must never silently resolve
  # in favour of either one. Each `tryEval` below is paired with a positive
  # control that differs ONLY in the defect, because `tryEval` reports
  # `success` and never the message -- a typo in the subject would fail
  # exactly like the rejection under test.
  checks.org-preset-name-collisions-rejected =
    assert lib.assertMsg (checkNamesEvaluate (preset {
      extraOutputs = _: {
        checks.forge-preset-distinct = extraMarker;
      };
    })) "control failed: an extra check with an unused name was rejected";
    assert
      !(checkNamesEvaluate (preset {
        extraOutputs = _: {
          checks.default = extraMarker;
        };
      }));

    assert lib.assertMsg (checkNamesEvaluate (preset {
      overrideOutputs = _: {
        checks.default = extraMarker;
      };
    })) "control failed: overriding a generated check was rejected";
    assert
      !(checkNamesEvaluate (preset {
        overrideOutputs = _: {
          checks.no-such-generated-check = extraMarker;
        };
      }));

    # A misspelled output KIND is the same class of silent loss: `check`
    # instead of `checks` would otherwise be an attrset nothing ever reads.
    assert lib.assertMsg (checkNamesEvaluate (preset {
      extraOutputs = _: {
        checks = { };
      };
    })) "control failed: an empty `checks` addition was rejected";
    assert
      !(checkNamesEvaluate (preset {
        extraOutputs = _: {
          check = { };
        };
      }));
    pkgs.runCommand "org-preset-name-collisions-rejected" { } "touch $out";

  # The version reaches every derivation that carries one, from the .asd and
  # from nowhere else -- including the store path, which is the form a
  # release is actually inspected in.
  checks.org-preset-version-comes-from-the-asd =
    assert lib.assertMsg (
      flake.packages.${system}.default.version == "0.5.3"
    ) "the package version did not come from forge-preset.asd";
    assert lib.assertMsg (
      flake.packages.${system}.docs.version == "0.5.3"
    ) "the docs version did not come from forge-preset.asd";

    # ... and a hardcoded one is refused, which is the anti-pattern the org's
    # check-conformance.sh greps for. The control is the same call with a
    # different, permitted `packageArgs` entry.
    assert lib.assertMsg (packageVersionEvaluates (preset {
      packageArgs = _: { lispAsdPath = [ ]; };
    })) "control failed: a permitted packageArgs entry was rejected";
    assert
      !(packageVersionEvaluates (preset {
        packageArgs = _: { version = "9.9.9"; };
      }));
    assert
      !(builtins.tryEval
        (preset {
          docs = {
            root = ./docs;
            version = "9.9.9";
          };
        }).packages.${system}.docs.version
      ).success;

    pkgs.runCommand "org-preset-version-comes-from-the-asd" { src = flake.packages.${system}.default; }
      ''
        case "$src" in
          *-forge-preset-0.5.3) ;;
          *)
            echo "cl-nix-forge: package derivation is named $src" >&2
            exit 1
            ;;
        esac
        touch "$out"
      '';

  # `nix flake check --all-systems` fails with a platform mismatch, rather
  # than skipping, on a flake that advertises a platform no runner builds --
  # so the declared list must be the whole truth about which systems exist.
  checks.org-preset-emits-only-declared-systems =
    assert lib.assertMsg (
      builtins.attrNames flake.packages == [ system ]
    ) "packages was emitted for systems other than the declared one";
    assert lib.assertMsg (
      builtins.attrNames twoSystems.packages == [
        "aarch64-darwin"
        "x86_64-linux"
      ]
    ) "declaring two systems did not emit exactly those two";
    assert lib.assertMsg (
      builtins.attrNames twoSystems.checks == [
        "aarch64-darwin"
        "x86_64-linux"
      ]
    ) "checks did not follow the declared system list";
    assert lib.assertMsg (
      builtins.attrNames twoSystems.apps == [
        "aarch64-darwin"
        "x86_64-linux"
      ]
    ) "apps did not follow the declared system list";
    assert lib.assertMsg (
      builtins.attrNames twoSystems.devShells == [
        "aarch64-darwin"
        "x86_64-linux"
      ]
    ) "devShells did not follow the declared system list";
    assert lib.assertMsg (
      !(builtins.hasAttr "aarch64-linux" twoSystems.packages)
    ) "an undeclared system reached packages";
    pkgs.runCommand "org-preset-emits-only-declared-systems" { } "touch $out";

  # The generated overlay publishes the package under its own pname, and
  # nothing else -- `packages.docs` must not become `pkgs.docs`.
  checks.org-preset-generated-overlay =
    assert lib.assertMsg (
      !(builtins.hasAttr "docs" (pkgs.extend flake.overlays.default))
    ) "the generated overlay published packages.docs as pkgs.docs";
    pkgs.runCommand "org-preset-generated-overlay"
      { exposed = (pkgs.extend flake.overlays.default).forge-preset; }
      ''
        test -f "$exposed/run-tests.lisp"
        touch "$out"
      '';
}
