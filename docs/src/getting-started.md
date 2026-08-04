# Getting started

## Add the flake input

```nix
{
  inputs.cl-nix-forge = {
    url = "github:nerima-lisp/cl-nix-forge/v0.4.2";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

Pin a release tag. A bare `github:nerima-lisp/cl-nix-forge` follows this
repository's default branch, so a push upstream would change your build
without warning. `inputs.nixpkgs.follows` keeps one nixpkgs in the closure
rather than two.

## Build one system

```nix
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
```

Three things are worth naming in that snippet.

`version = cl.fromAsdSystem ./my-app.asd` reads the `:version` your `.asd`
already declares, so a release edits one file. See
[`fromAsdSystem`](reference/versions.md#fromasdsystem).

`lispDependencies` is a *Lisp* dependency list. It resolves into
`CL_SOURCE_REGISTRY` and never into `buildInputs`. `buildInputs` and
`nativeBuildInputs` keep their ordinary Nix meanings and are still available
to you.

`fromNixpkgsLisp` requires `lispImplementation` explicitly. The package it
wraps contains fasls belonging to exactly one implementation, and a consumer
built with another one has to fail during evaluation rather than ask ASDF to
rewrite files inside the immutable store. See
[Dependencies](reference/dependencies.md#fromnixpkgslisp).

## Filter the source

`src = ./.` hashes everything in the directory, including the `.fasl` files a
local `sbcl --script run-tests.lisp` just dropped there. Use
[`mkLispSource`](reference/building.md#mklispsource) instead:

```nix
src = cl.mkLispSource { root = ./.; };
```

That is an allowlist: `.asd` and `.lisp` anywhere under `root`, and nothing
else. A fixture the build genuinely needs is opted in explicitly:

```nix
src = cl.mkLispSource {
  root = ./.;
  include = [ ./docs ./t/fixtures ];
};
```

## Add a check

The derivation can run its own `asdf:test-system` in the same sandboxed
build:

```nix
checks.${system}.my-app = cl.mkTestCheck self.packages.${system}.default;
```

If the suite cannot be driven by an enclosing `test-op`, or needs a time
limit, use [`mkScriptCheck`](reference/checks.md#mkscriptcheck), which
defaults to the org-standard `run-tests.lisp` entry point:

```nix
checks.${system}.my-app = cl.mkScriptCheck {
  drv = self.packages.${system}.default;
  timeoutSeconds = 600;
};
```

To run the same suite under more than one implementation, use
[`mkCheckMatrix`](reference/checks.md#mkcheckmatrix) rather than a
`meta.broken` predicate list.

## Deliver an executable

```nix
packages.${system}.my-cli = cl.mkExecutable {
  args = {
    pname = "my-cli";
    lispSystem = "my-app";
    version = cl.fromAsdSystem ./my-app.asd;
    src = cl.mkLispSource { root = ./.; };
    lispDependencies = [ ... ];
  };
};

apps.${system}.my-cli = cl.mkApp { drv = self.packages.${system}.my-cli; };
```

What a binary *is* stays in the `.asd`: `:build-operation`, `:entry-point`
and `:build-pathname` have no Nix option here, because a system with two
places to declare its own entry point has two places to disagree. See
[`mkExecutable`](reference/outputs.md#mkexecutable).

Add `installSource = true;` when the image loads a system at run time rather
than only running what was dumped into it. It installs the sources and their
dependency closure under the binary's own prefix, which is where an image
looking for `share/common-lisp/source/` next to itself will find them; see
[what `$out` contains](reference/outputs.md#what-out-contains-and-what-an-image-may-assume).

## The rest of a flake

[Flake outputs and delivery](reference/outputs.md) covers `mkTestApp`
(`nix run .#test`), `mkOverlay`, `mkDevShell`, `mkDocsSite` and `collect` —
the outputs a downstream repository writes once and then stops thinking
about. [`examples/flake-outputs/`](guide/examples.md) is a worked version of
exactly that surface.

If the repository is a nerima-lisp package, do not assemble those by hand:
[`mkPackageFlake`](reference/outputs.md#mkpackageflake) generates all of them
— plus the formatter, the docs check and the test app — from the `.asd` and a
source root, and every page above then describes an argument rather than a
call you write.
