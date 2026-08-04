# API index

`cl-nix-forge.lib.${system}` is one flat attrset of 30 functions. This page
lists all of them; each row links to its full entry.

The **Module** column preserves the `lib/core/` versus `lib/batteries/`
distinction that the functional grouping of these pages cuts across.
`lib/core/` is the set of differentiators — the reason this library exists.
`lib/batteries/` is optional convenience that a downstream flake could write
by hand, and kept writing by hand identically, which is why it is here.

## Building systems

See [Building systems](building.md).

| Function | Module | Summary |
|---|---|---|
| [`lispDerivation`](building.md#lispderivation) | `core/asdf-derivation.nix` | Build and test one or more ASDF systems from a source tree |
| [`lispMultiDerivation`](building.md#lispmultiderivation) | `core/asdf-derivation.nix` | Several systems from one source tree, deduplicated |
| [`mkLispSource`](building.md#mklispsource) | `core/source.nix` | The `src` a Lisp build should see, as an allowlist |
| [`lispWithSystems`](building.md#lispwithsystems) | `core/asdf-derivation.nix` | A Lisp binary wrapped so it can load the given systems |
| [`lispScript`](building.md#lispscript) | `core/asdf-derivation.nix` | Package a Lisp script with that dependency environment |

## Dependencies and native libraries

See [Dependencies and native libraries](dependencies.md).

| Function | Module | Summary |
|---|---|---|
| [`fromDerivation`](dependencies.md#fromderivation) | `core/external.nix` | Wrap any Nix derivation as a `lispDependencies` leaf |
| [`fromNixpkgsLisp`](dependencies.md#fromnixpkgslisp) | `core/external.nix` | Wrap a nixpkgs Lisp package, implementation required |
| [`markNativeLibrary`](dependencies.md#marknativelibrary) | `core/native.nix` | Declare a derivation a producer of a native library |
| [`nativeLibraryPath`](dependencies.md#nativelibrarypath) | `core/native.nix` | `<drv>/lib` directories, `:`-joined |
| [`nativeLibraryEnv`](dependencies.md#nativelibraryenv) | `core/native.nix` | Those directories as a derivation `env` attrset |
| [`nativeLibraryWrapperArgs`](dependencies.md#nativelibrarywrapperargs) | `core/native.nix` | The same path as `makeWrapper` arguments |
| [`libraryPathVar`](dependencies.md#librarypathvar) | `core/native.nix` | `LD_LIBRARY_PATH` or `DYLD_LIBRARY_PATH` for this host |

## Checks and coverage

See [Checks and coverage](checks.md).

| Function | Module | Summary |
|---|---|---|
| [`mkTestCheck`](checks.md#mktestcheck) | `batteries/checks.nix` | A named check running the derivation's `asdf:test-system` |
| [`mkScriptCheck`](checks.md#mkscriptcheck) | `core/script-check.nix` | A check through an arbitrary Lisp entry point |
| [`mkCommandCheck`](checks.md#mkcommandcheck) | `batteries/checks.nix` | Run a command, assert its artifacts, publish them as `$out` |
| [`mkCheckMatrix`](checks.md#mkcheckmatrix) | `core/matrix.nix` | The same suite under several Lisp implementations |
| [`mkCoverageReport`](checks.md#mkcoveragereport) | `batteries/coverage.nix` | An sb-cover HTML report as a derivation (SBCL only) |

## Flake outputs and delivery

See [Flake outputs and delivery](outputs.md).

| Function | Module | Summary |
|---|---|---|
| [`mkPackageFlake`](outputs.md#mkpackageflake) | `batteries/package-flake.nix` | Every output an org-standard package's flake declares, as one call |
| [`mkExecutable`](outputs.md#mkexecutable) | `batteries/app.nix` | Deliver a standalone binary via `asdf:program-op` |
| [`mkApp`](outputs.md#mkapp) | `batteries/outputs.nix` | A flake `apps.<system>.<name>` entry for a derivation |
| [`mkTestApp`](outputs.md#mktestapp) | `batteries/outputs.nix` | `nix run .#test`, running the repo's `run-tests.lisp` |
| [`mkOverlay`](outputs.md#mkoverlay) | `batteries/outputs.nix` | `overlays.default`, naming packages by their own `pname` |
| [`mkDevShell`](outputs.md#mkdevshell) | `batteries/devshell.nix` | A `nix develop` shell with the resolved registry exported |
| [`mkDocsSite`](outputs.md#mkdocssite) | `batteries/docs.nix` | A mkdocs-material site as a package |
| [`collect`](outputs.md#collect) | `batteries/siblings.nix` | Pull named sibling packages out of flake inputs |

## Reading a `.asd`

See [Reading a `.asd`](versions.md).

| Function | Module | Summary |
|---|---|---|
| [`fromAsdSystem`](versions.md#fromasdsystem) | `batteries/version.nix` | The `:version` a `.asd` declares, as one string |
| [`asdSystemVersions`](versions.md#asdsystemversions) | `batteries/version.nix` | The same extraction, keyed by system name |
| [`asdSystemDependencies`](versions.md#asdsystemdependencies) | `batteries/version.nix` | The `:depends-on` names, keyed by system, for a given `*features*` |

## Internals

See [Internals](internals.md). Public implementation support, not the API to
reach for first.

| Function | Module | Summary |
|---|---|---|
| [`ancestryWalker`](internals.md#ancestrywalker) | `core/dedup.nix` | The dependency walk that collapses same-source derivations |
| [`unionAttrsBy`](internals.md#unionattrsby) | `core/dedup.nix` | Union attrsets, folding collisions through a combiner |

## Keeping this page honest

The invariant is that this index and `lib/default.nix` name exactly the same
30 attributes. It is checkable in one command from the repository root:

```sh
nix eval --impure --json --expr \
  'let pkgs = import <nixpkgs> {}; in builtins.attrNames
     (import ./lib/default.nix { inherit (pkgs) lib; inherit pkgs; })'
```

A function added to `lib/default.nix` needs a row here and a full entry on
the reference page for its group. `checks.api-index-contract` in `flake.nix`
now enforces the first half: it reads this file and every attribute name
`lib/default.nix` exports, and fails evaluation — before anything is built —
naming each attribute that has no row. `mkdocs build --strict`
(`checks.docs`) enforces the rest, since a row whose link target does not
exist is a dead anchor.

The check searches for the linked form ``[`name`](`` rather than a bare
mention, because a bare mention is exactly the state it exists to reject:
`mkPackageFlake` was exported in v0.3.0, was referred to by name on three
pages, and had neither a row here nor an entry anywhere until v0.4.1. That
was written up here as an unenforced gap, and the gap promptly recurred —
`asdSystemDependencies` was exported with no row on either count, which is
what turned the paragraph into a check.

The command above still answers "what is exported?" directly, which is the
question to ask when writing the row rather than when verifying it.
