{
  cl,
  pkgs,
  lib,
}:
let
  checkSupport = cl.lispDerivation {
    lispSystem = "check-only-support";
    version = cl.fromAsdSystem ./support/check-only-support.asd;
    src = ./support;
  };

  baseArgs = {
    lispSystem = "check-only-main";
    version = cl.fromAsdSystem ./main/check-only-main.asd;
    src = ./main;
    lispCheckDependencies = [ checkSupport ];
  };

  unchecked = cl.lispDerivation baseArgs;
  checked = cl.lispDerivation (baseArgs // { doCheck = true; });
in
{
  packages.check-only-main = unchecked;

  # The checked derivation loads the support system only through the ASDF
  # test system. The normal build remains free of that dependency closure.
  checks.check-only-dependencies = checked;
  checks.check-only-dependencies-are-check-only =
    assert unchecked.ancestry.deps == [ ];
    assert checked.ancestry.deps == [ checkSupport ];
    pkgs.runCommand "check-only-dependencies-are-check-only" { } "touch $out";
}
