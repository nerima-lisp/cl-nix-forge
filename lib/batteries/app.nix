{
  lib,
  pkgs,
  native,
  # The Darwin fallback below has to run a Lisp on a generated script file.
  # It takes `invoke` from asdf-derivation.nix's implementation table rather
  # than spelling `--script` a second time: that this branch happens to be
  # SBCL-only does not make a hardcoded SBCL flag any less of a duplicate of
  # the row that already records it.
  invoke,
}:
{
  # Delivers a standalone executable. Drives `asdf:program-op` -- the
  # `.asd` file's own `:build-operation`/`:build-pathname`/`:entry-point`
  # is the single source of truth for how a binary is built, instead of a
  # hand-rolled `save-lisp-and-die --eval` chain repeating that
  # information a second time in Nix.
  #
  # SBCL's `program-op` embeds the Lisp image directly into the executable
  # (`:executable t`), which is known to fail on Darwin (the same issue
  # documented in nerima-lisp's own cl-tmux flake.nix). What was actually
  # observed, once, on aarch64-darwin with SBCL 2.6.6: a bare
  # `(asdf:operate 'asdf:program-op "greeter-app")` run under
  # `sbcl --script` had not completed after five minutes and had written no
  # file at the system's `:build-pathname`; it was killed at that point, so
  # "does not finish in a workable time", not "provably never finishes". A
  # hand-written `sb-ext:save-lisp-and-die :executable t` on the same host
  # completes in seconds and produces a working binary, which is what puts
  # the fault in `program-op`'s delivery rather than in SBCL's dumper. No
  # upstream bug ID is cited because none could be identified with
  # confidence; that single reproduction is the whole of the evidence.
  #
  # On Darwin with SBCL this function therefore falls back to the
  # field-proven workaround: build a plain, non-executable `.core` via
  # `save-lisp-and-die` and wrap `sbcl --core` with `makeWrapper`. The
  # `.asd`'s own `:entry-point` is still the source of truth for the
  # fallback path too, read back via ASDF's own `component-entry-point` at
  # build time rather than duplicated in Nix.
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
  # look like they belong in this list deliberately are not:
  #
  #   save-runtime-options -- not an option because it cannot be turned
  #     off. `uiop:dump-image` hardcodes `:save-runtime-options t` whenever
  #     it is dumping an executable (uiop.lisp, in the `#+sbcl` branch), so
  #     the `program-op` path always saves them. On the Darwin path SBCL
  #     documents the flag as "meaningless if :executable is NIL", so it is
  #     unavailable there by construction. The observable behaviour it
  #     buys -- the image starts with the heap it was dumped with, and the
  #     runtime does not eat the user's arguments -- is instead made
  #     unconditional on both paths; see `deliveredFlags`.
  #
  #   core compression -- not an option because it cannot be turned on for
  #     `program-op`. ASDF's `perform ((o image-op) (c system))` calls
  #     `(dump-image (output-file o c) :executable ...)` and never passes
  #     `:compression`, and SBCL exposes no global to change that, so the
  #     only route would be monkey-patching an ASDF method at build time.
  #     The Darwin fallback used to hardcode `:compression t`, which meant
  #     one `mkExecutable` call produced a compressed, slower-starting core
  #     on Darwin and an uncompressed one everywhere else. It now matches
  #     `program-op` and compresses nothing.
  #
  #   lispDerivation    :: the module's own `lispDerivation` function.
  #   args              :: the exact attrset you'd pass to `lispDerivation`,
  #                        WITHOUT `lispBuildOp` (this function sets it).
  #   buildOperation    :: String ? "asdf:operate 'asdf:program-op" -- only
  #                        used on the non-Darwin-SBCL path; an ASDF
  #                        operation CLASS is invoked via `asdf:operate`,
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
  #                        the .asd: that is ASDF-native, works on both
  #                        paths, and keeps the system's own dependencies
  #                        in the system definition. This option is for the
  #                        remaining case where the *dump* needs a module
  #                        the system itself does not depend on.
  mkExecutable =
    {
      lispDerivation,
      args,
      buildOperation ? "asdf:operate 'asdf:program-op",
      programPath ? null,
      dynamicSpaceSize ? null,
      imageRequires ? [ ],
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
      needsDarwinWorkaround = pkgs.stdenv.hostPlatform.isDarwin && lispImplementation == "sbcl";

      # Options that act on the Lisp that performs the dump. They are
      # applied by wrapping that Lisp rather than by extending the ASDF
      # script, because on the `program-op` path the compile and the dump
      # happen inside one `sbcl --script` run that ASDF, not Nix, drives --
      # the invocation is the only part of it Nix legitimately holds.
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
    in
    assert lib.assertMsg (imageFlags == [ ] || lispImplementation == "sbcl")
      "cl-nix-forge mkExecutable: `dynamicSpaceSize` and `imageRequires` are spelled as SBCL command-line options; ${lispImplementation} does not accept them";
    builtins.seq lispSystem (
      if !needsDarwinWorkaround then
        let
          delivered = lispDerivation (deliveryArgs // { lispBuildOp = [ buildOperation ]; });
          resolvedProgramPath = if programPath == null then lispSystem else programPath;
          wrapperArgs = native.nativeLibraryWrapperArgs (delivered.nativeLibraries or [ ]);
        in
        pkgs.runCommand outputName
          {
            nativeBuildInputs = [ pkgs.makeWrapper ];
            passthru = delivered.passthru or { };
            meta = (delivered.meta or { }) // {
              mainProgram = outputName;
            };
          }
          ''
            cp -R ${delivered}/. "$out"
            chmod -R u+w "$out"
            program="$out/${resolvedProgramPath}"
            if [ ! -f "$program" ] || [ ! -x "$program" ]; then
              echo "cl-nix-forge: ASDF program-op did not create executable ${resolvedProgramPath}" >&2
              exit 1
            fi
            mkdir -p "$out/bin"
            original="$out/bin/${outputName}.cl-nix-forge-unwrapped"
            mv "$program" "$original"
            makeWrapper "$original" "$out/bin/${outputName}" \
              ${lib.concatStringsSep " " (map lib.escapeShellArg wrapperArgs)}
          ''
      else
        let
          loaded = lispDerivation (deliveryArgs // { lispBuildOp = [ "asdf:load-system" ]; });

          deliverScript = builtins.toFile "cl-nix-forge-deliver-${lib.strings.sanitizeDerivationName outputName}.lisp" ''
            (require "asdf")
            (asdf:load-system ${builtins.toJSON lispSystem})
            (let* ((system (asdf:find-system ${builtins.toJSON lispSystem}))
                   (entry (asdf/system:component-entry-point system)))
              (sb-ext:save-lisp-and-die "cl-nix-forge-delivered.core"
                :toplevel (uiop:ensure-function entry)
                :executable nil))
          '';

          core = pkgs.stdenv.mkDerivation {
            pname = "${outputName}-core";
            version = args.version or "unstable";
            src = loaded;
            nativeBuildInputs = [ imageLisp ];
            env = native.nativeLibraryEnv (loaded.nativeLibraries or [ ]);
            ASDF_OUTPUT_TRANSLATIONS = "/:/";
            buildPhase = ''
              runHook preBuild
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              export CL_SOURCE_REGISTRY="$PWD:${loaded.registryPath}"
              ${invoke "mkExecutable" lispImplementation imageLisp deliverScript}
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p "$out/lib"
              cp cl-nix-forge-delivered.core "$out/lib/${outputName}.core"
              runHook postInstall
            '';
          };

          # The delivered binary starts the *unwrapped* Lisp: `imageLisp`'s
          # flags are image-build-time only, and an `--eval (require ...)`
          # left on the delivered command line would just land in the
          # application's own argv.
          #
          # `--noinform` is a C-runtime option and must precede `--core`.
          # `--end-runtime-options` is what makes this path behave like the
          # `:save-runtime-options t` executable `program-op` produces:
          # without it the runtime keeps scanning for its own options and
          # eats a leading `--dynamic-space-size` meant for the
          # application. There is deliberately no `--no-sysinit
          # --no-userinit` here -- a core saved with a custom `:toplevel`
          # never runs SBCL's init-file processing at all (verified), so
          # those flags did nothing except appear in the application's
          # `sb-ext:*posix-argv*` as if the user had typed them.
          deliveredFlags =
            lib.optionals (dynamicSpaceSize != null) [
              "--dynamic-space-size"
              (toString dynamicSpaceSize)
            ]
            ++ [
              "--noinform"
              "--core"
              "${core}/lib/${outputName}.core"
              "--end-runtime-options"
            ];

          wrapperArgs = native.nativeLibraryWrapperArgs (loaded.nativeLibraries or [ ]);
        in
        pkgs.runCommand outputName
          {
            nativeBuildInputs = [ pkgs.makeWrapper ];
            passthru = {
              inherit (loaded) nativeLibraries;
            };
            meta = (loaded.meta or { }) // {
              mainProgram = outputName;
            };
          }
          ''
            mkdir -p "$out/bin"
            makeWrapper ${lib.getExe baseLisp} "$out/bin/${outputName}" \
              --inherit-argv0 \
              --add-flags ${lib.escapeShellArg (lib.concatStringsSep " " deliveredFlags)} \
              ${lib.concatStringsSep " " (map lib.escapeShellArg wrapperArgs)}
          ''
    );
}
