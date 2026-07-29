{ lib, pkgs }:
{
  # `lispDerivation`'s own result is already a usable `nix develop` shell
  # (it carries the right buildInputs). `mkDevShell` adds the two things a
  # raw derivation can't -- pulling in extra interactive-only packages (an
  # editor, a linter, a Lisp with competitor libraries to benchmark
  # against) without them becoming part of the *build*, and a short banner
  # so `nix develop` isn't silent about what it just set up -- plus the one
  # thing `inputsFrom` alone gets wrong.
  #
  # That last one: `lispDerivation` exports its search path by having its
  # shellHook `eval "$setAsdfPathPhase"`, and `mkShell` copies shellHook
  # *text* out of `inputsFrom` but not the derivation's environment, so
  # `$setAsdfPathPhase` arrives empty and the eval silently does nothing.
  # The shell's banner claimed CL_SOURCE_REGISTRY was set while it was in
  # fact unset and `(asdf:load-system ...)` failed. Set it here from the
  # derivation's own resolved `registryPath` instead -- same value, same
  # order, including the literal `$PWD` entry that makes the tree you are
  # standing in take precedence, and prepending any registry the caller had
  # already exported exactly as the build does.
  #
  # Deliberately NOT exported: ASDF_OUTPUT_TRANSLATIONS. The build sets it
  # to the identity mapping so fasls land beside their sources and the
  # output stays reusable as a registry entry; a REPL wants the opposite,
  # because fasls dropped into the working tree are precisely the artefacts
  # `mkLispSource` then has to keep back out of the store. Left unset, ASDF
  # caches under ~/.cache/common-lisp.
  #
  # `pkgs.sbcl.withPackages` in `extraPackages` composes correctly, which
  # was not obvious and was checked: `mkShell` puts `packages` ahead of
  # everything from `inputsFrom` on PATH, so the wrapped Lisp wins over the
  # plain one the derivation pulls in, and nixpkgs builds that wrapper with
  # `--prefix CL_SOURCE_REGISTRY` (not `--set`), so its Quicklisp-style
  # packages are prepended to the registry exported here rather than
  # replacing it.
  mkDevShell =
    {
      drv,
      extraPackages ? [ ],
    }:
    pkgs.mkShell {
      inputsFrom = [ drv ];
      packages = extraPackages;
      shellHook = ''
        export CL_SOURCE_REGISTRY="''${CL_SOURCE_REGISTRY:+$CL_SOURCE_REGISTRY:}${drv.registryPath}"
        echo "cl-nix-forge dev shell: ${lib.concatStringsSep ", " (drv.lispSystems or [ "?" ])}"
        echo "CL_SOURCE_REGISTRY is set -- load a system directly, e.g.:"
        echo "  (asdf:load-system \"${lib.head (drv.lispSystems or [ "?" ])}\")"
      '';
    };
}
