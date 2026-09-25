# Why cl-nix-forge

There are two established ways to build a Common Lisp system with Nix:
nixpkgs' own `lisp-modules` (`pkgs.sbcl.buildASDFSystem`) and
[`cl-nix-lite`](https://github.com/hraban/cl-nix-lite). Both are real, usable
options, and this project owes its build primitive to both.

`cl-nix-forge` exists because of gaps neither closes.

## Point by point

| | nixpkgs `lisp-modules` | `cl-nix-lite` | `cl-nix-forge` |
|---|---|---|---|
| One derivation per ASDF system, sharing prebuilt fasls | yes | yes | yes |
| One repo exporting several systems that depend on each other, deduplicated | no | yes (`ancestryWalker`), documented as an advanced API | yes, same mechanism, promoted to a documented, supported path |
| Lisp dependency vs. Nix build input | conflated | conflated (`buildInputs = ... ++ ancestry.deps`) | separated: `lispDependencies` never touches `buildInputs` |
| Native library visible to a transitive (2+ hop) consumer | no | no (one hop, and only if the consumer directly depends on a package literally named `cffi`) | yes, propagated through the same dependency graph as everything else |
| Declarative multi-Lisp-implementation test matrix | no | no (hand-maintained `meta.broken` predicate lists) | yes (`mkCheckMatrix`) |
| `.asd` `:version` extraction | no | no ("no QuickLisp database nor .asd file introspection is done whatsoever") | yes (`fromAsdSystem`), fails loudly on an unrecognized shape |
| Cross-platform `program-op` executable delivery | — | — | yes — the same `asdf:program-op` path on every declared platform, including aarch64-darwin with SBCL (see below) |
| Consume a nixpkgs or foreign-flake package as a dependency | — | — | yes (`fromDerivation`/`fromNixpkgsLisp`) |

`lib/core/*.nix` carries the implementation and the reasoning behind each of
these, in doc comments next to the code they document.

## The rows that need more than a cell

### Multi-system repositories

A single source tree can export several ASDF systems that depend on each
other — and, transitively, on systems from other source trees that depend
back on the first tree's other systems. That is a same-repository dependency
cycle, and it appears the moment you stop treating "system" and "repository"
as the same granularity.

Building each exported system as an independent derivation would recompile
the shared source tree once per system, and worse, ASDF would try to rewrite
fasls a sibling derivation already produced from the same files.

`ancestryWalker` walks the dependency graph and collapses any two derivations
resolving to the same key — normally the store path of the source tree they
were built from — into one. `cl-nix-lite` reached the same mechanism, and
then warned its users away from it. Here it is the documented path, with one
addition: when two merged systems disagree about a non-dependency build
argument, that is an evaluation error naming the arguments and both systems,
never a silent pick of whichever side the dependency walk folded last.

### Lisp dependency versus Nix build input

They are different things. A Lisp-level dependency has to be findable by
ASDF; a Nix-level build input has to be on `PATH` or in the linker's view.
Conflating them, as both prior options do, means every transitive Lisp
dependency silently joins your derivation's rebuild-trigger set even when
nothing native changed.

`lispDependencies` resolve purely into `CL_SOURCE_REGISTRY`. They are still
derivation inputs — their string context is preserved, so a dependency change
still rebuilds its consumer — but they never enter `buildInputs`.

### Native library propagation

A Lisp dependency that also builds a native `.so`/`.dylib` (via CFFI, say)
has, in prior art, no way to make that fact visible more than one hop away.
Every transitive consumer has to know by name which of its
dependencies-of-dependencies produced the library, and hand-copy an
`LD_LIBRARY_PATH` line for it.

Here `nativeLibraries` folds into the same dependency walk as
`lispDependencies`, so a consumer three hops from the producer still finds
the library — at build time, in a dev shell, and inside a delivered
executable's wrapper. See
[Dependencies and native libraries](../reference/dependencies.md).

### Darwin executable delivery

`mkExecutable` drives `asdf:program-op`, which on SBCL embeds the Lisp image
directly into the executable — the same path on aarch64-darwin as on Linux.
An earlier revision fell back to a plain `.core` via `save-lisp-and-die`
wrapped in `sbcl --core` on Darwin with SBCL, on the strength of one
observation that `program-op` had not produced a binary within five minutes.
That observation did not reproduce: rebuilt in isolation against a current
nixpkgs SBCL, the same invocation this module uses completed in seconds and
produced a working, already ad-hoc-signed Mach-O executable. See
[Platform coverage](../project/platform-coverage.md) for what is and is not
verified about this on aarch64-darwin.

## What this does not claim

[Non-goals](non-goals.md) lists what `cl-nix-forge` does not do and the
reason for each boundary.
