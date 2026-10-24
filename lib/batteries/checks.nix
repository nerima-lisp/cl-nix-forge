{ lib, pkgs }:
let
  checkRuntime = import ../core/check-runtime.nix { inherit lib pkgs; };

  # An artifact path is written by hand at the call site and then used in two
  # places (assertion and installation), so a trailing slash -- natural to
  # write for a directory, and how cl-weave spells its coverage report -- must
  # be normalized once, here. `cp -R dir/ dst/` means "copy the directory" to
  # GNU cp and "copy its contents" to BSD cp; normalizing removes the question
  # rather than relying on which cp a given stdenv provides.
  normalizeArtifact =
    name: artifact:
    let
      stripped = lib.removeSuffix "/" artifact;
    in
    if !builtins.isString artifact || artifact == "" then
      throw "cl-nix-forge mkCommandCheck (${name}): artifacts must be non-empty relative path strings"
    else if lib.hasPrefix "/" artifact then
      throw "cl-nix-forge mkCommandCheck (${name}): artifact \"${artifact}\" must be relative to the build tree, not absolute"
    else if lib.hasSuffix "/" stripped || stripped == "" then
      throw "cl-nix-forge mkCommandCheck (${name}): artifact \"${artifact}\" has a malformed trailing slash"
    else
      stripped;
in
{
  # `lispDerivation` already runs `asdf:test-system` inside the very same
  # sandboxed build as the derivation itself (`passthru.enableCheck` toggles
  # `doCheck`) -- there is no separate "copy the read-only store path to a
  # writable tree" step to reinvent here the way older, hand-rolled
  # flake.nix test harnesses needed, because a Nix build's working
  # directory is already a private writable copy. `mkTestCheck` exists so a
  # `checks.<system>.<name>` attribute reads as an intentional, named
  # decision rather than a bare `.enableCheck` property access scattered
  # across a flake.
  #
  # For a suite that cannot be driven by an enclosing `test-op`, or that
  # needs a time limit, use `mkScriptCheck` (lib/core/script-check.nix).
  mkTestCheck = drv: drv.enableCheck;

  # Runs a command against a built system, asserts it produced named
  # artifacts, validates them, and publishes them as the check's `$out`.
  #
  # This is the shape of every artifact check in cl-weave's flake: run the
  # packaged CLI with an argv, assert `cl-weave-junit.xml` exists, run
  # `xmllint --noout` and an xpath equality over it, then copy it into `$out`
  # so CI can retrieve the file rather than only a pass/fail bit.
  #
  #   drv                :: a `lispDerivation` result. Supplies the working
  #                         tree, the resolved CL_SOURCE_REGISTRY (including
  #                         `lispCheckDependencies`) and the native-library
  #                         environment, exactly as `mkScriptCheck` does --
  #                         a packaged CLI still has to FIND the systems it
  #                         is asked to operate on.
  #   name               :: String -- required. A single system routinely has
  #                         ten of these; deriving the name would collide.
  #   command            :: [ String ] -- argv, quoted with
  #                         `lib.escapeShellArgs`. A LIST, never a
  #                         concatenated string: a filter expression like
  #                         `"filtering > runs only tests matching a path
  #                         substring"` contains spaces and a `>` that a
  #                         string-concatenated command would hand to the
  #                         shell as a redirection.
  #   artifacts          :: [ String ] ? [ ] -- paths relative to the build
  #                         tree, files or directories.
  #   validationCommands :: [ String ] ? [ ] -- shell snippets run after the
  #                         artifacts are asserted, in the build tree.
  #   timeoutSeconds     :: Int ? null, killAfterSeconds :: Int ? 30 --
  #                         see core/check-runtime.nix.
  #   nativeBuildInputs  :: [ derivation ] ? [ ] -- the validators
  #                         (`pkgs.jq`, `pkgs.libxml2`, `pkgs.perl`, ...).
  mkCommandCheck =
    {
      drv,
      name,
      command,
      artifacts ? [ ],
      validationCommands ? [ ],
      timeoutSeconds ? null,
      killAfterSeconds ? 30,
      nativeBuildInputs ? [ ],
    }:
    let
      normalized = map (normalizeArtifact name) artifacts;

      # Every artifact is asserted PRESENT AND NON-EMPTY. Presence alone is
      # not the property anyone actually wants: a reporter that opens its
      # output file and then dies leaves a zero-byte JSON document behind,
      # and `test -e` is perfectly happy with it. cl-weave separately
      # hand-wrote `test -s` for the two artifacts it had been burned by;
      # this makes that the rule instead of the exception. A directory is
      # non-empty when it has at least one entry -- `test -s` on a directory
      # reports its inode size and is meaningless.
      assertArtifacts = ''
        clNixForgeAssertArtifact() {
          if [ -d "$1" ]; then
            if [ -z "$(ls -A -- "$1")" ]; then
              echo "cl-nix-forge: ${name}: artifact directory '$1' was produced but is empty" >&2
              exit 1
            fi
          elif [ -f "$1" ]; then
            if [ ! -s "$1" ]; then
              echo "cl-nix-forge: ${name}: artifact file '$1' was produced but is empty" >&2
              exit 1
            fi
          else
            echo "cl-nix-forge: ${name}: command did not produce artifact '$1'" >&2
            exit 1
          fi
        }
        ${lib.concatMapStringsSep "\n" (
          artifact: "clNixForgeAssertArtifact ${lib.escapeShellArg artifact}"
        ) normalized}
      '';

      # Artifacts keep their relative layout under `$out`, so a check that
      # writes `reports/summary.json` does not silently flatten to
      # `$out/summary.json` and collide with another artifact of that name.
      installArtifacts = lib.concatMapStringsSep "\n" (
        artifact:
        let
          # `$out` stays OUTSIDE the escaping. `lib.escapeShellArg
          # "$out/${dir}"` single-quotes the whole string, so the shell never
          # expands the variable and silently creates a directory literally
          # named `$out` in the build tree instead -- leaving the check's real
          # output empty while every assertion above still passes.
          destination = ''"$out"/${lib.escapeShellArg (builtins.dirOf artifact)}'';
        in
        ''
          mkdir -p ${destination}
          cp -R -- ${lib.escapeShellArg artifact} ${destination}/
        ''
      ) normalized;
    in
    if !builtins.isList command || command == [ ] || !lib.all builtins.isString command then
      throw "cl-nix-forge mkCommandCheck (${name}): `command` must be a non-empty list of strings (argv), not a concatenated shell string"
    else
      drv.enableCheck.overrideAttrs (old: {
        pname = name;
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ checkRuntime.packages ++ nativeBuildInputs;

        checkPhase = ''
          runHook preCheck
          ${checkRuntime.isolateHome}
          ${checkRuntime.withTimeLimit {
            label = name;
            command = lib.escapeShellArgs command;
            inherit timeoutSeconds killAfterSeconds;
          }}
          ${assertArtifacts}
          # Validation runs after the artifacts are known to exist, and
          # outside the time limit: the limit exists for the Lisp process's
          # runaway risk, and folding a sub-second `jq` into it would let a
          # slow validator be reported as a suite timeout.
          ${lib.concatStringsSep "\n" validationCommands}
          runHook postCheck
        '';

        # Unlike `mkScriptCheck`, this replaces `lispDerivation`'s install:
        # the entire point of the check is retrieving named artifacts, and
        # burying them inside a full copy of the source tree plus its FASLs
        # defeats that.
        installPhase = ''
          runHook preInstall
          mkdir -p "$out"
          ${installArtifacts}
          runHook postInstall
        '';
      });
}
