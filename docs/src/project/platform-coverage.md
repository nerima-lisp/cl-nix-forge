# Platform coverage

This page states what is verified, by what, and what is not. It exists
because the answer is not symmetric across platforms, and a reader deciding
whether to depend on this library deserves the asymmetry stated rather than
discovered.

## What the flake declares

`flake.nix` declares two systems:

- `x86_64-linux` — exercised by CI
- `aarch64-darwin` — exercised by local development

Nothing else is advertised, because nothing else is verified.

## What CI does

`.github/workflows/ci.yml` has a single job, `flake-check`, on
`ubuntu-latest`. It runs two steps:

1. `nix flake check --all-systems --no-build --no-write-lock-file` —
   *evaluates* every declared system, including `aarch64-darwin`. This is
   what catches an evaluation-time assertion that only fires on a platform
   the runner is not standing on.
2. A loop that `nix build`s every check for the host system — that is,
   `x86_64-linux` and nothing else.

So `aarch64-darwin` is evaluated by CI and **built** by no one but a
developer running `nix flake check` on a Mac.

## The consequence, stated plainly

`lib/batteries/app.nix` branches on `isDarwin && sbcl`. A Linux runner
therefore only ever executes the `asdf:program-op` delivery path. The Darwin
`save-lisp-and-die` fallback — the branch that exists precisely because
`program-op` was observed to produce no binary on aarch64-darwin — is
verified by local `nix flake check` alone, never by CI.

That is the coverage gap. It is not "lightly tested"; it is "tested by
whoever last ran the suite on a Mac, and by no automated gate".

The observation that motivated the fallback is itself a single data point:
aarch64-darwin, SBCL 2.6.6, no binary at the system's `:build-pathname` after
five minutes, killed at that point. "Not workable", not "provably never
terminates", and no upstream bug ID could be identified with confidence. See
[`mkExecutable`](../reference/outputs.md#mkexecutable) for the full record.

## Closing it

Building the `aarch64-darwin` checks in CI needs a macOS runner. Until there
is one, the honest statement is the one above.

## The other platform branch

`lib/` contains exactly two conditionals on the host platform. The second is
[`libraryPathVar`](../reference/dependencies.md#librarypathvar), which
resolves to `DYLD_LIBRARY_PATH` on Darwin and `LD_LIBRARY_PATH` elsewhere.
Everything downstream of it — `nativeLibraryEnv`,
`nativeLibraryWrapperArgs`, and therefore the whole native-library
propagation path exercised by `examples/native-library-consumer/` — runs on
CI with the Linux spelling only. The Darwin spelling has the same local-only
coverage as the fallback above, though it is one string rather than a
delivery strategy.

## Everything else

The remaining checks take the same code path on both systems: the examples
that build and test ASDF systems, the source filter, the deduplication walk,
the version extractor, the check helpers and this documentation site. All of
them are built on `x86_64-linux` by CI on every push and pull request.
