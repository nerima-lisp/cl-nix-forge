# API index

`cl-nix-forge.lib.${system}` is a flat attrset. The table maps each export to
its detailed reference and implementation module.

The **Module** column names the implementation module, with paths relative to
`lib/`. Modules under `core/` contain core APIs; modules under `batteries/`
contain optional convenience APIs for common downstream flake patterns.

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
| [`mkFeatureLintCheck`](checks.md#mkfeaturelintcheck) | `batteries/checks.nix` | Statically check feature declarations, package boundaries, glossary, and exports |
| [`mkOrphanTestCheck`](checks.md#mkorphantestcheck) | `batteries/checks.nix` | Compare test-root Lisp files with the combined ASDF test-system components |

## Flake outputs and delivery

See [Flake outputs and delivery](outputs.md).

| Function | Module | Summary |
|---|---|---|
| [`mkPackageFlake`](outputs.md#mkpackageflake) | `batteries/package-flake.nix` | Assemble a package's flake outputs from one argument set |
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

See [Internals](internals.md). These helpers support `cl-nix-forge`'s own
modules. Downstream flakes usually call the documented builders above.

| Function | Module | Summary |
|---|---|---|
| [`ancestryWalker`](internals.md#ancestrywalker) | `core/dedup.nix` | The dependency walk that collapses same-source derivations |
| [`unionAttrsBy`](internals.md#unionattrsby) | `core/dedup.nix` | Union attrsets, folding collisions through a combiner |

## Keeping this page honest

This index has a linked row for each of the 32 attributes exported by
`lib/default.nix`. From the repository root, with `<nixpkgs>` available via
`NIX_PATH`, the following command prints the exported names for use when
updating or reviewing the table:

```sh
nix eval --impure --json --expr \
  'let pkgs = import <nixpkgs> {}; in builtins.attrNames
     (import ./lib/default.nix { inherit (pkgs) lib; inherit pkgs; })'
```

When adding an export, add a row here and a detailed section on the reference
page for its group. `checks.api-index-contract` in `flake.nix` requires every
exported attribute to appear in a linked row. `mkdocs build --strict`
(`checks.docs`) checks that each link target resolves. These checks do not
reject stale rows or verify that a resolved section documents the linked
function, so review those details when updating the index.
