# Dependencies and native libraries

## Consuming packages this library did not build

### `fromDerivation`

Wrap an arbitrary Nix derivation — a Quicklisp-packaged library from nixpkgs,
the output of an unrelated project's hand-written flake, anything — as a
`lispDependencies`-compatible leaf.

```nix
cl.fromDerivation {
  drv = someForeignPackage;
  recursive = false;
  nativeLibraries = [ ];
  lispImplementation = null;
}
```

| Argument | Default | Effect |
|---|---|---|
| `drv` | required | The foreign package |
| `recursive` | `false` | Append `//` so ASDF searches `$out`'s whole subtree for `.asd` files, not just `$out` itself |
| `nativeLibraries` | `[ ]` | Declare that this package itself provides native libraries |
| `lispDependencies` | `[ ]` | Dependencies of the wrapped package, if it has them |
| `lispImplementation` | `null` | Which implementation built any fasls inside |

A generic foreign derivation is an opaque leaf: its output directory joins
`CL_SOURCE_REGISTRY`, but it contributes no inferred Lisp dependencies,
because it might not be ASDF-based by the time it reaches `$out`. If its own
`$out/lib` holds a `.so`/`.dylib` that a Lisp consumer will `dlopen`, say so
with `nativeLibraries = [ drv ]` — cl-nix-forge cannot detect this for a
package it did not build.

`lispImplementation` is optional *here* because `fromDerivation`
deliberately wraps outputs containing no Lisp at all: a C shared library, a
data directory, some foreign flake's binary. Those have no implementation to
name, and demanding one would only teach callers to invent an answer. Two
properties keep the omission from being a hole. Wrapping something
cl-nix-forge built preserves its recorded implementation without the caller
restating it; and *contradicting* an inherited value is an assertion failure,
not a silent relabel of somebody else's fasls.

### `fromNixpkgsLisp`

Shorthand for the common case of pulling in a Quicklisp-packaged nixpkgs
library.

```nix
lispDependencies = [
  (cl.fromNixpkgsLisp {
    drv = pkgs.sbcl.pkgs.alexandria;
    lispImplementation = "sbcl";
  })
];
```

Both arguments are required, and there is deliberately no bare-derivation
shorthand — passing one is an error that says what to write instead, rather
than the opaque "called without required argument" a destructuring pattern
would produce. Everything this function wraps is a precompiled Lisp package
whose fasls belong to exactly one implementation. A shorthand letting the
caller leave that unsaid would be a one-character way to opt out of the
boundary `lispDerivation` enforces — and that check is the whole reason a
consumer built with a different implementation fails during evaluation
instead of asking ASDF to rewrite fasls inside the immutable store.

It defaults to `recursive = true` and does not offer the argument: nixpkgs'
own ASDF builder copies a package's whole build tree into `$out`, and unlike
cl-nix-forge's convention of keeping every system's `.asd` at the source
root, several real Quicklisp systems (cffi's grovel and toolchain
subsystems, for instance) keep secondary `.asd` files in subdirectories.
`propagatedBuildInputs` are wrapped recursively, so a dependency's `.asd`
stays discoverable to ASDF without any of them entering `buildInputs`.

## Native libraries

The gap these close: a Lisp dependency that also builds a native
`.so`/`.dylib` has, in prior art, no way to make that fact visible more than
one hop away. Every transitive consumer has to know by name which of its
dependencies-of-dependencies produced the library and hand-copy a search-path
line for it.

`lib/core/native.nix` does not walk the dependency graph itself.
`lib/core/asdf-derivation.nix` already walks it once for `lispDependencies`,
and reuses that exact walk to fold in each dependency's own
already-transitive `nativeLibraries`. These functions only turn the resulting
flat list of producer derivations into the right form for whichever
consumption point needs it: a build/check environment, an interactive dev
shell, or a delivered executable's wrapper. Explicit data flow instead of
nixpkgs setup-hook chaining, so propagation depth is never a surprise.

Of the five, only `markNativeLibrary` is normally called by hand. The other
four are the low-level loader helpers `lispDerivation`, `lispWithSystems` and
`mkExecutable` apply for you; they stay public — like
[`ancestryWalker`](internals.md#ancestrywalker) — for the case where you are
building something this library does not yet cover, and are documented here
so that use is against a stated contract rather than a read of the source.

### `markNativeLibrary`

Marks a derivation that itself produces a native library — its `$out/lib`
holds a `.so`/`.dylib` — as a `nativeLibraries` entry for consumers.

```nix
natlib = cl.markNativeLibrary (pkgs.stdenv.mkDerivation { ... });
```

Most producers just need `passthru.nativeLibraries = [ finalDrv ]`, spelled
out at the call site rather than forced through one more layer of
indirection. This helper exists for the common case of wrapping a plain
`stdenv.mkDerivation` with no other cl-nix-forge involvement — a pure-C
shared library with no Lisp code of its own. It sets the attribute both
directly and in `passthru`, because consumers read it directly and attrset
extension does not promote `passthru` the way `mkDerivation` does.

### `nativeLibraryPath`

`<drv>/lib` directories for a list of producer derivations, `:`-joined into
one string.

### `nativeLibraryEnv`

The same directories as an attrset suitable for a derivation's `env`, so a
test suite that `dlopen`s a transitively-declared native library finds it
without a hand-copied `preBuild` hook.

An empty input produces an empty attrset, not an environment variable set to
the empty string.

Setting the search-path variable in `env` yourself while `nativeLibraries`
are present is refused by `lispDerivation`, with a message pointing at a
wrapper or at adding the library to `nativeLibraries` — because the two would
otherwise silently overwrite each other.

### `nativeLibraryWrapperArgs`

`makeWrapper` arguments (`--suffix <var> : <path>`) that bake the same search
path into a delivered executable, so it keeps resolving its native libraries
after leaving the Nix build sandbox. This is what
[`mkExecutable`](outputs.md#mkexecutable) and
[`lispWithSystems`](building.md#lispwithsystems) apply.

Also empty for an empty input, so an unconditional splice into a
`makeWrapper` invocation stays correct.

### `libraryPathVar`

The runtime-loader search-path variable for the host platform:
`DYLD_LIBRARY_PATH` on Darwin, `LD_LIBRARY_PATH` elsewhere. Exported so a
consumer writing its own wrapper spells the platform condition the same way
the library does, instead of a second time.
