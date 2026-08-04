# Platform coverage

This page states what is verified, by what, and what is not. It exists
because the answer is not symmetric across code paths, and a reader deciding
whether to depend on this library deserves the asymmetry stated rather than
discovered.

## What the flake declares

`flake.nix` declares two systems:

- `x86_64-linux` — built by CI on every push and pull request
- `aarch64-darwin` — the development machine; built by nobody but a
  developer running `nix build` or `nix develop` locally

The list has changed twice in three days, and the reason is worth recording
because the two entries carry different guarantees. The 2026-08-01 revision
of the org package standard dropped `aarch64-darwin`, on the grounds that
declaring a platform is a promise to support it, and the only thing backing
that promise was a developer's own machine — nothing any gate enforced. That
reasoning still holds. It was reverted the next day anyway, because
`mkPackageFlake` generates `packages`, `checks`, `apps`, *and* `devShells`
from this one list: dropping `aarch64-darwin` from `systems` did not just
remove an unverified package, it removed `devShells.aarch64-darwin` too,
taking `nix build` and `nix develop` off the development machine along with
everything else. The cost of that consistency outweighed what it bought.

**`aarch64-darwin` carries no CI gate, and the org standard accepts this
explicitly.** Its only guarantee is that a developer runs it day to day; a
change that breaks only `aarch64-darwin` passes CI clean. Declaring it
anyway is a bet that a working `nix develop` on the maintainer's machine is
worth more than the inconsistency of an unverified platform in the list.
Adding a macOS runner to CI would remove the need for that bet.

The list is this repository's own, for its examples and its documentation
site. It is **not** the list an adopter passes to
[`mkPackageFlake`](../reference/outputs.md#mkpackageflake): that one belongs
to the adopter's flake, and `mkPackageFlake` iterates whatever it is given.

## What CI does

`.github/workflows/ci.yml` has a single job, `check`, on `ubuntu-latest`. It
runs two steps:

1. `nix flake check --no-build --no-write-lock-file` — *evaluates* the
   outputs for the runner's own system, `x86_64-linux`. Without
   `--all-systems`, `nix flake check` scopes itself to the current system by
   default, so `aarch64-darwin` is neither evaluated nor built here. The
   package standard forbids `--all-systems` outright: `ubuntu-latest` cannot
   produce an `aarch64-darwin` derivation, so passing it would fail on a
   platform mismatch rather than widen coverage.
2. A loop that `nix build`s every check for the host system — that is,
   `x86_64-linux`.

Evaluation and build therefore cover the same set, `x86_64-linux` alone.
`aarch64-darwin` is exercised by nothing CI does; its only verification is a
developer running `nix build` or `nix flake check` on that architecture
locally.

## The consequence, stated plainly

`lib/batteries/app.nix` branches on `isDarwin && sbcl`. A Linux runner
therefore only ever executes the `asdf:program-op` delivery path. The Darwin
`save-lisp-and-die` fallback — the branch that exists precisely because
`program-op` was observed to produce no binary on aarch64-darwin — is
verified by nothing at all.

That is the coverage gap. Dropping `aarch64-darwin` from the declared systems
did not create it; it stopped the declaration from implying it was covered.
The branch is kept because an adopter may still declare `aarch64-darwin` in
their own `systems`, and on that platform the fallback is what makes
`mkExecutable` produce a binary.

The observation that motivated the fallback is itself a single data point:
aarch64-darwin, SBCL 2.6.6, no binary at the system's `:build-pathname` after
five minutes, killed at that point. "Not workable", not "provably never
terminates", and no upstream bug ID could be identified with confidence. See
[`mkExecutable`](../reference/outputs.md#mkexecutable) for the full record.

## Closing it

Building the Darwin path in CI needs a macOS runner. Until there is one, the
honest statement is the one above.

## The other platform branch

`lib/` contains exactly two conditionals on the host platform. The second is
[`libraryPathVar`](../reference/dependencies.md#librarypathvar), which
resolves to `DYLD_LIBRARY_PATH` on Darwin and `LD_LIBRARY_PATH` elsewhere.
Everything downstream of it — `nativeLibraryEnv`,
`nativeLibraryWrapperArgs`, and therefore the whole native-library
propagation path exercised by `examples/native-library-consumer/` — runs on
CI with the Linux spelling only. The Darwin spelling has the same
unverified status as the fallback above, though it is one string rather than
a delivery strategy.

## Everything else

The remaining checks take the same code path on either system: the examples
that build and test ASDF systems, the source filter, the deduplication walk,
the version extractor, the check helpers and this documentation site. All of
them are built on `x86_64-linux` by CI on every push and pull request, and
`checks.default` aggregates them so that one build fails if any single one
does — see [Release process](release-process.md#what-the-tag-gate-actually-builds).
