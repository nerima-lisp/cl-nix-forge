{
  cl,
  pkgs,
  lib,
}:
let
  asdSearchPath = cl.lispDerivation {
    lispSystem = "asd-search-path";
    version = cl.fromAsdSystem ./src/asd/asd-search-path.asd;
    src = ./src;
    lispAsdPath = [ "asd" ];
    doCheck = true;
  };
in
{
  packages.asd-search-path = asdSearchPath;
  checks.asd-search-path = asdSearchPath;
}
