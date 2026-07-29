{ lib, pkgs }:
let
  libraryPathVar =
    if pkgs.stdenv.hostPlatform.isDarwin then "DYLD_LIBRARY_PATH" else "LD_LIBRARY_PATH";

  libDirsOf = nativeLibraries: map (drv: "${drv}/lib") nativeLibraries;
in
{
  inherit libraryPathVar;

  # The gap this closes: a Lisp dependency that happens to also build a
  # native `.so`/`.dylib` (e.g. via CFFI) has no way, in any prior art, to
  # make that fact visible more than one hop away -- every transitive
  # consumer has to know, by name, which of ITS dependencies-of-dependencies
  # produced a native library and hand-copy an LD_LIBRARY_PATH line for it.
  #
  # This module doesn't walk the dependency graph itself -- asdf-derivation.nix
  # already does that once, for lispDependencies, and reuses the exact same
  # walk to fold in each dependency's own (already-transitive)
  # `nativeLibraries` list. This module only turns the resulting flat list
  # of producer derivations into the right environment for whichever
  # consumption point needs it: a derivation's own build/check environment,
  # an interactive devShell, or a delivered executable's wrapper. Explicit
  # data flow instead of nixpkgs setup-hook chaining, so propagation depth
  # is never a surprise.

  # `<drv>/lib` directories, `:`-joined, for a list of native-library
  # producer derivations.
  nativeLibraryPath = nativeLibraries: lib.concatStringsSep ":" (libDirsOf nativeLibraries);

  # Environment attrset for a derivation's `env` (build/check time), so a
  # test suite that dlopens a transitively-declared native library finds it
  # without a hand-copied preBuild hook. Empty input produces an empty
  # attrset, not an env var set to "".
  nativeLibraryEnv =
    nativeLibraries:
    lib.optionalAttrs (nativeLibraries != [ ]) {
      ${libraryPathVar} = lib.concatStringsSep ":" (libDirsOf nativeLibraries);
    };

  # `makeWrapper` arguments that bake the same search path into a delivered
  # executable, so it keeps resolving its native libraries after leaving
  # the Nix build sandbox (see batteries/app.nix).
  nativeLibraryWrapperArgs =
    nativeLibraries:
    lib.optionals (nativeLibraries != [ ]) [
      "--suffix"
      libraryPathVar
      ":"
      (lib.concatStringsSep ":" (libDirsOf nativeLibraries))
    ];

  # Marks a derivation that itself produces a native library (its `$out/lib`
  # holds a `.so`/`.dylib`) as a `nativeLibraries` entry for consumers. Most
  # producers just need `passthru.nativeLibraries = [ finalDrv ]`, spelled
  # out directly at the call site instead of forcing every producer through
  # one more layer of indirection -- this helper exists for the common case
  # of wrapping a plain `stdenv.mkDerivation` that has no other
  # cl-nix-forge involvement (e.g. a pure-C shared library with no Lisp
  # code of its own).
  markNativeLibrary =
    drv:
    drv
    // {
      # Consumers read this attribute directly; passthru alone is only
      # promoted by mkDerivation, not by attrset extension.
      nativeLibraries = [ drv ];
      passthru = (drv.passthru or { }) // {
        nativeLibraries = [ drv ];
      };
    };
}
