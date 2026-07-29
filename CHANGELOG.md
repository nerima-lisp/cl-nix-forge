# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the major version is 0, the public API in `lib/` may change in a
breaking way in any release. It is deliberately not frozen yet: the library
has not yet been applied to a real repository, and the first three adoptions
(`cl-weave`, `cl-prolog`, `cl-json-kit`) are expected to expose gaps that are
better fixed than worked around. `1.0.0` is the release that follows those
three migrations, not the one that precedes them.

## [Unreleased]

## [0.2.0] - 2026-07-30

### Added

- `mkPackageFlake` — the nerima-lisp flake standard as a function call
  instead of a template to copy. One call returns a package's whole output
  set (`packages`, `checks`, `apps`, `devShells`, `formatter`, `overlays`)
  from its declarations. It is the only module taking `lib` without `pkgs`:
  every other module is instantiated for one `pkgs`, and a preset built that
  way could only emit the single system it was instantiated for, so this one
  takes `systems` and obtains a `pkgs` — and a cl-nix-forge — per declared
  system itself. `extraOutputs` adds and `overrideOutputs` replaces, kept
  separate so an intended override stays distinguishable from an accidental
  name collision; a collision is an evaluation error.
- Implementation table rows for `ccl`, `abcl`, `clisp` and `clasp`, joining
  `sbcl` and `ecl`. CCL is why the rows carry their reasoning: it has no
  `--script`, rejects a bare filename outright, and needs `--batch` to route
  an unhandled condition to a non-zero exit — without which a failing suite
  exits 0 and every test appears to pass.
- This repository's own documentation site, built by its own `mkDocsSite`.

### Changed

- `mkCheckMatrix` decides availability from `lib.meta.availableOn` rather
  than a platform list kept in this library, so one matrix can be written
  once and used on every system — nixpkgs is the authority on where CCL
  builds, and it changes. A platform skip, a caller's `skip` and an
  `expectedFailure` remain three distinct things: conflating them would let
  a real regression hide behind an implementation that cannot run on the
  host. A package that IS available here but broken, unfree or insecure
  still throws, exactly as it would anywhere else in nixpkgs.
- README is a 136-line entry point, under the org standard's 150-line cap,
  with the reference material moved to `docs/src/`.

### Known gaps

- `mkExecutable`'s two delivery paths are never verified by the same
  machine. The branch is `isDarwin && sbcl`, so a Linux runner always takes
  `asdf:program-op` and an aarch64-darwin developer always takes the
  `save-lisp-and-die` fallback. CI is `x86_64-linux` only, which leaves the
  Darwin fallback resting on local `nix flake check` alone.
- `ccl`, `clisp` and `clasp` rows are unverified by execution on
  aarch64-darwin, where nixpkgs reports all three unavailable. CI is the
  first machine to run them.
- No consumer has been migrated yet. See the note at the top about `1.0.0`.

## [0.1.0] - 2026-07-29

First tagged release. Everything below is new; the sections describe what the
library does rather than what changed, since there is no prior version.

### Added

#### Core (`lib/core/`)

- `lispDerivation` — build and test one or more ASDF systems from a source
  tree. `$out` is source plus compiled FASLs side by side, directly reusable
  as another package's `CL_SOURCE_REGISTRY` entry. Lisp dependencies enter the
  registry and never `buildInputs`.
- `lispMultiDerivation` — several ASDF systems from one source tree, merged
  into a single derivation when they depend on each other. Systems that merge
  must agree on every non-dependency build argument; disagreement is an
  evaluation error naming the arguments and both systems, never a silent pick.
- `lispWithSystems`, `lispScript` — a wrapped implementation, and a script
  packaged with the same dependency environment.
- `mkScriptCheck` — run a check through an arbitrary Lisp entry point instead
  of `asdf:test-system`, defaulting to the nerima-lisp standard
  `run-tests.lisp`. Required for a suite that cannot be driven by an enclosing
  `test-op`: a framework that tests its own ASDF integration puts `test-op` on
  the plan twice and ASDF rejects it as a circular dependency.
- `mkLispSource` — the `src` a Lisp build should see, as an allowlist. A
  denylist over `lib.cleanSourceFilter` is wrong in both directions: it keeps
  `.fasl`/`.core` and every artefact directory nothing has been taught about
  yet, so a local test run changes the derivation hash; and it cannot
  distinguish "the filter dropped `t/`" from "`t/` was untracked".
- `mkCheckMatrix` — declarative multi-implementation test matrix, replacing
  hand-maintained `meta.broken` predicate lists.
- `markNativeLibrary` and the native-loader helpers — a native library
  declared once stays visible to consumers any number of hops away, through
  the same dependency walk as everything else.
- `fromDerivation` / `fromNixpkgsLisp` — consume a nixpkgs or foreign-flake
  package as a dependency. `fromNixpkgsLisp` requires `lispImplementation`,
  so a consumer on another implementation fails during evaluation rather than
  attempting to compile FASLs into the immutable Nix store.
- `ancestryWalker` / `unionAttrsBy` — the deduplication primitive the
  multi-system path is built on.

#### Batteries (`lib/batteries/`)

- `fromAsdSystem` — extract a literal `:version` from a `.asd` file.
  Recognises `defsystem`, `asdf:defsystem` and `asdf/defsystem:defsystem`.
  One file normally defines `<pkg>` and `<pkg>/test` carrying the same
  version: that unanimity is accepted. Versions that disagree are real drift
  and fail loudly, naming each value and its system.
- `asdSystemVersions` — the same extraction keyed by system name.
- `mkTestCheck` — a named check for a derivation's `asdf:test-system` path.
- `mkCommandCheck` — run a command (an argv list), assert it produced named
  artifacts, validate them, and publish the artifacts — and only the
  artifacts — as the check's `$out`.
- `mkCoverageReport` — an sb-cover HTML report. SBCL only, and it says so
  during evaluation rather than producing an empty report at build time.
- `mkExecutable` — deliver a standalone binary via `asdf:program-op`, with a
  fallback on Darwin/SBCL where that path was observed to produce no binary
  within five minutes.
- `mkApp`, `mkTestApp`, `mkOverlay` — flake `apps` and `overlays` entries.
- `mkDocsSite`, `mkDevShell`, `collect` — a mkdocs-material site, a
  `nix develop` shell, and sibling-package collection from flake inputs.

### Known gaps

- `mkExecutable`'s two delivery paths are never verified by the same machine,
  and CI covers only one of them. The branch is `isDarwin && sbcl`, so a
  Linux runner always takes `asdf:program-op` and an aarch64-darwin developer
  always takes the `save-lisp-and-die` fallback. CI is `x86_64-linux` only,
  which leaves the Darwin fallback resting on local `nix flake check` alone.
- Only `sbcl` and `ecl` have rows in the implementation table.
- The library has no consumers yet. See the note above about `1.0.0`.

[Unreleased]: https://github.com/nerima-lisp/cl-nix-forge/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/nerima-lisp/cl-nix-forge/releases/tag/v0.2.0
[0.1.0]: https://github.com/nerima-lisp/cl-nix-forge/releases/tag/v0.1.0
