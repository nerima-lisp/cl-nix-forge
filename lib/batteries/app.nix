{
  lib,
  pkgs,
  native,
}:
{
  # Delivers a standalone executable. Drives `asdf:program-op` -- the
  # `.asd` file's own `:build-operation`/`:build-pathname`/`:entry-point`
  # is the single source of truth for how a binary is built, instead of a
  # hand-rolled `save-lisp-and-die --eval` chain repeating that
  # information a second time in Nix.
  #
  # This is one code path for every platform, including aarch64-darwin with
  # SBCL. An earlier revision fell back to a plain, non-executable `.core`
  # plus a `makeWrapper` shim around `sbcl --core` there, on the strength of
  # a single observation: `program-op` had not produced a binary at the
  # system's `:build-pathname` within five minutes on aarch64-darwin with
  # SBCL 2.6.6 (see git history and docs/src/project/platform-coverage.md
  # for that observation as it was recorded). That observation did not
  # reproduce. Rebuilding the exact same `lispDerivation` invocation this
  # function uses -- same `CL_SOURCE_REGISTRY` plumbing, same
  # `ASDF_OUTPUT_TRANSLATIONS`, same `(asdf:operate 'asdf:program-op
  # "<system>")` script, a real ASDF dependency resolved purely by name --
  # against nixpkgs SBCL 2.6.8 on aarch64-darwin produced a working
  # `Mach-O 64-bit executable arm64` in a few seconds, every time. The
  # multi-minute stalls seen while investigating this turned out to be
  # ambient `nix-daemon` contention from unrelated concurrent builds on a
  # shared machine (visible as "SQLite database ... is busy" warnings and
  # several other builds racing for the same 4 job slots), not anything
  # `program-op` or ASDF did on this code path; a build run in isolation
  # completed in seconds. Nothing rules out a genuine regression specific to
  # SBCL 2.6.6, but nothing in this code path is Darwin-specific enough to
  # explain one, and the fallback's own cost (a second delivery mechanism,
  # untested by CI on either platform, duplicating the `:save-runtime-options`
  # and compression behaviour below by hand) was paid on a single five-minute
  # data point. See docs/src/project/platform-coverage.md for what is and
  # is not verified about this on aarch64-darwin now.
  #
  # No extra code-signing step is needed to make the delivered binary
  # runnable on aarch64-darwin. `codesign -dv` on a freshly built binary
  # reports `flags=0x20002(adhoc,linker-signed)`: nixpkgs' SBCL runtime is
  # already ad-hoc/linker-signed the way every locally linked Mach-O binary
  # on modern macOS is, and `save-lisp-and-die :executable t` (what
  # `program-op` calls on SBCL) writes the delivered image by appending the
  # dumped heap to a copy of that already-signed runtime, so the signature
  # travels with it. There is nothing here for `sigtool`/`codesign` to add;
  # if a future SBCL or nixpkgs change ever strips that signature, the
  # symptom will be the kernel refusing to exec the binary at all (not a
  # silent `program-op` failure), which is an easy thing to add an explicit
  # ad-hoc `codesign -s -` fixup step for if it is ever observed.
  #
  # WHAT `$out` CONTAINS, AND WHAT A DELIVERED IMAGE MAY ASSUME
  #
  # This contract is written down because its absence was a bug. cl-weave's
  # image entry point resolves its ASDF source root at run time by looking
  # for `share/common-lisp/source/` under the prefix its own
  # `sb-ext:*runtime-pathname*` sits in -- the layout every nerima-lisp
  # package and nixpkgs' own Lisp modules use -- and this function published
  # `$out/bin` and nothing else. Both sides were individually correct and
  # disagreed silently: the discovery found nothing, the image fell back to
  # the build-time `asdf:system-source-directory`, and the binary died with
  # "Failed to find the TRUENAME of
  # /nix/var/nix/builds/nix-.../src/package.lisp" the first time it re-loaded
  # one of its own systems.
  #
  # `$out` always contains:
  #
  #   $out/bin/<pname>   the entry point, and `meta.mainProgram`. A real
  #                      executable produced by `program-op` when the image
  #                      has no native libraries to resolve at run time; a
  #                      thin `makeWrapper` shim (see `nativeLibraries`
  #                      below) only when one does, since baking a search
  #                      path into `DYLD_LIBRARY_PATH`/`LD_LIBRARY_PATH` has
  #                      no representation inside the binary itself.
  #
  # `$out` contains, when `installSource` is true:
  #
  #   $out/share/common-lisp/source/<pname>/     `args.src`, verbatim
  #   $out/share/common-lisp/source/<dep>/       one directory per entry of
  #                                              the resolved dependency
  #                                              closure, named by its
  #                                              `pname`
  #
  # so that ONE `(:tree "<prefix>/share/common-lisp/source/")` registry entry
  # resolves the delivered system and everything it loads. The closure is
  # installed too, not just the system's own tree: a system whose sources are
  # findable but whose dependencies' are not fails at exactly the same place,
  # one `asdf:load-system` later.
  #
  # A delivered image may therefore assume that `share/common-lisp/source/`
  # exists under the installation prefix of the file it is running out of --
  # the parent of the directory holding `sb-ext:*runtime-pathname*` -- and
  # nothing more.
  #
  # What is NOT promised: `$out` also holds the whole built tree at its root,
  # because that is where ASDF wrote the program and the delivery copies the
  # derivation wholesale. That is an artifact, not an interface --
  # `share/common-lisp/source/` is the only source layout to build on.
  #
  # `installSource` defaults to false: it puts the source tree and its whole
  # dependency closure into the delivered runtime closure, which a binary
  # that never re-loads a system at run time should not pay for.
  #
  # WHAT NIX OWNS AND WHAT THE .asd OWNS
  #
  # The .asd owns everything about *what* is built: `:build-operation`,
  # `:build-pathname`, `:entry-point`, and (via
  # `:depends-on ((:require :sb-cover))`) which implementation contribs the
  # system needs. None of those are Nix options here, and adding them would
  # give a system two places to disagree about its own entry point.
  #
  # Nix owns the *invocation* of the Lisp that performs the dump, which is
  # where `dynamicSpaceSize` and `imageRequires` below act. Two knobs that
  # are not options here:
  #
  #   save-runtime-options -- not an option because it cannot be turned
  #     off. `uiop:dump-image` hardcodes `:save-runtime-options t` whenever
  #     it is dumping an executable (uiop.lisp, in the `#+sbcl` branch), so
  #     `program-op` always saves them. The observable behaviour it buys --
  #     the image starts with the heap it was dumped with, and the runtime
  #     does not eat the user's arguments -- needs nothing further from this
  #     module.
  #
  #   core compression -- not an option because it cannot be turned on for
  #     `program-op`. ASDF's `perform ((o image-op) (c system))` calls
  #     `(dump-image (output-file o c) :executable ...)` and never passes
  #     `:compression`, and SBCL exposes no global to change that, so the
  #     only route would be monkey-patching an ASDF method at build time.
  #
  #   lispDerivation    :: the module's own `lispDerivation` function.
  #   args              :: the exact attrset you'd pass to `lispDerivation`,
  #                        WITHOUT `lispBuildOp` (this function sets it).
  #   buildOperation    :: String ? "asdf:operate 'asdf:program-op" -- an
  #                        ASDF operation CLASS invoked via `asdf:operate`,
  #                        not called directly (unlike `asdf:load-system`).
  #   programPath       :: String ? null -- ASDF writes a program to the
  #                        system's `:build-pathname`, which is not
  #                        necessarily `$out/bin/<system>`. Keep that
  #                        ASDF-specific detail explicit at the boundary,
  #                        then normalize the Nix result.
  #   dynamicSpaceSize  :: Int ? null -- megabytes of SBCL dynamic space.
  #   imageRequires     :: [ String ] ? [ ] -- implementation modules to
  #                        `(require ...)` before the image is dumped.
  #                        Prefer `:depends-on ((:require :sb-cover))` in
  #                        the .asd: that is ASDF-native, works everywhere,
  #                        and keeps the system's own dependencies in the
  #                        system definition. This option is for the
  #                        remaining case where the *dump* needs a module
  #                        the system itself does not depend on.
  #   installSource     :: Bool ? false -- install `args.src` and the
  #                        resolved dependency closure under the delivered
  #                        image's own prefix, as described above, so an
  #                        image that re-loads a system at run time can find
  #                        one. Costs the whole source closure at runtime.
  mkExecutable =
    {
      lispDerivation,
      args,
      buildOperation ? "asdf:operate 'asdf:program-op",
      programPath ? null,
      dynamicSpaceSize ? null,
      imageRequires ? [ ],
      installSource ? false,
    }:
    let
      baseLisp = args.lisp or pkgs.sbcl;
      lispImplementation = args.lispImplementation or (lib.getName baseLisp);
      requestedLispSystem = args.lispSystem or null;
      requestedLispSystems = args.lispSystems or null;
      lispSystem =
        if requestedLispSystem != null && requestedLispSystems != null then
          throw "cl-nix-forge mkExecutable: pass exactly one ASDF system via `lispSystem` or `lispSystems`"
        else if requestedLispSystem != null then
          if builtins.isString requestedLispSystem then
            requestedLispSystem
          else
            throw "cl-nix-forge mkExecutable: `lispSystem` must be a string"
        else if requestedLispSystems == null then
          throw "cl-nix-forge mkExecutable: pass exactly one ASDF system via `lispSystem` or `lispSystems`"
        else if !builtins.isList requestedLispSystems then
          throw "cl-nix-forge mkExecutable: `lispSystems` must be a single-element list containing a string"
        else if requestedLispSystems == [ ] then
          throw "cl-nix-forge mkExecutable: `lispSystems` must contain exactly one ASDF system, not an empty list"
        else if builtins.length requestedLispSystems != 1 then
          throw "cl-nix-forge mkExecutable: `lispSystems` must contain exactly one ASDF system"
        else if !builtins.isString (builtins.head requestedLispSystems) then
          throw "cl-nix-forge mkExecutable: `lispSystems` must contain a string"
        else
          builtins.head requestedLispSystems;
      outputName = args.pname or lispSystem;

      # The delivery is the package a release is actually inspected as, so it
      # carries the version it was built from: `runCommand outputName` alone
      # produced `...-cl-weave` where the hand-written flake it replaced
      # produced `...-cl-weave-1.0.1`, and a store path that cannot be told
      # apart from the previous release's is a worse diagnostic than no store
      # path at all. `pname`/`version` are set alongside `name` as well, so
      # `lib.getName`/`lib.getVersion` -- and therefore `mkOverlay`, which
      # names its attributes with them -- read the identity off the
      # derivation rather than re-parsing a joined string.
      version = args.version or null;
      deliveryName = if version == null then outputName else "${outputName}-${version}";
      identityAttrs = {
        pname = outputName;
      }
      // lib.optionalAttrs (version != null) { inherit version; };

      # `share/common-lisp/source/<name>/`: nixpkgs' own Lisp modules and
      # every nerima-lisp package put sources there, and a delivered image
      # looking for its own siblings looks there. One directory per tree, so
      # a single `(:tree ...)` entry over the parent finds all of them and
      # ASDF's own recursive search does the rest.
      sourceInstallDir = "share/common-lisp/source";

      # Shell that installs the delivered system's sources, plus every
      # already-built dependency in its closure, into `$out`. `dependencies`
      # is the derivation's own resolved `ancestry.deps` -- the same list
      # `lispDerivation` turns into CL_SOURCE_REGISTRY -- so what the image
      # can find at run time is exactly what it compiled against.
      installSourceCommands =
        dependencies:
        let
          trees = [
            {
              name = outputName;
              path = args.src;
            }
          ]
          ++ map (dependency: {
            name = lib.getName dependency;
            path = dependency;
          }) dependencies;
          names = map (tree: tree.name) trees;
          duplicated = lib.unique (lib.filter (name: lib.count (other: other == name) names > 1) names);
        in
        assert lib.assertMsg (duplicated == [ ])
          "cl-nix-forge mkExecutable: `installSource` gives every shipped source tree its own directory under ${sourceInstallDir}/, but ${
            lib.concatMapStringsSep ", " (name: "`${name}`") duplicated
          } names more than one of them. Give the delivered executable or the colliding dependency a distinct `pname`.";
        ''
          mkdir -p "$out/${sourceInstallDir}"
        ''
        + lib.concatMapStrings (tree: ''
          if [ -e "$out/${sourceInstallDir}/${tree.name}" ]; then
            echo "cl-nix-forge mkExecutable: $out/${sourceInstallDir}/${tree.name} already exists; the delivered tree ships that layout itself" >&2
            exit 1
          fi
          cp -R ${tree.path} "$out/${sourceInstallDir}/${tree.name}"
          chmod -R u+w "$out/${sourceInstallDir}/${tree.name}"
        '') trees;

      # Options that act on the Lisp that performs the dump. They are
      # applied by wrapping that Lisp rather than by extending the ASDF
      # script, because the compile and the dump happen inside one
      # `sbcl --script` run that ASDF, not Nix, drives -- the invocation is
      # the only part of it Nix legitimately holds.
      imageFlags =
        lib.optionals (dynamicSpaceSize != null) [
          "--dynamic-space-size"
          (toString dynamicSpaceSize)
        ]
        ++ lib.optionals (imageRequires != [ ]) (
          # `--eval` ahead of `--script` is honoured and still exits
          # non-zero on a script error, but it re-enables the banner that
          # `--script` alone suppresses.
          [ "--noinform" ]
          ++ lib.concatMap (module: [
            "--eval"
            "(require :${module})"
          ]) imageRequires
        );

      # A shell script rather than `makeWrapper --add-flags`: that option
      # splices its argument into the wrapper unquoted, which would tear
      # `(require :sb-cover)` in half at the space. The wrapper keeps the
      # implementation's own name so `lispDerivation`'s
      # `lispImplementation` check still recognises it.
      imageLisp =
        if imageFlags == [ ] then
          baseLisp
        else
          pkgs.writeShellScriptBin (lib.getName baseLisp) ''
            exec ${lib.getExe baseLisp} ${lib.escapeShellArgs imageFlags} "$@"
          '';

      deliveryArgs = (removeAttrs args [ "lispBuildOp" ]) // {
        lisp = imageLisp;
      };

      delivered = lispDerivation (deliveryArgs // { lispBuildOp = [ buildOperation ]; });
      resolvedProgramPath = if programPath == null then lispSystem else programPath;
      wrapperArgs = native.nativeLibraryWrapperArgs (delivered.nativeLibraries or [ ]);
    in
    assert lib.assertMsg (imageFlags == [ ] || lispImplementation == "sbcl")
      "cl-nix-forge mkExecutable: `dynamicSpaceSize` and `imageRequires` are spelled as SBCL command-line options; ${lispImplementation} does not accept them";
    builtins.seq lispSystem (
      pkgs.runCommand deliveryName
        (
          {
            nativeBuildInputs = lib.optionals (wrapperArgs != [ ]) [ pkgs.makeWrapper ];
            passthru = delivered.passthru or { };
            meta = (delivered.meta or { }) // {
              mainProgram = outputName;
            };
          }
          // identityAttrs
        )
        ''
          cp -R ${delivered}/. "$out"
          chmod -R u+w "$out"
          program="$out/${resolvedProgramPath}"
          if [ ! -f "$program" ] || [ ! -x "$program" ]; then
            echo "cl-nix-forge: ASDF program-op did not create executable ${resolvedProgramPath}" >&2
            exit 1
          fi
          mkdir -p "$out/bin"
          ${
            if wrapperArgs == [ ] then
              # No native libraries to resolve at run time, so there is
              # nothing a wrapper could add: move the real executable
              # `program-op` produced straight to its published path rather
              # than hiding it behind a `makeWrapper` shell script that
              # would only ever `exec` it unchanged.
              ''
                mv "$program" "$out/bin/${outputName}"
              ''
            else
              ''
                original="$out/bin/${outputName}.cl-nix-forge-unwrapped"
                mv "$program" "$original"
                makeWrapper "$original" "$out/bin/${outputName}" \
                  ${lib.concatStringsSep " " (map lib.escapeShellArg wrapperArgs)}
              ''
          }
          ${
            # `$out/bin/<pname>` (or, with native libraries,
            # `$out/bin/<pname>.cl-nix-forge-unwrapped`) IS the image
            # `program-op` produced (the wrapper, when there is one, execs
            # it unchanged; SBCL resolves `*runtime-pathname*` from the
            # running executable either way), so `$out` is the prefix the
            # image anchors on and the sources belong here.
            lib.optionalString installSource (installSourceCommands (delivered.ancestry.deps or [ ]))
          }
        ''
    );
}
