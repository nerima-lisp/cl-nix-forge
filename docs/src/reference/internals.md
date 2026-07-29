# Internals

These two are exported and supported, but they are public *implementation
support* rather than the API to reach for first. Prefer
[`lispDerivation`](building.md#lispderivation) and
[`lispMultiDerivation`](building.md#lispmultiderivation), which drive
`ancestryWalker` for you. Reach here when you are building something the
library does not yet cover, or reading the deduplication code and wanting the
contract stated.

## `ancestryWalker`

The dependency walk that collapses derivations built from the same source
tree into one.

### The problem it solves

A single source tree can export several ASDF systems that depend on each
other — and, transitively, on systems from other source trees that depend
back on the first tree's other systems. That is a same-repository dependency
cycle, which appears as soon as you stop pretending "system" and "repository"
are the same granularity.

Building each exported system as an independent Nix derivation would
recompile the shared source tree once per system and, worse, ASDF would try
to rewrite fasls that a sibling derivation already produced from the exact
same files.

`ancestryWalker` walks the dependency graph and collapses any two derivations
that resolve to the same `key` — normally the store path of the source tree
they were built from — into one, via `merge`.

### Contract

| Argument | Type | Meaning |
|---|---|---|
| `keyOf` | `derivation -> String` | Identity of a dependency's source tree. Applied only to `dependencies` entries, never to `me` |
| `myKey` | `String` | `me`'s own key, precomputed by the caller from the same inputs `keyOf` would use |
| `me` | `derivation` | The derivation currently being defined |
| `merge` | `derivation -> derivation -> derivation` | Combine two derivations sharing a key |
| `dependencies` | `[ derivation ]` | `me`'s immediate dependencies, each already carrying its own `ancestry` |

The caller is expected to store the *result* as `me`'s own
`passthru.ancestry`, so the walk is incremental: each derivation only
inspects its immediate dependencies' already-computed `ancestry`, never
re-walking the whole graph.

`myKey` being an argument rather than `keyOf me` is load-bearing, not
stylistic. Deriving it by calling `keyOf me` would read an attribute off `me`
from inside `me`'s own definition — `me`'s `passthru.ancestry` is this very
value — and nixpkgs' `mkDerivation` forces enough of its argument attrset on
attribute access that this becomes a genuine evaluation cycle, not a lazily
resolved forward reference.

### Result

`me`

: Either the original `me`, or — if some dependency turned out to share
`me`'s own key, a same-source-tree cycle — the result of merging `me` into
that dependency instead.

`deps`

: The flattened, deduplicated list of every transitive dependency
derivation, excluding `me`.

`merge`

: The combiner, carried along so dependents can fold this subtree into
theirs.

`_depsMap`

: `deps` as a `{ <key> = derivation; }` map. Internal, used by dependents'
own `ancestryWalker` calls to fold this subtree in at O(1) rather than
re-walking it.

### How `lispDerivation` keys it

Source identity alone would incorrectly merge SBCL and ECL fasls, so the key
is source identity *plus* implementation name, the Lisp package's own
identity, the host platform, `lispAsdPath`, `lispBuildOp`, any caller
`CL_SOURCE_REGISTRY`, `doCheck`, and the dependency closures. A source tree
can safely share compiled output only when every registry entry that can
affect compilation is identical.

## `unionAttrsBy`

Union many `{ <key> = value; }` attrsets into one, resolving a collision on
the same key by folding every value sharing that key through `combine`, left
to right.

```nix
cl.unionAttrsBy combine [ attrsA attrsB attrsC ]
```

`ancestryWalker` uses it to flatten N dependency subtrees into one map
without silently picking an arbitrary winner when two subtrees disagree about
the same key. That "no arbitrary winner" property is the whole reason it
exists as a named function rather than a `//` fold.
