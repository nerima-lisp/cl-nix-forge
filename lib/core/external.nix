{ lib }:
rec {
  # Wrap an arbitrary Nix derivation -- a Quicklisp-packaged library from
  # nixpkgs (`pkgs.sbcl.pkgs.alexandria`), the output of a completely
  # unrelated project's own hand-written flake.nix, or anything else this
  # library didn't build -- as a `lispDependencies`-compatible leaf.
  #
  # A generic foreign derivation is an opaque leaf. Its output directory is
  # added to CL_SOURCE_REGISTRY, but it contributes no inferred Lisp
  # dependencies: it might not be ASDF-based by the time it reaches $out.
  #
  #   drv             :: derivation      the foreign package
  #   recursive       :: bool  ? false   append `//` so ASDF searches $out's
  #                                      whole subtree for .asd files,
  #                                      instead of just $out itself. Needed
  #                                      for foreign packages whose .asd
  #                                      doesn't sit at the output root.
  #   nativeLibraries :: [derivation] ? [ ]
  #                                      declare that this foreign package
  #                                      itself provides native libraries
  #                                      (see native.nix). cl-nix-forge has
  #                                      no way to detect this for a
  #                                      package it didn't build -- if the
  #                                      foreign package's own $out/lib
  #                                      holds a `.so`/`.dylib` a Lisp
  #                                      consumer will dlopen, declare
  #                                      `nativeLibraries = [ drv ]`
  #                                      explicitly here.
  #   lispImplementation :: string ? null
  #                                      implementation that built any FASLs
  #                                      in this foreign package. When set,
  #                                      lispDerivation rejects consumers
  #                                      using a different implementation,
  #                                      rather than letting ASDF attempt to
  #                                      rewrite immutable store paths.
  #
  # Why this argument is OPTIONAL here while `fromNixpkgsLisp` below makes
  # it mandatory: `fromDerivation` deliberately wraps outputs that contain
  # no Lisp at all -- a C shared library, a data directory, some foreign
  # flake's binary. Those have no implementation to name, and demanding one
  # would only teach callers to invent an answer, which is worse than an
  # honest `null`. Two properties keep the omission from being a hole:
  #   * the `drv //` below preserves an existing
  #     `clNixForgeLispImplementation`, so re-wrapping something
  #     cl-nix-forge built keeps its boundary without the caller restating
  #     it; and
  #   * contradicting that inherited value is an error (assertion below),
  #     not a silent relabel of somebody else's fasls.
  # `fromNixpkgsLisp` has neither excuse: every package it wraps is a
  # precompiled Lisp library, so there the answer always exists.
  #
  # A foreign leaf never merges with another derivation (dedup.nix's
  # collision case only matters between derivations cl-nix-forge itself
  # produced from the same source tree), so `ancestry.merge` is a no-op
  # that just keeps whichever side asked.
  fromDerivation =
    {
      drv,
      recursive ? false,
      nativeLibraries ? [ ],
      lispDependencies ? [ ],
      lispImplementation ? null,
    }:
    assert lib.assertMsg
      (
        lispImplementation == null
        || !(drv ? clNixForgeLispImplementation)
        || drv.clNixForgeLispImplementation == lispImplementation
      )
      "cl-nix-forge fromDerivation: `lispImplementation` \"${lispImplementation}\" contradicts the wrapped derivation's own \"${drv.clNixForgeLispImplementation}\"; a wrapper may name an implementation an opaque output does not declare, but it may not overrule one that does";
    drv
    // lib.optionalAttrs (lispImplementation != null) {
      clNixForgeLispImplementation = lispImplementation;
    }
    // {
      _lispOrigSrc = drv;
      ancestry = rec {
        merge = other: other;
        me = drv;
        deps = lispDependencies;
        _depsMap = builtins.foldl' (
          dependencies: dependency:
          dependencies
          // dependency.ancestry._depsMap
          // {
            ${builtins.unsafeDiscardStringContext (toString (dependency._lispOrigSrc or dependency))} =
              dependency;
          }
        ) { } lispDependencies;
      };
      inherit nativeLibraries;
      registrySuffix = lib.optionalString recursive "//";
    };

  # Shorthand for the common case of pulling in a Quicklisp-packaged
  # nixpkgs library, e.g.:
  #
  #   lispDependencies = [
  #     (fromNixpkgsLisp {
  #       drv = pkgs.sbcl.pkgs.alexandria;
  #       lispImplementation = "sbcl";
  #     })
  #   ];
  #
  # Both arguments are required, and there is deliberately no
  # bare-derivation shorthand. Everything this function wraps is a
  # precompiled Lisp package, whose fasls belong to exactly one
  # implementation; a shorthand that let the caller leave that unsaid would
  # be a one-character way to opt out of the boundary lispDerivation
  # enforces -- and that check is the whole reason a consumer built with a
  # different implementation fails during evaluation instead of asking ASDF
  # to rewrite fasls inside the immutable store.
  #
  # Defaults to `recursive = true`: nixpkgs' own ASDF builder copies a
  # package's whole build tree into $out, and unlike cl-nix-forge's own
  # convention of keeping every system's .asd at the source root, several
  # real Quicklisp systems (e.g. cffi's grovel/toolchain subsystems) keep
  # secondary .asd files in subdirectories.
  fromNixpkgsLisp =
    options:
    # Checked before destructuring: a bare derivation IS an attrset, so the
    # pattern below would reject it with an opaque "called without required
    # argument" instead of saying what to write.
    assert lib.assertMsg (builtins.isAttrs options && options ? drv && options ? lispImplementation)
      "cl-nix-forge fromNixpkgsLisp: both `drv` and `lispImplementation` are required, e.g. `fromNixpkgsLisp { drv = pkgs.sbcl.pkgs.alexandria; lispImplementation = \"sbcl\"; }`; a bare derivation is not accepted, because an unnamed implementation cannot be checked against a consumer's";
    (
      # Destructured without `...` so a misspelled or unsupported attribute
      # is an error rather than a silently ignored request. `recursive` is
      # not offered: see above for why it is always right here.
      {
        drv,
        lispImplementation,
      }:
      let
        wrap =
          package:
          fromDerivation {
            drv = package;
            recursive = true;
            inherit lispImplementation;
            # nixpkgs Lisp modules expose their ASDF dependencies through
            # propagatedBuildInputs. Keep them out of buildInputs while making
            # every required .asd discoverable to ASDF.
            lispDependencies = map wrap (package.propagatedBuildInputs or [ ]);
          };
      in
      wrap drv
    )
      options;
}
