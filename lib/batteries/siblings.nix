{ lib }:
{
  # The real fix for cross-repo composition isn't a bigger helper -- once a
  # sibling repo's own flake exposes its package as an ordinary
  # `lispDependencies` entry (see external.nix and core/dedup.nix), no
  # bespoke registry-string merging code is needed at all. This is only a
  # naming-convention shorthand for the common shape "pull the default
  # package out of each of these flake inputs by name," so a downstream
  # flake doesn't reinvent yet another way to spell that.
  #
  #   flakeInputs :: the calling flake's own `inputs` (or a subset)
  #   names       :: [ String ] -- attribute names shared by both
  #                  `flakeInputs` and each input's own `packages.<system>`
  #   system      :: String
  collect =
    {
      flakeInputs,
      names,
      system,
    }:
    lib.genAttrs names (name: flakeInputs.${name}.packages.${system}.default);
}
