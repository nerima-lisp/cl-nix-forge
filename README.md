# cl-nix-forge

`cl-nix-forge` is a Nix flake-library for building, testing, and composing
Common Lisp (ASDF) systems as Nix derivations — the same role
[`crane`](https://github.com/ipetkov/crane) plays for Rust/Cargo.

It is not a package set (it ships no Quicklisp database) and not a
replacement for nixpkgs' own Lisp packaging. It is a small set of composable
functions: point them at a source tree with a `.asd` file and get back a
normal Nix derivation, whose `$out` (source plus compiled fasls, side by
side) is directly usable as another package's dependency.

## Why not just use nixpkgs' `sbcl.buildASDFSystem`, or `cl-nix-lite`?

Both are real, usable options, and this project owes its build primitive to
both. `cl-nix-forge` exists because of three gaps neither closes:

| | nixpkgs `lisp-modules` | `cl-nix-lite` | `cl-nix-forge` |
|---|---|---|---|
| One derivation per ASDF system, sharing prebuilt fasls | yes | yes | yes |
| One repo exporting several systems that depend on each other, deduplicated | no | yes (`ancestryWalker`), but its own docs call the multi-system API "an advanced API which doesn't work... do not use this unless you are stubborn" | yes, same mechanism, promoted to a documented, supported path |
| Lisp dependency vs. Nix build input | conflated | conflated (`buildInputs = ... ++ ancestry.deps`, flagged in-code as "clearly wrong") | separated: `lispDependencies` never touches `buildInputs` |
| Native library visible to a transitive (2+ hop) consumer | no | no (one hop, and only if the consumer directly depends on a package literally named `cffi`) | yes, propagated through the same dependency graph as everything else |
| Declarative multi-Lisp-implementation test matrix | no | no (hand-maintained `meta.broken` predicate lists) | yes (`mkCheckMatrix`) |
| `.asd` `:version` extraction | no | no ("no QuickLisp database nor .asd file introspection is done whatsoever") | yes (`fromAsdSystem`), fails loudly on an unrecognized shape |
| Cross-platform `program-op` executable delivery | — | — | yes — transparently works around SBCL's Darwin `program-op` delivery bug (observed once on aarch64-darwin: no binary after five minutes; see `lib/batteries/app.nix`) |
| Consume a nixpkgs or foreign-flake package as a dependency | — | — | yes (`fromDerivation`/`fromNixpkgsLisp`) |

See `lib/core/*.nix` for the implementation and the reasoning behind each of
these, in doc comments next to the code they document.

## What this deliberately does NOT do

- **Per-file FASL caching finer than one derivation per ASDF system.**
  Infeasible, not just undeveloped: compiling file N of a serial ASDF system
  requires files `1..N-1` to already be *loaded* (macros, `eval-when`, CLOS
  class definitions all take effect at load time), so a file can't be
  compiled as a pure function of its own text. One derivation per system is
  the real ceiling — nixpkgs' and `cl-nix-lite`'s independent designs already
  converge on it.
- **Cargo/poetry-style lockfile version unification.** ASDF resolves systems
  by name only; there's no version-lockfile concept to unify. This library
  makes the existing name-based model *reproducible* for a fixed set of
  pinned inputs — it doesn't invent CL package-version resolution.
- **Quicklisp/Ultralisp dist fetching.** Use `pkgs.sbcl.withPackages` /
  nixpkgs `lisp-modules` for that, and hand the result to `fromNixpkgsLisp`
  if you need to mix it with `cl-nix-forge`-built systems.
- **Cross-compilation.**

## Quick start

```nix
{
  inputs.cl-nix-forge.url = "github:nerima-lisp/cl-nix-forge";

  outputs = { self, nixpkgs, cl-nix-forge }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      cl = cl-nix-forge.lib.${system};
    in
    {
      packages.${system}.default = cl.lispDerivation {
        lispSystem = "my-app";
        version = cl.fromAsdSystem ./my-app.asd;
        src = ./.;
        lispDependencies = [
          (cl.fromNixpkgsLisp {
            drv = pkgs.sbcl.pkgs.alexandria;
            lispImplementation = "sbcl";
          })
        ];
      };
    };
}
```

## Core API (`lib/core/`)

- `lispDerivation` — build and test one or more ASDF systems. Pass exactly
  one of `lispSystem` or `lispSystems`; `lispDependencies` enter
  `CL_SOURCE_REGISTRY`, while `buildInputs` and `nativeBuildInputs` retain
  ordinary Nix meanings. They are nevertheless derivation inputs, so a
  dependency change still rebuilds its consumer. `lisp`,
  `lispImplementation`, `lispAsdPath`, and `lispBuildOp` select the
  implementation, executable name, ASDF search roots, and ASDF operations
  respectively. When `lisp` is supplied, `lispImplementation` defaults to
  its package name (for example, `ecl`) and, if explicitly set, must match
  that package name.
- `lispMultiDerivation` — same-repository multi-system helper. Two systems
  that share a source tree and a dependency closure build as one
  derivation, so they must also agree on every non-dependency build
  argument (`buildInputs`, `patches`, `version`, ...); disagreement is an
  evaluation error naming the arguments and both systems, never a silent
  pick of one side. Model systems with fundamentally different build phases
  as separate derivations.
- `mkLispSource` — the `src` a Lisp build should see, as an **allowlist**
  (`lib/core/source.nix`): `.asd` and `.lisp` anywhere under `root`, and
  nothing else. `mkLispSource { root = ./.; }` is the whole common case.
  A denylist over `lib.cleanSourceFilter` is the shape every downstream
  repo reached independently and it is wrong in both directions —
  `cleanSourceFilter` keeps `.fasl`/`.core` and every artefact directory a
  tool has not been taught about yet, so a local test run changes the
  derivation hash; and it gives no way to distinguish "the filter dropped
  `t/`" from "`t/` was untracked", which is the confusion cl-prolog's
  filter encodes. An allowlist keeps `t/` by the same rule that keeps
  `src/`, with no clause of its own. `extensions`, `include` and `exclude`
  are the escape hatches; a fixture the build genuinely needs and that is
  not Lisp source is opted in with `include`, and its absence fails loudly
  rather than silently.
- `markNativeLibrary` — explicitly declares a producer of a shared library
  for transitive runtime-loader propagation (`lib/core/native.nix`).
- `mkScriptCheck` — run a check through an arbitrary Lisp entry point
  instead of `asdf:test-system` (`lib/core/script-check.nix`). Defaults to
  `entryPoint = "run-tests.lisp"`, the nerima-lisp org standard, so the
  command a developer runs by hand and the gate CI runs cannot drift apart;
  pass `entryPointText` for an inline script instead. Required for a suite
  that cannot be driven by an enclosing `test-op` — a framework that tests
  its own ASDF integration puts `test-op` on the plan twice and ASDF rejects
  it as a circular dependency. Accepts `timeoutSeconds`/`killAfterSeconds`.
- `mkCheckMatrix` — declarative multi-Lisp-implementation test matrix
  (`lib/core/matrix.nix`).
- `fromDerivation` / `fromNixpkgsLisp` — consume a nixpkgs or foreign-flake
  package as a dependency (`lib/core/external.nix`). `fromNixpkgsLisp`
  requires both `drv` and `lispImplementation` — there is no
  bare-derivation form, because every package it wraps is precompiled Lisp
  whose FASLs belong to one implementation, and a consumer using another
  one must fail during evaluation instead of attempting to compile FASLs
  into the immutable Nix store. `fromDerivation` also wraps genuinely
  non-Lisp outputs, so its `lispImplementation` stays optional; it inherits
  the wrapped derivation's own implementation when there is one, and
  refuses to contradict it.

`lispWithSystems` creates a wrapped implementation with the supplied systems
on `CL_SOURCE_REGISTRY` while preserving a caller-supplied registry.
`lispScript` packages a script with the same dependency environment.
`ancestryWalker` and the low-level native loader helpers remain public
implementation support. Prefer the APIs above for new projects.

## Batteries (`lib/batteries/`, optional convenience)

- `fromAsdSystem` — extract the literal, unescaped `:version` declared as a
  direct option of a `defsystem` form in a `.asd` file. The operator is
  recognised as `defsystem`, `asdf:defsystem` or `asdf/defsystem:defsystem`,
  case-insensitively, since all three occur in the wild. One `.asd` normally
  defines several systems (`<pkg>` and `<pkg>/test`) that all carry the same
  version: that unanimity is accepted and returned. Versions that *disagree*
  are real drift and fail loudly, naming each value and the system it came
  from. Line and nested block comments are ignored, a `:version` nested
  inside `:components` is never mistaken for a system's own, and missing or
  dynamic versions fail — pass `version` explicitly in those cases.
- `asdSystemVersions` — the same extraction as an attrset keyed by system
  name (`{ "cl-prolog" = "1.1.0"; "cl-prolog/test" = "1.1.0"; }`), for the
  rarer case of needing one specific system's version rather than the
  file's consensus. System-name designators are normalised, so `"x"`, `:x`
  and `#:x` all key as `"x"`.
- `mkTestCheck` — a named `checks.<system>.<name>` for a derivation's
  `enableCheck`, i.e. the `asdf:test-system` path. For a suite that cannot
  be driven by an enclosing `test-op`, or that needs a time limit, use
  `mkScriptCheck`.
- `mkCommandCheck` — run a command (an argv **list**, never a concatenated
  string) against a built system, assert it produced named `artifacts`,
  run `validationCommands` over them, and publish the artifacts — and only
  the artifacts — as the check's `$out`, so CI can retrieve them. Every
  artifact is asserted present *and non-empty*; a directory artifact must
  contain at least one entry. Accepts `timeoutSeconds`/`killAfterSeconds`
  and `nativeBuildInputs` for the validators (`jq`, `libxml2`, `perl`, …).
- `mkCoverageReport` — an sb-cover HTML report as a derivation whose `$out`
  is the report. **SBCL only**: it throws during evaluation for any other
  implementation rather than emitting an empty report. It owns the
  load-bearing `declaim`/`:force t`/`declaim` sequence, without which ASDF
  reuses uninstrumented FASLs and the report comes back empty. It asserts
  its own `cover-index.html` is non-empty, so it doubles as
  `checks.coverage` with no wrapper derivation. There is deliberately no
  minimum-coverage threshold: the report exists to make the number visible
  and trending, and `sb-cover:report` exposes no aggregate percentage, so a
  gate would mean scraping SBCL's generated HTML. Compute the ratio in your
  own Lisp and gate it with `mkCommandCheck` if you want one.
- `mkDocsSite` — a generic mkdocs-material site builder. `pname`,
  `version` and `meta` are the caller's: a docs site is a package
  published under a project's own name, and hardcoding
  `docs-site`/`unstable` was enough to make every consumer hand-write the
  derivation again. `version` pairs with `fromAsdSystem`, so a release
  still only edits the `.asd`.
- `mkDevShell` — a `nix develop` shell that exports the derivation's own
  resolved `CL_SOURCE_REGISTRY` and prints a short banner. It sets the
  registry itself rather than inheriting the derivation's shellHook:
  `mkShell` copies shellHook *text* out of `inputsFrom` but not the
  derivation's environment, so `lispDerivation`'s `eval
  "$setAsdfPathPhase"` arrived empty and the registry silently stayed
  unset. `ASDF_OUTPUT_TRANSLATIONS` is deliberately left alone, so a REPL
  caches FASLs under `~/.cache` instead of dropping them in the working
  tree for `mkLispSource` to filter back out. A
  `pkgs.sbcl.withPackages`-built Lisp in `extraPackages` composes: it wins
  on `PATH`, and nixpkgs builds that wrapper with `--prefix
  CL_SOURCE_REGISTRY`, so its packages prepend to the registry rather than
  replacing it.
- `mkExecutable` — deliver a standalone binary via `asdf:program-op`
  (with the Darwin SBCL workaround described above). Its `args` are the
  corresponding `lispDerivation` arguments. `pname` controls the installed
  executable name and may differ from `lispSystem`; use `programPath` when
  the ASDF `:build-pathname` differs from the system name.
  `dynamicSpaceSize` and `imageRequires` act on the Lisp that performs the
  dump, and take effect on both delivery paths. What a binary *is* stays
  the `.asd`'s: `:build-operation`, `:entry-point`, `:build-pathname`, and
  contribs the system needs (`:depends-on ((:require :sb-cover))`) have no
  Nix option here. Two knobs are absent on purpose — `uiop:dump-image`
  hardcodes `:save-runtime-options t` for executables, and ASDF never
  passes `:compression`, so neither could be honoured on the `program-op`
  path; both behaviours are instead made identical across the two paths.
- `mkApp` — a flake `apps.<system>.<name>` entry for a derivation, with
  `program` read from its `meta.mainProgram` via `lib.getExe` instead of
  spelled out a second time.
- `mkTestApp` — `nix run .#test`: runs the repo's own `run-tests.lisp`
  (the nerima-lisp org standard entry point) in place, under a
  `CL_SOURCE_REGISTRY` in which the tree under test shadows everything
  else, with a `timeout -k` that escalates to SIGKILL because SBCL defers
  signals to safepoints. Complements `mkTestCheck`/`mkScriptCheck`: same
  suite, but the `nix run` output rather than a check.
- `mkOverlay` — `overlays.default`, naming each published package by its
  own `pname` rather than repeating the name. Reads the system from
  `prev`, not `final`: an overlay whose attribute *names* are computed
  cannot force `final.stdenv` without recursing infinitely.
- `collect` — pull a named set of sibling packages out of flake inputs.

## Examples

`examples/` doubles as this library's own test suite (wired into
`checks.<system>` by `flake.nix`):

- `simple-library/` — a single-system leaf exercising `fromAsdSystem`,
  `mkTestCheck`, `mkDocsSite`, `mkDevShell`, `lispWithSystems`,
  `lispScript`, a direct `lispBuildOp` override, and an executable whose
  ASDF and installed names differ.
- `multi-system-repo/` — two systems in one source tree, one depending on
  the other, exercising `lispMultiDerivation`, `fromDerivation`, and
  `core/dedup.nix`'s merge path.
- `native-library-consumer/` — a native shared library, a direct consumer,
  and a consumer of that consumer, proving the search path propagates two
  hops without the middle package needing to know about it. The test loads
  the shared library through CFFI and calls its exported symbol.
- `asd-search-path/` — an ASDF definition below the source root, proving
  `lispAsdPath` makes both its build and `asdf:test-system` discoverable.
- `check-only-dependencies/` — a test-only ASDF dependency resolved through
  `lispCheckDependencies` during `doCheck`, while the normal derivation has
  no dependency closure for that support system.
- `multi-lisp-matrix/` — one system tested under both SBCL and ECL plus an
  external (non-Lisp) tool dependency, via `mkCheckMatrix`.
- `checks-and-coverage/` — a system whose `.asd` defines a `test-op` that
  errors on purpose, so that a passing `mkScriptCheck` is itself proof the
  check never routed through `asdf:test-system`. Covers both entry-point
  forms, a `mkCommandCheck` producing JSON/text/directory artifacts (one
  filename contains a space, which survives only because `command` is an
  argv list), and an `mkCoverageReport`. Its failure paths are proved, not
  assumed: a deliberately failing entry point and a runaway loop killed by
  its time limit each run the real check phase inside a wrapper that passes
  only when that phase failed with an expected exit status (1, and 124/137
  respectively).

- `flake-outputs/` — the flake surface a downstream repo actually writes:
  `mkLispSource`, `mkApp`, `mkTestApp`, `mkOverlay`, a `mkDocsSite` with
  caller-supplied identity, and an `mkExecutable` with a non-default
  dynamic space size and an extra image module. Nothing is asserted in a
  comment: planted `.fasl`/`.core`/`coverage-report-*` fixtures are proved
  absent from the filtered source and `t/` proved present by listing it;
  the test app is run twice, once against a suite that passes and once
  against one that fails; and the delivered binary prints its own argv,
  dynamic space size and loaded modules so the checks can assert on all
  three.

On one host, run `nix flake check` to build and verify that host's checks.
Run `nix flake check --all-systems --no-build --no-write-lock-file` to
evaluate every declared system without attempting cross-platform builds. CI
does both: it evaluates all declared systems, then builds every check on each
supported host (x86_64-linux and aarch64-darwin).
