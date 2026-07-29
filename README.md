# cl-nix-forge

[![CI](https://github.com/nerima-lisp/cl-nix-forge/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/nerima-lisp/cl-nix-forge/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Documentation](https://img.shields.io/badge/docs-MkDocs%20Material-0a7a5a)](docs/src/index.md)

`cl-nix-forge` is a Nix flake-library for building, testing, and composing
Common Lisp (ASDF) systems as Nix derivations — the same role
[`crane`](https://github.com/ipetkov/crane) plays for Rust/Cargo.

It is not a package set (it ships no Quicklisp database) and not a
replacement for nixpkgs' own Lisp packaging. It is a small set of composable
functions: point them at a source tree with a `.asd` file and get back a
normal Nix derivation, whose `$out` (source plus compiled fasls, side by
side) is directly usable as another package's dependency.

## Quick Start

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

[Getting started](docs/src/getting-started.md) continues from here: filtering
the source, adding a check, and delivering an executable.

## Install

As a flake input, pinned to a release tag:

```nix
inputs.cl-nix-forge = {
  url = "github:nerima-lisp/cl-nix-forge/v0.1.0";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

A bare `github:nerima-lisp/cl-nix-forge` follows this repository's default
branch, so a push here would change your build without warning.

The library is `cl-nix-forge.lib.${system}`, a flat attrset of 28 functions.
There is nothing to install into a Lisp image and no runtime component.

## Why not nixpkgs' `sbcl.buildASDFSystem`, or `cl-nix-lite`?

Both are real, usable options, and this project owes its build primitive to
both. `cl-nix-forge` exists because of gaps neither closes:

- **Multi-system repositories are a supported path.** One source tree
  exporting several interdependent ASDF systems builds as one deduplicated
  derivation. `cl-nix-lite` has the same mechanism, but its own docs call
  that API "an advanced API which doesn't work... do not use this unless you
  are stubborn".
- **A Lisp dependency is not a Nix build input.** `lispDependencies` enter
  `CL_SOURCE_REGISTRY` and never `buildInputs`. Both prior options conflate
  the two.
- **Native libraries propagate transitively.** A CFFI-loaded `.so` stays
  findable two or more hops from its producer, through the same dependency
  graph as everything else.
- **A multi-implementation test matrix is declarative** (`mkCheckMatrix`),
  rather than a hand-maintained `meta.broken` predicate list.
- **`.asd` `:version` extraction** (`fromAsdSystem`) that fails loudly on an
  unrecognized shape, rather than no `.asd` introspection at all.

The full point-by-point comparison, including what each project does better,
is in [Why cl-nix-forge](docs/src/guide/why.md). What this library
deliberately refuses to do — per-file FASL caching, lockfile version
unification, Quicklisp dist fetching, cross-compilation — is in
[Non-goals](docs/src/guide/non-goals.md), with the reasoning for each.

## Documentation

The documentation source lives in [docs/src/](docs/src/) and builds with
`mkdocs build --strict`.

- [Getting started](docs/src/getting-started.md)
- [Why cl-nix-forge](docs/src/guide/why.md) — the comparison table
- [Non-goals](docs/src/guide/non-goals.md)
- [Examples](docs/src/guide/examples.md) — the eight worked examples in
  `examples/`, which double as this library's own test suite
- [API reference](docs/src/reference/api.md) — all 28 exported functions
- [Platform coverage](docs/src/project/platform-coverage.md) — what CI
  verifies and what it does not

## Development

```sh
nix flake check          # build and verify this host's checks
nix fmt                  # treefmt/nixfmt, gated by checks.formatting
nix build .#docs         # the documentation site
```

`nix flake check --all-systems --no-build --no-write-lock-file` evaluates
every declared system without attempting cross-platform builds. CI runs both,
but builds only on `x86_64-linux`; see
[Platform coverage](docs/src/project/platform-coverage.md) for the gap that
leaves.

`examples/` is the test suite. A change to `lib/` that no example exercises
is a change nothing verifies.

## Contributing

Issues and pull requests are welcome at
<https://github.com/nerima-lisp/cl-nix-forge>. `nix flake check` must pass,
and behaviour changes need an example that would have caught the old
behaviour.

## Support

Report bugs at <https://github.com/nerima-lisp/cl-nix-forge/issues>.

## License

MIT — see [LICENSE](LICENSE).
