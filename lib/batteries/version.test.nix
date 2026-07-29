{ lib }:
let
  version = import ./version.nix { inherit lib; };
  # Nix is lazy, so the argument is still an unforced thunk here and the throw
  # happens inside tryEval's dynamic extent.
  assertFails = expression: !(builtins.tryEval expression).success;
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
}
