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

## [0.4.0] - 2026-07-30

### Fixed

- `mkPackageFlake` builds its generated `devShells.default` from the
  check-enabled derivation, so a package whose sibling dependency is
  test-only can actually load it under `nix develop`. Two of the three first
  adopters had written the same `overrideOutputs` workaround, which is what
  identified this as the library's defect rather than one package's quirk;
  the third could never have caught it, being its own test framework with no
  external test dependency. It costs no extra build — `mkShell`'s
  `inputsFrom` takes inputs rather than outputs and subtracts the named
  derivation, so the check-enabled derivation is never realised, while the
  check dependencies it names are already built by `checks.default`.
- `mkLispSource`'s doc comment claimed an allowlist stops a local test run
  from invalidating the build. It narrows that, it does not close it: an
  allowlist by extension excludes an artefact directory of HTML but not one
  of generated `.lisp`. What closes it is the flake source being Git-backed.
  The claim is narrowed to what is true.

## [0.3.0] - 2026-07-30

Everything here was found by APPLYING the library to a real repository for
the first time, not by reading it. This is the release that justifies the
note at the top of this file about `1.0.0`.

### Added

- `mkPackageFlake` gains `executable`, which builds a delivered CLI from the
  preset's OWN resolved `lispDerivation` arguments. `mkExecutable`'s `args`
  was documented as "the exact attrset you'd pass to lispDerivation", but the
  preset had already computed that attrset and exposed only the result — so a
  delivered binary re-spelled `pname`, `lispSystem`, `meta`, `version` and
  `src` in an escape hatch. Two sources of truth for the package's identity,
  inside the one function whose purpose is removing exactly that. The first
  package to deliver a CLI *and* carry `lispDependencies` would have shipped a
  binary silently missing them. The resolved attrset is also on the context
  for anything the argument does not cover; re-spelling `args` wholesale is
  rejected by name.
- `mkExecutable` gains `installSource`, plus a written contract for what
  `$out` contains and what a delivered image may assume about its
  surroundings. A Lisp image that resolves its ASDF source root from
  `*runtime-pathname*` found nothing, because this function published
  `$out/bin` and nothing else; the binary died on its first re-load of one of
  its own systems. Both sides were individually correct and disagreed
  silently, so the missing contract was the actual defect. The dependency
  closure is installed alongside the system's own tree — sources that are
  findable while their dependencies' are not fail at the same place, one
  `asdf:load-system` later.

### Changed

- **Breaking:** `mkPackageFlake`'s `root` is required. `root ? self` was the
  obvious default and never worked: a flake's `self` is an attrset carrying
  an `outPath`, and `lib.fileset` rejects it, so the failure surfaced from
  inside `mkLispSource` naming neither `self` nor the argument responsible.
  It survived the suite because examples are handed `pkgs` and `cl` directly
  and their `self` was already a path literal — the test suite could not
  reach the bug because it never exercises a real flake `self`.
- Delivered executables carry their version in the store path again.

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

[Unreleased]: https://github.com/nerima-lisp/cl-nix-forge/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/nerima-lisp/cl-nix-forge/releases/tag/v0.4.0
[0.3.0]: https://github.com/nerima-lisp/cl-nix-forge/releases/tag/v0.3.0
[0.2.0]: https://github.com/nerima-lisp/cl-nix-forge/releases/tag/v0.2.0
[0.1.0]: https://github.com/nerima-lisp/cl-nix-forge/releases/tag/v0.1.0
