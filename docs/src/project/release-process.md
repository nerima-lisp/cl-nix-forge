# Release process

A release here is a git tag, a green build of the tagged tree, and a GitHub
Release whose description is the changelog. There is no `CHANGELOG.md`: the
2026-08-01 revision of the org standard made the Release description the only
canonical history, on the grounds that a file and a Release description
describing the same release is two places to forget.

## Where the version lives

`VERSION`, at the repository root, one line, no `v` prefix.

Every other repository in this org spells its version in the `:version` of
its `.asd`, and [`fromAsdSystem`](../reference/versions.md#fromasdsystem)
reads it from there. `cl-nix-forge` ships no `.asd` — it is Nix, not Lisp —
so it has nothing for that function to read. Until the same revision the
version of record was the first `## [x.y.z]` heading in `CHANGELOG.md`, which
`docs/default.nix` parsed; abolishing that file removed the version source
along with it, and a plain `VERSION` file replaces it.

Two alternatives were rejected:

- **`version = "0.5.0"` in `flake.nix`.** The org conformance rule is
  literally "version is not hardcoded in `flake.nix`".
- **Derive it from the git tag.** Unavailable under pure evaluation, which
  is the only mode `nix flake check` and every consumer's lock file use.

`docs/default.nix` reads `VERSION` and passes it to
[`mkDocsSite`](../reference/outputs.md#mkdocssite), so the published
documentation site carries the release number without a second place to edit.

## What keeps the file and the tag in step

The obvious objection to a `VERSION` file is that a human has to remember to
bump it. That is equally true of a `.asd` `:version`, and it is not the file
format that makes the arrangement safe — it is the gate:

```yaml
# .github/workflows/release.yml
- name: Verify tag matches VERSION
  run: |
    tag="${GITHUB_REF_NAME#v}"
    file="$(tr -d '[:space:]' < VERSION)"
    [ "$tag" = "$file" ]
```

A tag that disagrees with the file fails the release job before anything is
published. Without this step the two drift apart silently, which is the exact
failure the `.asd` rule exists to prevent.

## What the tag gate actually builds

The release job then runs `nix flake check --print-build-logs` on the tagged
tree. `--print-build-logs`, and no `--no-build`: the point is to *build*, not
evaluate. A missing module argument is a lazy error that passes evaluation
and only fails at build time, which is how six checks were once green under
`--no-build` and red in CI.

`checks.default` is the aggregate this repository's own suite hangs from —
the same statement [`mkPackageFlake`](../reference/outputs.md#mkpackageflake)
makes on an adopter's behalf, namely "this package's tests pass". It names
every member of the suite in its build script, so each one enters its input
closure and is built before the command runs, and its output is a manifest of
what was gated:

```sh
nix build .#checks.x86_64-linux.default   # fails if any single check fails
```

`checks.formatting` is deliberately not a member. treefmt over the whole tree
is not a statement about whether the library works, which is why
`mkPackageFlake` also keeps it as a sibling of `default` rather than a
component of it.

`checks.docs` is the same derivation as `packages.docs`: `mkdocs build
--strict` fails on a broken link or a page missing from the nav, so a broken
docs tree fails the release rather than the deploy that follows it.

## Cutting one

1. Decide the number. The public API in `lib/` may change in a breaking way
   in any `0.x` release (see [Home](../index.md#status)); within that, a
   change to what `lib/` exports or to what the flake declares is a minor
   bump, and a fix or a documentation correction is a patch.
2. Bump `VERSION` and merge that to `main` along with the release's content.
3. Tag the merge commit and push the tag:

   ```sh
   git tag -a v0.5.0 -m "cl-nix-forge v0.5.0"
   git push origin v0.5.0
   ```

4. `release.yml` verifies the tag against `VERSION`, builds every check, and
   opens the Release **as a draft with an empty body**. The draft is
   load-bearing: a published release with no notes would make "the maintainer
   forgot the changelog" a user-visible state, and a draft appears neither
   under "Latest release" nor in the default output of `gh release list`.
5. Write the notes and publish:

   ```sh
   gh release edit v0.5.0 --notes-file notes.md --draft=false
   ```

## What a consumer pins

A release tag, never the branch:

```nix
inputs.cl-nix-forge = {
  url = "github:nerima-lisp/cl-nix-forge/v0.5.0";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

A bare `github:nerima-lisp/cl-nix-forge` follows `main`, so a push here would
change a downstream build with no lock-file change to review.
