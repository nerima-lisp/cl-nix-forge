{
  cl,
  pkgs,
  lib,
}:
let
  matrixProbe = pkgs.writeShellScriptBin "matrix-probe" ''
    printf '%s\n' 'matrix-probe: ready'
  '';
in
{
  checks = cl.mkCheckMatrix {
    args = {
      lispSystem = "matrix-demo";
      version = cl.fromAsdSystem ./matrix-demo.asd;
      src = ./.;
    };
    lisps = [
      "sbcl"
      "ecl"
    ];
    lispPackages = {
      sbcl = pkgs.sbcl;
      ecl = pkgs.ecl;
    };
    externalBins = [ matrixProbe ];
  };
}
