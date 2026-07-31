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
  # The single source of truth for this repository's version.
  #
  # cl-nix-forge has no `.asd`, so `fromAsdSystem` has nothing to read. Until
  # the 2026-08-01 revision the version of record was the first
  # `## [x.y.z] - date` heading in CHANGELOG.md; that revision abolished
  # CHANGELOG.md org-wide, which briefly left this repository with no version
  # source at all.
  #
  # A plain VERSION file replaces it. The objection to one -- that a tracked
  # file has to be kept in step with the tag by hand -- applies just as much to
  # a `.asd` `:version`, which is what every other repository here uses. What
  # makes that arrangement safe is not the file format but the gate:
  # release.yml refuses to publish a tag that disagrees with the file. The same
  # gate is wired to this file, so the two cannot drift silently.
  #
  # Not flake.nix: a `version = "0.4.0"` attribute there trips the conformance
  # rule "version is not hardcoded in flake.nix". Not the git tag: it is
  # unavailable under pure evaluation.
  version = lib.removeSuffix "\n" (builtins.readFile ../VERSION);

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
