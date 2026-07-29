{ lib }:
let
  mergeAll =
    combine: values:
    if builtins.length values == 1 then
      builtins.head values
    else
      builtins.foldl' combine (builtins.head values) (builtins.tail values);

  # Union many `{ <key> = value; }` attrsets into one, resolving a collision
  # on the same key by folding every value sharing that key through `combine`
  # (left to right). Used below to flatten N dependency subtrees into one
  # map without silently picking an arbitrary winner when two subtrees
  # disagree about the same key.
  unionAttrsBy = combine: attrsets: lib.zipAttrsWith (_name: mergeAll combine) attrsets;
in
{
  inherit unionAttrsBy;

  # The core problem this solves: a single source tree can export several
  # ASDF systems that depend on each other (and, transitively, on systems
  # from OTHER source trees that in turn depend back on the first tree's
  # other systems -- a same-repo dependency cycle once you stop pretending
  # "system" and "repo" are the same granularity). Building each exported
  # system as an independent Nix derivation would recompile the shared
  # source tree once per system and, worse, ASDF would try to rewrite fasls
  # that a sibling derivation already produced from the exact same files.
  #
  # ancestryWalker resolves this by walking the dependency graph and
  # collapsing any two derivations that resolve to the same `key` (normally
  # "the store path of the source tree they were built from") into one, via
  # `merge`. The caller is expected to store the *result* of this function
  # as `me`'s own `passthru.ancestry`, so the walk is incremental: each
  # derivation only needs to inspect its immediate dependencies' already
  # computed `ancestry`, not re-walk the whole graph from scratch.
  #
  #   keyOf        :: derivation -> String       identity of a dependency's source tree.
  #                                               Applied only to `dependencies` entries
  #                                               (already-built values) -- NEVER to `me`,
  #                                               which is still under construction; see
  #                                               `myKey` below for why that distinction
  #                                               is load-bearing, not stylistic.
  #   myKey        :: String                     `me`'s own key, precomputed by the caller
  #                                               from the same inputs `keyOf` would use.
  #                                               Deriving this by calling `keyOf me`
  #                                               instead would read an attribute off `me`
  #                                               from inside `me`'s own definition (`me`'s
  #                                               `passthru.ancestry` is this very value) --
  #                                               nixpkgs' `mkDerivation` forces enough of
  #                                               its argument attrset on attribute access
  #                                               that this becomes a genuine evaluation
  #                                               cycle, not just a lazily-resolved
  #                                               forward reference.
  #   me           :: derivation                 the derivation currently being defined
  #   merge        :: derivation -> derivation -> derivation
  #                                               combine two derivations sharing the same key
  #   dependencies :: [ derivation ]              me's immediate dependencies, each already
  #                                               carrying its own `.ancestry` (i.e. already
  #                                               built via a previous call to this function)
  #
  # Returns `{ merge, me, deps, _depsMap }`:
  #   me       -- either the original `me`, or (if some dependency turned out
  #               to share `me`'s own key -- a same-source-tree cycle) the
  #               result of merging `me` into that dependency instead.
  #   deps     -- the flattened, deduplicated list of every transitive
  #               dependency derivation, excluding `me` itself.
  #   _depsMap -- `deps` as a `{ <key> = derivation; }` map; internal, used
  #               by dependents' own ancestryWalker calls to fold this
  #               subtree into theirs in O(1) rather than re-walking it.
  ancestryWalker =
    {
      keyOf,
      myKey,
      me,
      merge,
      dependencies,
    }:
    let
      entryFor = drv: { ${keyOf drv} = drv; };
      # Each dependency already knows its own transitive deps (`_depsMap`);
      # folding that together with the dependency's own entry gives, for
      # each dependency, its full "subtree as seen from here" in one map.
      subtreeOf = drv: drv.ancestry._depsMap // entryFor drv;
      allSubtreesIncludingMe = unionAttrsBy (a: b: a.ancestry.merge b) (map subtreeOf dependencies);
      depsMap = removeAttrs allSubtreesIncludingMe [ myKey ];
    in
    {
      inherit merge;
      me = if allSubtreesIncludingMe ? ${myKey} then merge allSubtreesIncludingMe.${myKey} else me;
      _depsMap = depsMap;
      deps = builtins.attrValues depsMap;
    };
}
