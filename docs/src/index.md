# cl-nix-forge

`cl-nix-forge` is a Nix flake-library for building, testing, and composing
Common Lisp (ASDF) systems as Nix derivations — the same role
[`crane`](https://github.com/ipetkov/crane) plays for Rust/Cargo.

It is not a package set (it ships no Quicklisp database) and not a
replacement for nixpkgs' own Lisp packaging. It is a small set of composable
functions: point them at a source tree with a `.asd` file and get back a
normal Nix derivation, whose `$out` (source plus compiled fasls, side by
side) is directly usable as another package's dependency.

## Where to go

- **New here** — [Getting started](getting-started.md) builds one system,
  filters its source, adds a check, and delivers a binary.
- **Evaluating it** — [Why cl-nix-forge](guide/why.md) compares it
  point by point with nixpkgs `lisp-modules` and `cl-nix-lite`, and
  [Non-goals](guide/non-goals.md) says what it refuses to do and why.
- **Writing Nix against it** — the [API index](reference/api.md) lists all
  30 exported functions with one line each and a link to the full entry.
  A nerima-lisp package's whole flake is one of them,
  [`mkPackageFlake`](reference/outputs.md#mkpackageflake).
- **Deciding whether to trust it** — [Examples](guide/examples.md) is the
  library's own test suite,
  [Platform coverage](project/platform-coverage.md) states precisely which
  code paths CI verifies and which it does not, and
  [Release process](project/release-process.md) says what a tag has to pass
  before it exists.

## The shape of the library

Everything is reached through `cl-nix-forge.lib.${system}`, one flat attrset.
There is no module system, no overlay to apply first, and no runtime
component inside a Lisp image.

The attrset comes from two directories, and the split is a statement about
what is load-bearing:

`lib/core/`

: The actual differentiators — the ASDF derivation builder, source
filtering, the deduplicating multi-system walk, the native-library
propagation, the dependency-boundary checks, the test matrix. These are the
functions that exist because no prior art provided them.

`lib/batteries/`

: Optional, clearly-secondary conveniences — version extraction, named
checks, coverage reports, dev shells, docs sites, flake output helpers.
Every one of them could be written by hand in a downstream flake; they are
here because every downstream flake was writing the same one.

Each function's entry in the [API index](reference/api.md) names the file it
lives in, so the distinction survives contact with the functional grouping
the reference pages use.

## The three things that make a derivation

```nix
cl.lispDerivation {
  lispSystem = "my-app";     # what ASDF is asked to build
  src = ./.;                 # what it is built from
  lispDependencies = [ ... ]; # what has to be on CL_SOURCE_REGISTRY first
}
```

`$out` is the source tree with its compiled fasls beside it, produced under
an identity `ASDF_OUTPUT_TRANSLATIONS`. That single decision is what makes
the result directly reusable as the next package's registry entry, with no
separate output-translation directory to keep in sync — and it is why a
built system can serve as another derivation's `src` when two systems from
one repository merge.

## Status

The public API in `lib/` may change in a breaking way in any `0.x` release.
It is deliberately not frozen: the library has not yet been applied to a real
repository, and the first three adoptions (`cl-weave`, `cl-prolog`,
`cl-json-kit`) are expected to expose gaps that are better fixed than worked
around. `1.0.0` is the release that follows those migrations, not the one
that precedes them.
