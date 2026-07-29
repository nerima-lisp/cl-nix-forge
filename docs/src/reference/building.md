# Building systems

## `lispDerivation`

Build and test one or more ASDF systems from a single source tree as a
single Nix derivation. `$out` is source plus compiled fasls side by side —
directly reusable as a `lispDependencies` entry, or as an interactive
`nix develop` shell.

```nix
cl.lispDerivation {
  lispSystem = "my-app";
  src = cl.mkLispSource { root = ./.; };
  version = cl.fromAsdSystem ./my-app.asd;
  lispDependencies = [ ... ];
}
```

Pass exactly one of `lispSystem` (a string) or `lispSystems` (a non-empty
list of strings). Passing both, neither, or a wrong type is an evaluation
error naming what to write instead.

### Dependency arguments

There are four, and they are not interchangeable.

`lispDependencies`

: Other `lispDerivation` results, or foreign derivations wrapped by
[`fromDerivation`](dependencies.md#fromderivation)/[`fromNixpkgsLisp`](dependencies.md#fromnixpkgslisp),
needed at compile and load time. Resolved purely into `CL_SOURCE_REGISTRY`,
never injected into Nix's `buildInputs`. They are nevertheless derivation
inputs — their string context is preserved — so a dependency change still
rebuilds its consumer.

`lispCheckDependencies`

: Like `lispDependencies`, but only pulled in when `doCheck` is true.

`nativeLibraries`

: Producers of shared libraries. Propagates transitively through the same
dependency walk as `lispDependencies`, so a consumer three hops from the
producer still finds the library on
[`libraryPathVar`](dependencies.md#librarypathvar).

`buildInputs` / `nativeBuildInputs`

: Ordinary Nix meaning, untouched.

### Implementation and operation arguments

| Argument | Default | Effect |
|---|---|---|
| `lisp` | `pkgs.sbcl` | The Lisp implementation package to build with |
| `lispImplementation` | `lib.getName lisp` | Which row of the implementation table to use, and the boundary asserted against dependencies |
| `lispAsdPath` | `[ ]` | Extra ASDF search roots, relative to the build tree |
| `lispBuildOp` | `[ "asdf:load-system" ]` | The ASDF operations the build phase performs |
| `CL_SOURCE_REGISTRY` | `""` | A caller registry, prepended to the resolved one |
| `doCheck` | `false` | Run `asdf:test-system` in the same build |

`lispImplementation` is the *package name* of the Lisp, not a free label:
when `lisp` is supplied it defaults to that package's name (for example,
`ecl`), and if it is also set explicitly it must match. A name with no row in
`lib/core/asdf-derivation.nix`'s `lispImplementations` table is rejected
during evaluation of your own expression, not later when a build phase string
is forced.

Every dependency built by cl-nix-forge carries the implementation that
produced its fasls. A consumer using a different one is an evaluation error
rather than a request that ASDF rewrite fasls inside the immutable store.

### What the result carries

Beyond the derivation itself: `enableCheck` (the same derivation with
`doCheck = true`, which every check helper builds on), `lispSystems`,
`registryPath` (the resolved, colon-joined `CL_SOURCE_REGISTRY`),
`nativeLibraries` (transitive), `clNixForgeLispImplementation`, and
`ancestry`.

`meta.broken` propagates: a derivation is broken if any dependency in its
closure is.

## `lispMultiDerivation`

One source tree, several exported ASDF systems as separate Nix outputs,
automatically deduplicated when they depend on each other.

```nix
cl.lispMultiDerivation {
  src = cl.mkLispSource { root = ./.; };
  version = "1.0.0";
  systems = {
    core-a = { };
    core-b = { lispDependencies = [ ... ]; };
  };
}
```

`systems.<name>` is an attrset of extra or overriding arguments for that
system's own `lispDerivation` call; its `lispSystem` defaults to the
attribute name. A per-system `src` is refused — systems here share the
parent's source tree by construction, and distinct trees want distinct
`lispDerivation` calls.

Two systems merge into a single derivation whenever they resolve to the same
dedup key (same source tree, implementation, ASDF operations and dependency
closure) and something depends on both. One derivation has only one
`buildInputs`, one `patches`, one `version`, so such a pair must also agree on
every non-dependency build argument.

Disagreement is an evaluation error naming the offending arguments and both
systems — never a silent pick of one side. Upstream `cl-nix-lite` let
whichever side merged last win, which made the surviving value depend on
dependency-walk order. Give merging systems identical non-dependency
arguments, or model systems with fundamentally different build phases as
separate derivations over separate source trees.

## `mkLispSource`

The `src` a Lisp build should see, as an **allowlist**: `.asd` and `.lisp`
anywhere under `root`, and nothing else.

```nix
src = cl.mkLispSource { root = ./.; };
```

| Argument | Default | Effect |
|---|---|---|
| `root` | required | Project root; a plain path or a store path (a flake's own `self`) both work |
| `extensions` | `[ "asd" "lisp" ]` | Extensions taken as Lisp source anywhere under `root` |
| `include` | `[ ]` | Filesets for anything else the build genuinely reads |
| `exclude` | `[ ]` | Filesets subtracted last |

### Why an allowlist

A denylist over `lib.cleanSourceFilter` is the shape every downstream repo
reached independently, and it is wrong in both directions — silently, in both
directions.

**Too permissive.** `cleanSourceFilter` keeps `.fasl` and `.core` (it only
drops `.o`/`.so`), keeps any directory whose name merely starts with
`result`, and cannot know about the next artefact directory a tool invents. A
working tree that has had `sbcl --script run-tests.lisp` run in it therefore
hashes differently from a clean checkout, so every local test run invalidates
the whole build. Not hypothetical: `cl-weave`'s tree accumulates
`coverage-report-*/` and `watch-forward-dependencies-*/` directories that no
denylist written before those tools existed could have named.

**Too restrictive, apparently.** `cl-prolog`'s filter re-includes `t/` with a
note that `cleanSourceFilter` drops it. It does not — nixpkgs'
`lib/sources.nix` has no rule matching `t`. The test sources really were
missing, but because they were untracked in a Git-backed flake input, which
the same comment goes on to say a filter cannot fix. A denylist gives no way
to tell those two causes apart. An allowlist makes the question moot: `t/`
is kept by the same rule that keeps `src/`, with no clause of its own.

`extensions`, `include` and `exclude` are the escape hatches. A fixture the
build genuinely needs and that is not Lisp source is opted in with `include`,
and its absence then fails loudly at build or test time — whereas a stray
`.fasl` would silently change a hash. The default errs toward the loud
failure.

`extensions` deliberately omits `lsp` and `cl`: a project that uses them
should say so, rather than have the default quietly widen for everyone.

## `lispWithSystems`

A Lisp implementation binary wrapped so it can `(require "asdf")` and load
any of `systems` without further setup — the basis for `lispScript` and for
an interactive, batteries-included REPL.

```nix
cl.lispWithSystems {
  systems = [ myApp ];
  lisp = pkgs.sbcl;   # default
}
```

The wrapper prepends to `CL_SOURCE_REGISTRY` rather than replacing it, so a
caller-supplied registry survives. Each system contributes its own output
*and* its already-computed dependency closure: registering only the roots
would work for a leaf and break the moment an ASDF dependency is loaded at
runtime. Transitive `nativeLibraries` are baked into the wrapper too.

Systems built by cl-nix-forge with a different implementation are refused
during evaluation.

## `lispScript`

A Common Lisp script invoked through a `lispWithSystems` environment, so its
declared ASDF dependencies remain available after installation.

```nix
cl.lispScript {
  name = "my-script";
  src = ./my-script.lisp;
  dependencies = [ myApp ];
}
```

`dependencies` are systems, not files. `lisp` and `lispImplementation` behave
as they do for `lispDerivation`, including the table lookup being forced
during evaluation rather than when the install phase is built. The result
sets `meta.mainProgram` to `name`, which is what makes
[`mkApp`](outputs.md#mkapp) able to find its own entry point.
