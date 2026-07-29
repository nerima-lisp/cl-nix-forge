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
| One repo exporting several systems that depend on each other, deduplicated | no | yes (`ancestryWalker`), but its own docs call the multi-system API "an advanced API which doesn't work... do not use this unless you are stubborn" | yes, same mechanism, promoted to a documented, supported path |
| Lisp dependency vs. Nix build input | conflated | conflated (`buildInputs = ... ++ ancestry.deps`, flagged in-code as "clearly wrong") | separated: `lispDependencies` never touches `buildInputs` |
| Native library visible to a transitive (2+ hop) consumer | no | no (one hop, and only if the consumer directly depends on a package literally named `cffi`) | yes, propagated through the same dependency graph as everything else |
| Declarative multi-Lisp-implementation test matrix | no | no (hand-maintained `meta.broken` predicate lists) | yes (`mkCheckMatrix`) |
| `.asd` `:version` extraction | no | no ("no QuickLisp database nor .asd file introspection is done whatsoever") | yes (`fromAsdSystem`), fails loudly on an unrecognized shape |
| Cross-platform `program-op` executable delivery | — | — | yes — falls back to `save-lisp-and-die` on Darwin with SBCL, where `program-op` was observed to produce no binary (see below) |
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
directly into the executable. On Darwin with SBCL it instead builds a plain
`.core` via `save-lisp-and-die` and wraps `sbcl --core`.

The evidence for that fallback is one observation, and the docs should not
imply more. On aarch64-darwin with SBCL 2.6.6, a bare
`(asdf:operate 'asdf:program-op "greeter-app")` run under `sbcl --script` had
not completed after five minutes and had written no file at the system's
`:build-pathname`; it was killed at that point. So: "does not finish in a
workable time", not "provably never finishes". A hand-written
`sb-ext:save-lisp-and-die :executable t` on the same host completed in
seconds and produced a working binary, which is what places the fault in
`program-op`'s delivery rather than in SBCL's dumper. No upstream bug ID is
cited because none could be identified with confidence.

That fallback path is also the one CI does not build; see
[Platform coverage](../project/platform-coverage.md).

## What this does not claim

[Non-goals](non-goals.md) lists what `cl-nix-forge` deliberately does not do,
and why each of those is a decision rather than a gap waiting to be filled.
