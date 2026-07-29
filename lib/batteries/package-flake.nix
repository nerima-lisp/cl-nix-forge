# The nerima-lisp org flake preset: one call that returns a whole package's
# flake output set.
#
# `lib` only, no `pkgs`: this is the one function in the library that spans
# systems rather than living inside one. `lib/default.nix` instantiates every
# other module for a single `pkgs`, and a preset that produced
# `packages.<system>` from a single-system instantiation could only ever emit
# the system it happened to be instantiated for. So it takes `systems` and
# obtains a `pkgs` -- and a cl-nix-forge -- per declared system itself.
{ lib, ... }:
let
  # The flake output kinds this preset generates per declared system, and
  # therefore the only kinds `extraOutputs`/`overrideOutputs` may name.
  # `formatter` and `overlays` are deliberately absent: `formatter` is a
  # single value per system (there is nothing to merge into) and `overlays`
  # is not per-system at all, so both are configured by argument (`treefmt`,
  # `overlayPackages`) rather than by the escape hatch. Naming one of them in
  # the escape hatch is an error that says so, instead of a value that
  # silently goes nowhere.
  outputKinds = [
    "packages"
    "checks"
    "apps"
    "devShells"
  ];

  # PACKAGE_STANDARD.md scopes treefmt to Nix and only Nix: a YAML formatter
  # mangles the GitHub Actions `on:` key (it is the boolean `true` to a YAML
  # 1.1 parser) and reformatting Markdown churns an entire docs tree for no
  # reviewable gain. Overridable via `treefmt.module`, but the default is the
  # standard's answer so a conforming package configures nothing.
  defaultTreefmtModule = {
    projectRootFile = "flake.nix";
    programs.nixfmt.enable = true;
  };

  # `lispDerivation` arguments this preset computes from its own dedicated
  # arguments. Passing one of them again through `packageArgs` would mean two
  # sources of truth for the same value, with the escape hatch silently
  # winning -- and for `version` specifically that is exactly the hardcoded
  # version string the org's check-conformance.sh greps for. Rejected by
  # name, so the caller is pointed at the dedicated argument instead.
  #
  # `lispSystems` is on the list without a dedicated argument of its own,
  # because PACKAGE_STANDARD.md's shape is one exported system per repository
  # (plus its `<pkg>/test` sibling). A repository that really exports several
  # builds the extras with `lispMultiDerivation` and adds them through
  # `extraOutputs`, rather than having this preset grow a second, untested
  # naming scheme for `packages.<system>`.
  ownedPackageArgs = [
    "pname"
    "version"
    "src"
    "meta"
    "lispSystem"
    "lispSystems"
    "lisp"
    "lispDependencies"
    "lispCheckDependencies"
    "doCheck"
  ];

  # Same rule for the docs site: its version is the .asd's, full stop.
  # `pname` and `meta` are NOT owned here -- a docs site legitimately carries
  # its own name and description, and `mkDocsSite` already takes both.
  ownedDocsArgs = [ "version" ];

  rejectOwned =
    {
      pname,
      argument,
      owned,
      given,
    }:
    let
      clash = lib.intersectLists owned (builtins.attrNames given);
    in
    lib.assertMsg (clash == [ ])
      "cl-nix-forge mkPackageFlake (${pname}): `${argument}` may not set ${
        lib.concatMapStringsSep ", " (name: "`${name}`") clash
      } -- mkPackageFlake computes ${
        if builtins.elem "version" clash then
          "it (the version comes from the .asd and nowhere else)"
        else
          "them"
      } from its own arguments. Use the corresponding mkPackageFlake argument.";

  # Merge one output kind's generated attrset with the caller's additions and
  # overrides, failing loudly on either kind of mistake.
  #
  # Two channels rather than one overlay-style `final: prev:` function,
  # because a single channel cannot express intent and therefore cannot check
  # it. `extraOutputs` says "this name is new": colliding with a generated
  # name is an error, so a preset that grows a new generated check later
  # cannot silently shadow a caller's check of the same name (or be shadowed
  # by it -- which of the two happens would otherwise depend on `//` order,
  # i.e. on nothing the caller can see). `overrideOutputs` says "this name
  # already exists": naming something that was never generated is an error,
  # so a typo in an override is a build failure rather than a quietly
  # inert extra output that nobody notices until the thing it was meant to
  # replace ships unmodified. This mirrors flake.nix's own treatment of
  # duplicate example outputs.
  mergeKind =
    {
      pname,
      system,
      kind,
      generated,
      extras,
      overrides,
    }:
    let
      generatedNames = builtins.attrNames generated;
      collisions = lib.intersectLists generatedNames (builtins.attrNames extras);
      unknownOverrides = lib.subtractLists generatedNames (builtins.attrNames overrides);
    in
    assert lib.assertMsg (collisions == [ ])
      "cl-nix-forge mkPackageFlake (${pname}, ${system}): `extraOutputs` would shadow generated ${kind}: ${lib.concatStringsSep ", " collisions}. Move ${
        if builtins.length collisions == 1 then "it" else "them"
      } to `overrideOutputs` to replace the generated output, or pick another name to add alongside it.";
    assert lib.assertMsg (unknownOverrides == [ ])
      "cl-nix-forge mkPackageFlake (${pname}, ${system}): `overrideOutputs` names ${kind} that this preset does not generate: ${lib.concatStringsSep ", " unknownOverrides}. Generated ${kind}: ${
        if generatedNames == [ ] then "(none)" else lib.concatStringsSep ", " generatedNames
      }. Use `extraOutputs` to add a new output.";
    generated // extras // overrides;

  assertOutputShape =
    {
      pname,
      argument,
      value,
    }:
    let
      unknown = lib.subtractLists outputKinds (builtins.attrNames value);
    in
    assert lib.assertMsg (builtins.isAttrs value)
      "cl-nix-forge mkPackageFlake (${pname}): `${argument}` must return an attrset of output kinds";
    assert lib.assertMsg (unknown == [ ])
      "cl-nix-forge mkPackageFlake (${pname}): `${argument}` returned unknown output kind(s): ${lib.concatStringsSep ", " unknown}. Only ${lib.concatStringsSep ", " outputKinds} can be extended per system; `formatter` is configured with `treefmt` and `overlays` with `overlayPackages`.";
    value;
in
{
  # Everything a nerima-lisp package's flake.nix declares, as one call.
  #
  # PACKAGE_STANDARD.md distributes the org standard as a *template* --
  # templates/flake.nix, copied by hand into 21 repositories. The result is
  # that every repository re-derives the same `.asd` version extraction, the
  # same `forAllSystems`, the same treefmt eval wired to both `formatter` and
  # `checks.formatting`, the same mkdocs package plus docs check, the same
  # run-tests.lisp check, the same `apps.test`/`apps.default` pair and the
  # same devShell -- and drifts. cl-json-kit's copy is 199 lines, cl-prolog's
  # 357, cl-weave's 516, and cl-prolog's `:version` regex has already diverged
  # from the identical one the other two still share. This function is the
  # standard as a function call, so the copies converge by construction.
  #
  # It generates exactly PACKAGE_STANDARD.md's required-output table and
  # nothing else:
  #
  #   packages.<pname>   the ASDF system, via `lispDerivation`
  #   packages.default   an alias for it
  #   packages.docs      the mkdocs-material site (only when `docs != null`)
  #   checks.default     run-tests.lisp, via `mkScriptCheck`
  #   checks.formatting  the treefmt gate (only when `treefmt != null`)
  #   checks.docs        proves the --strict docs build (only when `docs != null`)
  #   apps.test          `nix run .#test`, via `mkTestApp`
  #   apps.default       an alias for it
  #   devShells.default  via `mkDevShell`
  #   formatter          the same treefmt eval `checks.formatting` uses
  #   overlays.default   via `mkOverlay` (unless `overlayPackages = [ ]`)
  #
  # Anything beyond that table is the caller's, through `extraOutputs` and
  # `overrideOutputs` -- and every real package has something: cl-weave has
  # ten artifact checks and a CLI binary, cl-prolog a coverage package plus
  # examples and app-test checks, cl-json-kit a benchmark devShell built with
  # `sbcl.withPackages`.
  #
  # There is no flake-parts and no flake-utils here, per PACKAGE_STANDARD.md;
  # `systems` is iterated with `lib.genAttrs`, so an output for a system the
  # caller did not declare cannot exist. That matters more than it looks:
  # `nix flake check --all-systems` on a flake advertising a platform no
  # runner can build fails with a platform mismatch rather than skipping it.
  #
  # Arguments (`ctx` marks a function of the context record described below):
  #
  #   self        -- the flake's own `self`. Used unfiltered for the treefmt
  #                  gate (which must see every tracked file, not just Lisp
  #                  source) and as the default `root`.
  #   pname       -- the package name. Names `packages.<pname>`, the
  #                  derivation, the test runner and the docs site.
  #   asd         -- path to the `.asd`. The ONLY place a version comes from;
  #                  there is deliberately no `version` argument.
  #   systems     -- [ String ]. Declared platforms, and only those.
  #   lispSystem  -- String ? pname. The ASDF system name, when it differs.
  #   meta        -- attrs ? { }. The package's meta; also the docs site's,
  #                  minus `mainProgram` and with a docs description.
  #
  #   nixpkgs     -- the caller's nixpkgs flake input. Used only by the
  #                  default `pkgsFor`.
  #   pkgsFor     -- system -> pkgs ? `import nixpkgs { inherit system; }`.
  #                  `import`, not `legacyPackages`, so a caller who needs
  #                  `config`/`overlays` overrides them in one place.
  #   forgeFor    -- system -> this library, instantiated for that system.
  #                  Overridable so a caller (and this repo's own
  #                  `examples/`, which IS its test suite) can hand in an
  #                  instance it already has rather than have the preset
  #                  quietly test a second, re-imported copy.
  #
  #   root        -- path ? self. What `mkLispSource` filters.
  #   sourceInclude / sourceExclude -- `mkLispSource`'s escape hatches.
  #   src         -- ? null. A ready-made source, bypassing `mkLispSource`
  #                  entirely, for a repository that cannot use an allowlist.
  #
  #   lisp                  -- ctx -> derivation ? `pkgs.sbcl`.
  #   lispDependencies      -- ctx -> [ derivation ] ? [ ]. Sibling packages
  #   lispCheckDependencies -- ctx -> [ derivation ] ? [ ]. as ALREADY-BUILT
  #                  derivations (`cl-weave.packages.${system}.default`),
  #                  never registry strings: building CL_SOURCE_REGISTRY is
  #                  `lispDerivation`'s job and it does it transitively.
  #                  Functions of `ctx` because a derivation is per-system
  #                  and the preset spans systems.
  #   packageArgs -- ctx -> attrs ? { }. Extra `lispDerivation` arguments
  #                  (`lispAsdPath`, `nativeLibraries`, `buildInputs`, ...).
  #
  #   runner          -- String ? "run-tests.lisp", the org-standard entry
  #                      point. Drives both `checks.default` and `apps.test`,
  #                      so the command a contributor runs by hand and the
  #                      gate CI runs cannot drift apart.
  #   timeoutSeconds  -- Int ? 600, killAfterSeconds :: Int ? 30.
  #
  #   docs        -- attrs ? null. `mkDocsSite` arguments; `null` omits the
  #                  docs package AND its check entirely. `{ root = ./docs; }`
  #                  is the common case (cl-prolog, cl-json-kit); a repo
  #                  whose changelog page snippet-includes the top-level
  #                  CHANGELOG.md (cl-weave) passes `root = ./.` with a
  #                  `fileset` and `mkdocsYmlName = "docs/mkdocs.yml"`.
  #                  `pname` and `version` are filled in for both.
  #   treefmt     -- { evalModule, module ? <nix-only default> } ? null.
  #                  `evalModule` is `treefmt-nix.lib.evalModule`, taken as an
  #                  argument rather than closed over: cl-nix-forge's own
  #                  treefmt-nix input pins a version its consumers did not
  #                  choose. Evaluated ONCE per system and used for both
  #                  `formatter` and `checks.formatting`, which is the whole
  #                  point -- `nix fmt` and the CI gate cannot then disagree
  #                  about what "formatted" means.
  #
  #   devShellPackages -- ctx -> [ derivation ] ? [ ]. `mkDevShell`'s
  #                  `extraPackages`.
  #   overlayPackages  -- [ String ] ? [ "default" ]. Which `packages.<system>`
  #                  entries `overlays.default` publishes; `[ ]` omits the
  #                  overlay. Not "all of them": `packages.docs` must not
  #                  become `pkgs.docs`.
  #
  #   extraOutputs    -- ctx -> { packages?, checks?, apps?, devShells? } ? { }
  #                  Add-only. A name that collides with a generated one is
  #                  an evaluation error.
  #   overrideOutputs -- ctx -> { packages?, checks?, apps?, devShells? } ? { }
  #                  Replace-only. A name that was not generated is an
  #                  evaluation error.
  #
  # ctx :: { system, pkgs, cl, version, src } for the arguments that feed the
  # package's own construction, plus { package, docs, generated } for the
  # ones evaluated after it exists (`devShellPackages`, `extraOutputs`,
  # `overrideOutputs`). `generated` is this preset's own output set for that
  # system, so an override can wrap what it replaces
  # (`generated.checks.default.overrideAttrs ...`) instead of rebuilding it.
  mkPackageFlake =
    {
      self,
      pname,
      asd,
      systems,
      lispSystem ? pname,
      meta ? { },

      nixpkgs ? null,
      pkgsFor ?
        system:
        if nixpkgs == null then
          throw "cl-nix-forge mkPackageFlake (${pname}): pass `nixpkgs` (your flake's nixpkgs input) or a `pkgsFor` of your own"
        else
          import nixpkgs { inherit system; },
      forgeFor ?
        system:
        let
          systemPkgs = pkgsFor system;
        in
        import ../default.nix {
          inherit (systemPkgs) lib;
          pkgs = systemPkgs;
        },

      root ? self,
      src ? null,
      sourceInclude ? [ ],
      sourceExclude ? [ ],

      lisp ? ctx: ctx.pkgs.sbcl,
      lispDependencies ? _: [ ],
      lispCheckDependencies ? _: [ ],
      packageArgs ? _: { },

      runner ? "run-tests.lisp",
      timeoutSeconds ? 600,
      killAfterSeconds ? 30,

      docs ? null,
      treefmt ? null,

      devShellPackages ? _: [ ],
      overlayPackages ? [ "default" ],

      extraOutputs ? _: { },
      overrideOutputs ? _: { },
    }:
    let
      forSystem =
        system:
        let
          pkgs = pkgsFor system;
          cl = forgeFor system;

          # The single source of truth for the version, on every path that
          # carries one: the derivation, the docs site, and the store paths
          # of both. A release edits the .asd and nothing else.
          version = cl.fromAsdSystem asd;

          resolvedSrc =
            if src != null then
              src
            else
              cl.mkLispSource {
                inherit root;
                include = sourceInclude;
                exclude = sourceExclude;
              };

          # The context the package's own inputs are computed from. It
          # deliberately does NOT carry `package`: these values are what
          # `package` is built from, and including it would be a cycle.
          baseContext = {
            inherit
              system
              pkgs
              cl
              version
              ;
            src = resolvedSrc;
          };

          resolvedLisp = lisp baseContext;
          resolvedDependencies = lispDependencies baseContext;
          resolvedCheckDependencies = lispCheckDependencies baseContext;
          resolvedPackageArgs = packageArgs baseContext;

          package =
            assert rejectOwned {
              inherit pname;
              argument = "packageArgs";
              owned = ownedPackageArgs;
              given = resolvedPackageArgs;
            };
            cl.lispDerivation (
              {
                inherit
                  pname
                  version
                  lispSystem
                  meta
                  ;
                src = resolvedSrc;
                lisp = resolvedLisp;
                lispDependencies = resolvedDependencies;
                lispCheckDependencies = resolvedCheckDependencies;
              }
              // resolvedPackageArgs
            );

          docsSite =
            if docs == null then
              null
            else
              assert rejectOwned {
                inherit pname;
                argument = "docs";
                owned = ownedDocsArgs;
                given = docs;
              };
              cl.mkDocsSite (
                {
                  pname = "${pname}-docs";
                  # The package's own meta, minus `mainProgram` -- a rendered
                  # site has no binary to name, and inheriting one makes
                  # `lib.getExe` on the docs package resolve to a path that
                  # does not exist.
                  meta = (removeAttrs meta [ "mainProgram" ]) // {
                    description = "Rendered MkDocs (Material) documentation for ${pname}";
                  };
                }
                // docs
                // {
                  inherit version;
                }
              );

          # ONE evaluation, two consumers. Keeping this in the per-system
          # `let` rather than recomputing it at each use site is what
          # guarantees `nix fmt` and `checks.formatting` run the same
          # formatter over the same file set.
          treefmtEval =
            if treefmt == null then
              null
            else if !(treefmt ? evalModule) then
              throw "cl-nix-forge mkPackageFlake (${pname}): `treefmt` needs `evalModule` (pass `treefmt-nix.lib.evalModule`)"
            else
              treefmt.evalModule pkgs (treefmt.module or defaultTreefmtModule);

          # `mkScriptCheck`, not `mkTestCheck`: the org standard's entry
          # point is run-tests.lisp, and a package whose suite tests its own
          # ASDF integration is untestable through an enclosing
          # `asdf:test-system` by construction (see core/script-check.nix).
          # The check inherits the derivation's resolved registry, so
          # `lispCheckDependencies` are on it without being named twice.
          testCheck = cl.mkScriptCheck {
            drv = package;
            entryPoint = runner;
            name = "${pname}-test";
            inherit timeoutSeconds killAfterSeconds;
          };

          # The same runner as a `nix run .#test`. Check dependencies are
          # concatenated here because `mkTestApp` has no doCheck phase to
          # distinguish them by -- the suite needs its test framework on the
          # registry whichever way it is started.
          testApp = cl.mkTestApp {
            inherit
              pname
              runner
              timeoutSeconds
              killAfterSeconds
              ;
            src = resolvedSrc;
            lisp = resolvedLisp;
            lispDependencies = resolvedDependencies ++ resolvedCheckDependencies;
          };

          # `mkDocsSite` already builds with `--strict`, so a broken link or
          # a page missing from the nav fails before this. The extra
          # assertion catches the other half: a --strict build that succeeded
          # while emitting nothing. cl-prolog wrote this by hand; cl-json-kit
          # and cl-weave re-exported the package and did not.
          docsCheck =
            if docsSite == null then
              null
            else
              pkgs.runCommand "${pname}-docs-check" { site = docsSite; } ''
                test -f "$site/index.html"
                touch "$out"
              '';

          generated = {
            packages = {
              default = package;
              ${pname} = package;
            }
            // lib.optionalAttrs (docsSite != null) { docs = docsSite; };

            checks = {
              default = testCheck;
            }
            // lib.optionalAttrs (docsCheck != null) { docs = docsCheck; }
            // lib.optionalAttrs (treefmtEval != null) {
              formatting = treefmtEval.config.build.check self;
            };

            apps = {
              test = testApp;
              default = testApp;
            };

            devShells.default = cl.mkDevShell {
              drv = package;
              extraPackages = devShellPackages packageContext;
            };
          };

          packageContext = baseContext // {
            inherit package;
            docs = docsSite;
          };

          outputContext = packageContext // {
            inherit generated;
          };

          extras = assertOutputShape {
            inherit pname;
            argument = "extraOutputs";
            value = extraOutputs outputContext;
          };

          overrides = assertOutputShape {
            inherit pname;
            argument = "overrideOutputs";
            value = overrideOutputs outputContext;
          };
        in
        {
          outputs = lib.genAttrs outputKinds (
            kind:
            mergeKind {
              inherit pname system kind;
              generated = generated.${kind};
              extras = extras.${kind} or { };
              overrides = overrides.${kind} or { };
            }
          );

          formatter = if treefmtEval == null then null else treefmtEval.config.build.wrapper;

          inherit cl;
        };

      # `lib.genAttrs`, not `flake-utils.eachDefaultSystem`: the caller's
      # list is the whole truth about which platforms exist here.
      perSystem =
        assert lib.assertMsg (
          builtins.isList systems && systems != [ ]
        ) "cl-nix-forge mkPackageFlake (${pname}): `systems` must be a non-empty list of system strings";
        lib.genAttrs systems forSystem;

      packages = lib.mapAttrs (_: entry: entry.outputs.packages) perSystem;
    in
    {
      inherit packages;
      checks = lib.mapAttrs (_: entry: entry.outputs.checks) perSystem;
      apps = lib.mapAttrs (_: entry: entry.outputs.apps) perSystem;
      devShells = lib.mapAttrs (_: entry: entry.outputs.devShells) perSystem;
    }
    // lib.optionalAttrs (treefmt != null) {
      formatter = lib.mapAttrs (_: entry: entry.formatter) perSystem;
    }
    // lib.optionalAttrs (overlayPackages != [ ]) {
      # Built from any one system's instantiation on purpose: `mkOverlay`
      # resolves the system from `prev` when the overlay is APPLIED, so the
      # instance it was created from contributes nothing but `lib`. Taking
      # the head avoids forcing a second nixpkgs import that the flake would
      # otherwise never need.
      overlays.default = (perSystem.${lib.head systems}).cl.mkOverlay {
        inherit packages;
        names = overlayPackages;
      };
    };
}
