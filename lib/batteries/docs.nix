{ lib, pkgs }:
{
  # A generic mkdocs-material site builder. Deliberately doesn't guess at
  # any one project's fileset shape: pass `fileset` (built with
  # `lib.fileset.unions`/etc., same as any other Nix project) when the docs
  # need something outside `root` -- a repo whose config is at
  # docs/mkdocs.yml but whose pages include a file from the repository root
  # passes `root = ./.`, a `fileset` naming both, and
  # `mkdocsYmlName = "docs/mkdocs.yml"` -- and plain `root` for the common
  # single-directory case. This one optional argument is what collapses
  # "two docs conventions that grew independently because nobody wanted to
  # touch the other one's derivation" into one function.
  #
  # Identity is the caller's, not this function's. The site is a package a
  # project publishes under its own name and version -- it appears in
  # `nix flake show`, in a store path, and in whatever deploys it -- so
  # baking in "docs-site"/"unstable" made every consumer that cared reject
  # the helper and hand-write the derivation again. `version` pairs
  # naturally with `fromAsdSystem`, so the .asd stays the one place a
  # release number is edited.
  #
  #   root         :: the directory `mkdocsYmlName` lives in.
  #   fileset      :: fileset ? null -- see above.
  #   pname        :: String ? "docs-site" -- by convention "<project>-docs".
  #   version      :: String ? "unstable" -- nixpkgs' spelling of "no
  #                   meaningful version", so an omitted version still
  #                   produces a well-formed derivation name.
  #   meta         :: attrs ? { } -- description/homepage/license.
  #   strict       :: Bool ? true -- promote broken links and pages missing
  #                   from the nav to build failures. Material bundles its
  #                   own assets, so the build needs no network either way.
  #   mkdocsYmlName :: String ? "mkdocs.yml".
  mkDocsSite =
    {
      root,
      fileset ? null,
      pname ? "docs-site",
      version ? "unstable",
      meta ? { },
      strict ? true,
      mkdocsYmlName ? "mkdocs.yml",
    }:
    pkgs.stdenvNoCC.mkDerivation {
      inherit pname version meta;
      src = if fileset != null then lib.fileset.toSource { inherit root fileset; } else root;
      nativeBuildInputs = [ pkgs.python3Packages.mkdocs-material ];
      buildPhase = ''
        runHook preBuild
        mkdocs build ${lib.optionalString strict "--strict"} --config-file ${mkdocsYmlName} --site-dir "$out"
        runHook postBuild
      '';
      dontInstall = true;
    };
}
