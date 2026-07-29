# This library's own documentation site, built by this library's own
# `mkDocsSite`. A Nix docs helper whose author hand-rolled a derivation to
# build its own docs would be evidence against the helper.
#
# Shaped like `examples/*/default.nix` -- `{ cl, pkgs, lib }` in, `packages`
# and `checks` out -- so `flake.nix` merges it exactly the way it merges an
# example, duplicate-name guard included.
{
  cl,
  lib,
  ...
}:
let
  # cl-nix-forge has no `.asd`, so `fromAsdSystem` has nothing to read here
  # and CHANGELOG.md is the repository's only version of record. Same
  # technique the org standard prescribes for `.asd` files: split into lines
  # first, because Nix's regexes are anchored to the whole string and `.`
  # does not cross a newline. The first `## [x.y.z] - date` heading is the
  # most recent release; `## [Unreleased]` does not match the digit-dot
  # shape and is skipped.
  #
  # A CHANGELOG whose heading format drifts fails the docs build loudly
  # rather than publishing a site labelled with the wrong version.
  #
  # The brackets are spelled `[[]`/`[]]` rather than `\[`/`\]`: Nix compiles
  # POSIX extended regexes, which reject a backslash-escaped bracket outright
  # ("invalid regular expression"), while a bracket expression containing the
  # literal is portable.
  releaseHeadingPattern = "## [[]([0-9]+[.][0-9]+[.][0-9]+)[]].*";
  changelogLines = lib.splitString "\n" (builtins.readFile ../CHANGELOG.md);
  releaseHeadings = builtins.filter (
    line: builtins.match releaseHeadingPattern line != null
  ) changelogLines;
  version =
    if releaseHeadings == [ ] then
      throw "cl-nix-forge docs: no `## [x.y.z] - date` heading found in CHANGELOG.md"
    else
      builtins.head (builtins.match releaseHeadingPattern (builtins.head releaseHeadings));

  site = cl.mkDocsSite {
    root = ./.;
    pname = "cl-nix-forge-docs";
    inherit version;
    meta = {
      description = "Documentation for cl-nix-forge";
      homepage = "https://nerima-lisp.github.io/cl-nix-forge/";
      license = lib.licenses.mit;
    };
  };
in
{
  packages.docs = site;

  # `checks.docs` and `packages.docs` are the same derivation on purpose.
  # `mkdocs build --strict` turns a broken link or a page missing from the
  # nav into a build failure, and without it in `checks` the first sign of a
  # broken docs tree would be a failed deploy after the merge.
  checks.docs = site;
}
