{ lib }:
let
  version = import ./version.nix { inherit lib; };
  # Nix is lazy, so the argument is still an unforced thunk here and the throw
  # happens inside tryEval's dynamic extent.
  assertFails = expression: !(builtins.tryEval expression).success;
  # `asdSystemDependencies` returns attrsets whose VALUES may be unforced
  # throws -- that is how a malformed `:depends-on` stays out of
  # `fromAsdSystem`'s way. `==` on the whole attrset forces every value, so
  # `assertFails` on a comparison is what actually exercises the poison; the
  # bare call would succeed without ever touching it. `deepSeq` says so
  # explicitly at the sites that only care that it blows up.
  assertDependenciesFail =
    arguments: assertFails (builtins.deepSeq (version.asdSystemDependencies arguments) null);
  # Fixtures with no reader conditional answer the same for every feature
  # list, so they are asked with the emptiest one there is. Naming it keeps
  # the fixtures that DO depend on the implementation visually distinct.
  noFeatures = [ ];
in
{
  # -- fromAsdSystem: operator spellings ------------------------------------
  uppercaseDefsystemAndVersion =
    version.fromAsdSystem ./version-test-fixtures/uppercase.asd == "1.2.3";
  bareDefsystem = version.fromAsdSystem ./version-test-fixtures/bare-defsystem.asd == "1.0";
  qualifiedDefsystem =
    version.fromAsdSystem ./version-test-fixtures/qualified-defsystem.asd == "3.1.4";

  # -- fromAsdSystem: what counts as the system's own version ---------------
  commentsAreIgnored = version.fromAsdSystem ./version-test-fixtures/comments.asd == "2.3.4";
  componentVersionIsIgnored =
    version.fromAsdSystem ./version-test-fixtures/nested-version.asd == "5.0.0";
  versionlessSiblingIsIgnored =
    version.fromAsdSystem ./version-test-fixtures/versionless-system.asd == "7.0.0";

  # -- fromAsdSystem: agreement vs. drift -----------------------------------
  # The cl-prolog shape: several defsystems, one repeated version.
  agreeingVersionsAreAccepted =
    version.fromAsdSystem ./version-test-fixtures/agreeing-versions.asd == "1.1.0";
  conflictingVersionsFail = assertFails (
    version.fromAsdSystem ./version-test-fixtures/conflicting-versions.asd
  );
  noDefsystem = assertFails (version.fromAsdSystem ./version-test-fixtures/no-defsystem.asd);
  nonLiteralVersion = assertFails (
    version.fromAsdSystem ./version-test-fixtures/non-literal-version.asd
  );

  # -- asdSystemVersions: designator normalisation --------------------------
  keywordNamedSystem =
    version.asdSystemVersions ./version-test-fixtures/keyword-name.asd == {
      foo = "2.0";
    };
  uninternedNamedSystem =
    version.asdSystemVersions ./version-test-fixtures/uninterned-name.asd == {
      foo = "4.0";
    };

  # -- asdSystemVersions: one entry per defsystem ---------------------------
  multiSystemVersions =
    version.asdSystemVersions ./version-test-fixtures/agreeing-versions.asd == {
      "agreeing" = "1.1.0";
      "agreeing/test" = "1.1.0";
    };
  # Orthogonal to fromAsdSystem: drift is reportable data here, not an error.
  driftIsReportedPerSystem =
    version.asdSystemVersions ./version-test-fixtures/conflicting-versions.asd == {
      first = "1.0.0";
      second = "2.0.0";
    };
  versionlessSystemIsOmitted =
    version.asdSystemVersions ./version-test-fixtures/versionless-system.asd == {
      versioned = "7.0.0";
    };
  componentVersionIsNotASystem =
    version.asdSystemVersions ./version-test-fixtures/nested-version.asd == {
      nested = "5.0.0";
    };
  noDefsystemHasNoSystems = version.asdSystemVersions ./version-test-fixtures/no-defsystem.asd == { };

  # -- asdSystemDependencies: one entry per defsystem -----------------------
  # Unlike `asdSystemVersions`, a system missing the option is PRESENT with an
  # empty list: a dependency-less system is a real, buildable system, whereas a
  # version-less one has no version to hand back. Both assertions are on the
  # same fixture so the difference is pinned, not just described.
  dependencylessSystemIsEmptyList =
    version.asdSystemDependencies {
      asd = ./version-test-fixtures/no-depends-on.asd;
      features = noFeatures;
    } == {
      standalone = [ ];
      dependent = [ "standalone" ];
    };
  versionlessSystemIsStillOmitted =
    version.asdSystemVersions ./version-test-fixtures/no-depends-on.asd == {
      dependent = "1.0.0";
    };
  # The sibling with a real dependency is what gives this assertion teeth: an
  # implementation that never parsed `:depends-on` would return `[ ]` for both
  # systems and could not be told apart from a correct one on `empty-depends`
  # alone.
  emptyDependsOnIsEmptyList =
    version.asdSystemDependencies {
      asd = ./version-test-fixtures/empty-depends-on.asd;
      features = noFeatures;
    } == {
      empty-depends = [ ];
      empty-dependent = [ "empty-depends" ];
    };
  # `:depends-on nil` says what `:depends-on ()` says, in either case.
  nilDependsOnIsEmptyList =
    version.asdSystemDependencies {
      asd = ./version-test-fixtures/nil-depends-on.asd;
      features = noFeatures;
    } == {
      nil-depends = [ ];
      uppercase-nil-depends = [ ];
      nil-dependent = [ "nil-depends" ];
    };
  # Same key shape as `asdSystemVersions`: the designator prefix is stripped,
  # on the dependency side as well as the system side.
  keywordNamedSystemDependencies =
    version.asdSystemDependencies {
      asd = ./version-test-fixtures/keyword-name.asd;
      features = noFeatures;
    } == {
      foo = [ "cl-date-kit" ];
    };

  # -- asdSystemDependencies: what counts as the system's own :depends-on ---
  # Both directions of the depth rule, on one file: the component's
  # `:depends-on` is not attributed to its system, and the system's own one
  # alongside it still is.
  componentDependsOnIsIgnored =
    version.asdSystemDependencies {
      asd = ./version-test-fixtures/nested-depends-on.asd;
      features = noFeatures;
    } == {
      "nested-depends" = [ "cl-date-kit" ];
      "nested-depends/component-only" = [ ];
    };
  # The other half of the same guard, and the half `componentDependsOnIsIgnored`
  # cannot reach: a `:depends-on` outside EVERY defsystem. Drop the guard and
  # the quoted template's parenthesised value is eaten as a dependency list,
  # taking the `defsystem` written inside it with it.
  strayDependsOnIsNotSystemMetadata =
    version.asdSystemDependencies {
      asd = ./version-test-fixtures/stray-depends-on.asd;
      features = noFeatures;
    } == {
      "template-inner" = [ ];
      "stray-depends-on" = [ "cl-date-kit" ];
    };
  strayDependsOnDoesNotHideAVersion =
    version.asdSystemVersions ./version-test-fixtures/stray-depends-on.asd == {
      "template-inner" = "9.9.9";
      "stray-depends-on" = "1.0.0";
    };

  # -- asdSystemDependencies: the list is reported as written ---------------
  dependencyOrderAndDuplicatesArePreserved =
    version.asdSystemDependencies {
      asd = ./version-test-fixtures/duplicate-dependencies.asd;
      features = noFeatures;
    } == {
      duplicated = [
        "cl-weave"
        "cl-date-kit"
        "cl-weave"
      ];
    };
  # A file cut off mid-list reports what it read. Without the end-of-input
  # branch this indexes past the last token instead.
  truncatedDependsOnReportsWhatItRead =
    version.asdSystemDependencies {
      asd = ./version-test-fixtures/truncated-depends-on.asd;
      features = noFeatures;
    } == {
      truncated = [ "cl-date-kit" ];
    };

  # -- asdSystemDependencies: element shapes --------------------------------
  dependencyDesignatorShapes =
    version.asdSystemDependencies {
      asd = ./version-test-fixtures/dependency-shapes.asd;
      features = noFeatures;
    } == {
      shapes = [
        "cl-date-kit"
        "cl-cc-ast"
        "cl-prolog"
        "cl-weave"
      ];
    };
  requireClauseNamesNoSystem =
    version.asdSystemDependencies {
      asd = ./version-test-fixtures/require-dependency.asd;
      features = noFeatures;
    } == {
      requires = [ "cl-date-kit" ];
    };

  # -- asdSystemDependencies: reader conditionals ---------------------------
  # The whole point of taking `features`: the same file answers differently
  # per implementation, because each name here becomes a derivation built for
  # one implementation and a surplus entry is a build for the wrong one.
  readerConditionalsOnSbcl =
    version.asdSystemDependencies {
      asd = ./version-test-fixtures/reader-conditional-dependencies.asd;
      features = [
        "sbcl"
        "unix"
      ];
    } == {
      conditional = [
        "cl-date-kit"
        "cl-sbcl-only"
        "cl-sbcl-or-ccl"
        "cl-sbcl-and-unix"
        "cl-stacked"
      ];
    };
  readerConditionalsOnEcl =
    version.asdSystemDependencies {
      asd = ./version-test-fixtures/reader-conditional-dependencies.asd;
      features = [
        "ecl"
        "unix"
      ];
    } == {
      conditional = [
        "cl-date-kit"
        "cl-not-sbcl"
        "cl-not-sbcl-compound"
        "cl-weave"
      ];
    };
  # `#+(or sbcl ccl)` lexes as the atom `#+` followed by a list, so the old
  # rule reported `or` as a dependency element and failed. Nothing in either
  # answer above is named `or` or `and`, which is the assertion.
  compoundConditionalIsNotADependencyName =
    !(builtins.elem "or"
      (version.asdSystemDependencies {
        asd = ./version-test-fixtures/reader-conditional-dependencies.asd;
        features = [ "sbcl" ];
      }).conditional
    );

  # -- asdSystemDependencies: ASDF's own (:feature ...) clause --------------
  featureClausesOnSbcl =
    version.asdSystemDependencies {
      asd = ./version-test-fixtures/feature-clause-dependencies.asd;
      features = [ "sbcl" ];
    } == {
      feature-clauses = [
        "cl-date-kit"
        "cl-sbcl-only"
        "cl-weave"
      ];
    };
  featureClausesOnEcl =
    version.asdSystemDependencies {
      asd = ./version-test-fixtures/feature-clause-dependencies.asd;
      features = [ "ecl" ];
    } == {
      feature-clauses = [
        "cl-date-kit"
        "cl-not-sbcl"
      ];
    };

  # -- asdSystemDependencies: shapes with no defensible answer --------------
  unknownDependencyShapeFails = assertDependenciesFail {
    asd = ./version-test-fixtures/unknown-dependency-shape.asd;
    features = noFeatures;
  };
  nonListDependsOnFails = assertDependenciesFail {
    asd = ./version-test-fixtures/non-list-depends-on.asd;
    features = noFeatures;
  };
  # `systemNameAt` accepts a bare symbol as a system NAME, so the rejection in
  # a dependency position is a rule of its own and needs its own fixture --
  # nothing else in this directory reaches that branch.
  bareSymbolDependencyFails = assertDependenciesFail {
    asd = ./version-test-fixtures/bare-symbol-dependency.asd;
    features = noFeatures;
  };
  # There is deliberately no assertion that omitting `features` fails.
  # `asdSystemDependencies` destructures `{ asd, features }`, so Nix itself
  # raises "called without required argument" -- an evaluator error, not a
  # `throw`, which `builtins.tryEval` does not catch and no test here could
  # observe. The guarantee is in the signature rather than in this file.

  # -- the shared parse: a bad :depends-on must not cost a version ----------
  # `defsystemForms` backs all three entry points. Nineteen repositories call
  # `fromAsdSystem` for a version string and have no stake in dependency
  # syntax; a `:depends-on` shape this lexer cannot read has to stay confined
  # to the dependency answer.
  malformedDependsOnStillYieldsAVersion =
    version.fromAsdSystem ./version-test-fixtures/malformed-depends-on.asd == "6.0.0";
  malformedDependsOnStillYieldsPerSystemVersions =
    version.asdSystemVersions ./version-test-fixtures/malformed-depends-on.asd == {
      malformed-non-list = "6.0.0";
      malformed-unknown-shape = "6.0.0";
      malformed-bare-symbol = "6.0.0";
      malformed-dangling-conditional = "6.0.0";
    };
  # ... and `asdSystemDependencies` is no quieter for it.
  malformedDependsOnStillFailsDependencies = assertDependenciesFail {
    asd = ./version-test-fixtures/malformed-depends-on.asd;
    features = noFeatures;
  };
}
