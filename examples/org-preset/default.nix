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
    # support/ is a SIBLING package that happens to live under this root, not
    # part of it. Excluding it is what makes the delivery checks below
    # meaningful: `forge-preset-support` is then reachable only as a
    # `lispDependencies` entry, never as a system ASDF stumbles over in the
    # package's own tree.
    sourceExclude = [ ./support ];
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

  # The dependency the delivered binary must carry. Built from its own root,
  # so its sources are in a store path of their own -- which is what the
  # `installSource` checks below need in order to tell "the image found the
  # tree shipped with it" apart from "the image found something".
  support = cl.lispDerivation {
    lispSystem = "forge-preset-support";
    version = cl.fromAsdSystem ./support/forge-preset-support.asd;
    src = cl.mkLispSource { root = ./support; };
  };

  # THE case the `executable` argument exists for. Everything the delivery
  # needs -- pname, version, src, meta and the `lispDependencies` entry --
  # comes from the preset's own resolved arguments; the only things spelled
  # here are the ones genuinely specific to the binary.
  #
  # `lispSystem` is overridden because this package's CLI is a separate ASDF
  # system (cl-prolog's and cl-json-kit's shape); cl-weave's, where the
  # exported system delivers itself, needs no override at all and is covered
  # by the round-trip instance below.
  withCli = preset {
    docs.root = ./docs;
    lispDependencies = _: [ support ];
    executable = {
      pname = "forge-preset-cli";
      lispSystem = "forge-preset-cli";
      dynamicSpaceSize = 2048;
      installSource = true;
    };
  };

  cliProgram = withCli.apps.${system}.default.program;

  # No `installSource`, everything else identical: the negative control for
  # the layout assertions. Without it, a check asserting the delivered tree
  # exists would pass just as well against a `mkExecutable` that installed
  # sources unconditionally -- which is a different, unrequested contract.
  # The `pname` deliberately MATCHES the instance above, so the two
  # deliveries share one compile of `forge-preset-cli` and differ only in the
  # delivery step under test.
  withCliNoSource = preset {
    lispDependencies = _: [ support ];
    executable = {
      pname = "forge-preset-cli";
      lispSystem = "forge-preset-cli";
      dynamicSpaceSize = 2048;
    };
  };

  # `ctx.lispDerivationArgs` handed straight back to `mkExecutable`, with
  # NOTHING overridden -- the escape hatch a caller falls back to when the
  # `executable` argument cannot express their delivery. If this stops being
  # a complete `lispDerivation` argument set, this call stops building.
  roundTripped =
    (preset {
      extraOutputs = ctx: {
        packages.round-tripped = ctx.cl.mkExecutable {
          args = ctx.lispDerivationArgs;
          installSource = true;
        };
      };
    }).packages.${system}.round-tripped;

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

  # `.outPath`, where the helper above reads `.version`, and the difference is
  # load-bearing: `mkDerivation` attaches `version` to the RESULT rather than
  # to the derivation, so reading it forces the attrset (and any `assert`
  # guarding it) but not the build script. A guard that lives inside the
  # script -- `mkExecutable`'s duplicate-source-directory check does -- is
  # only reached by forcing the store path. Reading `.version` instead
  # reports success and proves nothing, which is how this was found.
  packagePathEvaluates =
    candidate: (builtins.tryEval candidate.packages.${system}.default.outPath).success;

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
  packages.forge-preset-cli = withCli.packages.${system}.default;

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

  # D-1. The defect: `mkPackageFlake` computed the package's `lispDerivation`
  # arguments and exposed only the RESULT, so a caller delivering a CLI from
  # `overrideOutputs` had to re-spell pname, version, src, meta -- and every
  # `lispDependencies` entry. Forgetting the last of those produces a binary
  # that is simply missing a dependency, with nothing to notice it.
  #
  # So the assertion is not "a binary was produced" but "the binary can USE a
  # dependency that was declared once, on the `mkPackageFlake` call". It runs
  # from a scratch directory, because a run inside the source tree could
  # resolve `forge-preset-support` from the working directory and prove
  # nothing.
  checks.org-preset-executable-carries-dependencies =
    pkgs.runCommand "org-preset-executable-carries-dependencies" { cli = cliProgram; }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME" "$TMPDIR/elsewhere"
        cd "$TMPDIR/elsewhere"

        # Matched by PREFIX, never by line number: the image compiles a system
        # on this path, and a compiler note on stdout would otherwise shift
        # every assertion by a line.
        "$cli" > output
        cat output
        grep -qx "support=FORGE-PRESET-SUPPORT-REACHED-THE-IMAGE" output
        grep -qx "preset=forge-preset builds images" output
        touch "$out"
      '';

  # D-2. A delivered image could not find the sources shipped with it,
  # because nothing shipped any: `mkExecutable` published `$out/bin` and, on
  # the Darwin fallback, a core in an intermediate derivation no consumer
  # could name. The image's own discovery therefore fell through to the
  # build-time source directory and the binary died on the first system it
  # re-loaded.
  #
  # Three things are asserted, and all three are needed. The LAYOUT, because
  # that is the written contract. The RUN, from a directory that is not the
  # source tree, because the layout existing does not mean the image can
  # anchor on it -- and on a Darwin host the image is a bare `.core`, i.e.
  # the delivery path where `$out` is not what the image sees at all. And the
  # NEGATIVE control: the same binary delivered without `installSource` must
  # fail, or the run above would pass against any image that found sources
  # some other way.
  checks.org-preset-executable-installs-its-own-sources =
    pkgs.runCommand "org-preset-executable-installs-its-own-sources"
      {
        cli = cliProgram;
        delivered = withCli.packages.${system}.default;
        bare = withCliNoSource.packages.${system}.default;
        supportSrc = support;
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME" "$TMPDIR/elsewhere"

        installed="$delivered/share/common-lisp/source"
        # The delivered system's own tree...
        test -f "$installed/forge-preset-cli/forge-preset.asd"
        test -f "$installed/forge-preset-cli/forge-preset-runtime.asd"
        # ... and its whole resolved dependency closure, each in a directory
        # of its own. A system whose sources are findable but whose
        # dependencies' are not fails one `asdf:load-system` later, which is
        # the same bug with a longer fuse.
        test -f "$installed/forge-preset-support/forge-preset-support.asd"

        # Nothing installed unless asked.
        test ! -e "$bare/share/common-lisp"

        cd "$TMPDIR/elsewhere"
        "$cli" > output
        cat output

        # The image anchored on a real installed prefix -- not on the build
        # sandbox its ASDF configuration was frozen with, which is exactly
        # what the last-resort fallback would have returned. Matched by
        # PREFIX, never by line number: the image compiles a system on this
        # path, and a compiler note on stdout would shift every line.
        root="$(sed -n 's/^source-root=//p' output)"
        case "$root" in
          /nix/store/*/share/common-lisp/source/) ;;
          *)
            echo "cl-nix-forge example: image resolved its source root to $root" >&2
            exit 1
            ;;
        esac
        test -f "$root/forge-preset-cli/forge-preset.asd"

        # ... and really loaded a system out of it: `forge-preset-runtime` is
        # in no image, and pulls in both the delivered tree and the separate
        # store path the dependency's sources were installed from.
        grep -qx "runtime=FORGE-PRESET-SUPPORT-REACHED-THE-IMAGE|forge-preset builds a system loaded at run time" output

        # The negative control, run last so its failure cannot be mistaken
        # for one of the assertions above.
        if "$bare/bin/forge-preset-cli" > bare-output 2>&1; then
          echo "cl-nix-forge example: a delivery without installSource still found a source tree" >&2
          cat bare-output >&2
          exit 1
        fi
        grep -q "no source tree installed beside this image" bare-output

        touch "$out"
      '';

  # The escape hatch, kept honest: the resolved argument attrset really is a
  # complete `lispDerivation` call, so a caller whose delivery the
  # `executable` argument cannot express still spells the package's identity
  # exactly once. Nothing is overridden here -- if `ctx.lispDerivationArgs`
  # lost an entry, this would stop building rather than quietly deliver
  # something different.
  #
  # D-3 rides along: the delivered store path carries the version from the
  # .asd, where `runCommand outputName` used to drop it and leave two
  # releases indistinguishable by path.
  checks.org-preset-executable-round-trips-package-args =
    assert lib.assertMsg (
      roundTripped.version == "0.5.3"
    ) "the delivered executable did not carry the .asd's version";
    assert lib.assertMsg (
      roundTripped.pname == "forge-preset"
    ) "the delivered executable did not carry the package's pname";
    pkgs.runCommand "org-preset-executable-round-trips-package-args"
      {
        delivered = roundTripped;
        cli = withCli.packages.${system}.default;
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME" "$TMPDIR/elsewhere"
        cd "$TMPDIR/elsewhere"

        test "$("$delivered/bin/forge-preset")" = "forge-preset builds a delivered image"

        for path in "$delivered" "$cli"; do
          case "$path" in
            *-forge-preset-0.5.3|*-forge-preset-cli-0.5.3) ;;
            *)
              echo "cl-nix-forge example: delivered executable is named $path" >&2
              exit 1
              ;;
          esac
        done
        touch "$out"
      '';

  # Where the delivery lands in the output table, and what it does NOT
  # displace. Every assertion is paired with the same fact on the instance
  # that declares no `executable`, because a preset that ignored the argument
  # and one that always delivered would each satisfy half of this.
  checks.org-preset-executable-output-wiring =
    assert lib.assertMsg (
      withCli.packages.${system}.default.meta.mainProgram == "forge-preset-cli"
    ) "packages.default is not the delivered executable";
    assert lib.assertMsg (
      bare.packages.${system}.default.pname == "forge-preset"
    ) "control failed: without `executable`, packages.default is not the ASDF system";

    # The library is still exported under its own name -- that is the entry a
    # downstream `lispDependencies` needs, and delivering a binary must not
    # take it away.
    assert lib.assertMsg (
      withCli.packages.${system}.forge-preset.pname == "forge-preset"
    ) "packages.<pname> is no longer the ASDF system";

    assert lib.assertMsg (
      withCli.apps.${system}.default.program == withCli.apps.${system}.forge-preset.program
    ) "apps.<pname> is not the same CLI as apps.default";
    assert lib.assertMsg (
      withCli.apps.${system}.default.meta.mainProgram == "forge-preset-cli"
    ) "apps.default is not the delivered CLI";
    assert lib.assertMsg (
      withCli.apps.${system}.test.meta.mainProgram == "forge-preset-test"
    ) "the delivery replaced apps.test as well as apps.default";
    assert lib.assertMsg (
      bare.apps.${system}.default.program == bare.apps.${system}.test.program
    ) "control failed: without `executable`, apps.default is not apps.test";
    assert lib.assertMsg (
      !(builtins.hasAttr "forge-preset" bare.apps.${system})
    ) "a package declaring no executable still got apps.<pname>";

    # ctx.executable is the delivered binary itself, so the several
    # `ctx -> ...` functions that need it (an override for packages.default,
    # an extra check's argv) name one value instead of each rebuilding it
    # from identical arguments and trusting that to be the same derivation.
    assert lib.assertMsg (
      (preset {
        lispDependencies = _: [ support ];
        executable = {
          pname = "forge-preset-cli";
          lispSystem = "forge-preset-cli";
          dynamicSpaceSize = 2048;
        };
        extraOutputs = ctx: {
          checks.ctx-executable = ctx.executable;
        };
      }).checks.${system}.ctx-executable == withCliNoSource.packages.${system}.default
    ) "ctx.executable is not the derivation the preset delivered";
    assert lib.assertMsg (
      (preset { extraOutputs = ctx: { checks.ctx-executable = ctx.package; }; })
      .checks.${system}.ctx-executable == bare.packages.${system}.default
    ) "control failed: an unmodified extraOutputs check did not round trip";

    pkgs.runCommand "org-preset-executable-output-wiring" { } "touch $out";

  # Two ways to ask for a delivery that cannot mean what it says, each paired
  # with a positive control -- `tryEval` reports `success` and never the
  # message, so a misspelled subject fails exactly like the defect.
  checks.org-preset-executable-argument-guards =
    assert lib.assertMsg (packageVersionEvaluates (preset {
      executable = {
        lispSystem = "forge-preset-cli";
        dynamicSpaceSize = 2048;
      };
    })) "control failed: a well-formed `executable` was rejected";

    # `executable.args` would REPLACE the computed attrset wholesale, which is
    # the defect itself wearing the fix's clothes: a re-spelled `args` is once
    # again free to omit `lispDependencies`.
    assert
      !(packageVersionEvaluates (preset {
        executable = {
          args = {
            pname = "smuggled";
            lispSystem = "forge-preset-cli";
            src = ./.;
          };
        };
      }));

    # `installSource` gives each shipped tree a directory named after its
    # package, so a delivery whose name collides with one of its own
    # dependencies would otherwise install one of them over the other.
    assert lib.assertMsg (packagePathEvaluates (preset {
      lispDependencies = _: [ support ];
      executable = {
        pname = "forge-preset-cli";
        lispSystem = "forge-preset-cli";
        installSource = true;
      };
    })) "control failed: a non-colliding installSource delivery was rejected";
    assert
      !(packagePathEvaluates (preset {
        lispDependencies = _: [ support ];
        executable = {
          pname = "forge-preset-support";
          lispSystem = "forge-preset-cli";
          installSource = true;
        };
      }));
    pkgs.runCommand "org-preset-executable-argument-guards" { } "touch $out";

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
