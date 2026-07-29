{ lib, pkgs }:
# The two things every check-producing function in this library has to put
# into its `checkPhase`, kept in one place so the three call sites
# (core/script-check.nix, batteries/checks.nix, batteries/coverage.nix)
# cannot drift into three subtly different answers.
{
  # Isolate HOME, and nothing else.
  #
  # The hand-rolled flake.nix harnesses this library replaces all open with
  # `cp -R $src source; chmod -R u+w; cd source; export XDG_CACHE_HOME=...`.
  # None of that is reproduced here: a Nix build directory is ALREADY a
  # private writable copy of the source tree (that is what `unpackPhase`
  # produces), and `lispDerivation` already sets the identity
  # ASDF_OUTPUT_TRANSLATIONS, so ASDF never reaches for a user-level FASL
  # cache that would need scoping.
  #
  # HOME is the one line that survives, for a different reason than the
  # original: stdenv points HOME at /homeless-shelter, a path that does not
  # exist. A suite that writes a scratch file under $HOME -- or a Lisp that
  # tries to create its default per-user directory -- then fails on that
  # rather than on its own assertions, which is a maximally confusing build
  # log for a problem the test author did not cause.
  isolateHome = ''
    export HOME="$NIX_BUILD_TOP/cl-nix-forge-check-home"
    mkdir -p "$HOME"
  '';

  # `timeout` ships in coreutils. stdenv already puts coreutils on PATH, but
  # every function that emits a time-limited command names this dependency
  # explicitly rather than relying on that: the limit is the whole point of
  # the feature, and a caller who trims `nativeBuildInputs` should get a
  # build error, not a silently unbounded run.
  packages = [ pkgs.coreutils ];

  # Wraps ONE already-quoted shell command in the two-stage SIGTERM -> SIGKILL
  # escalation that every nerima-lisp repository hand-rolls as `timeout -k 30`:
  #
  #   -k sends SIGKILL `killAfterSeconds` after the SIGTERM deadline. SBCL
  #   defers signals to safepoints, so a tight compiled loop (a runaway Prolog
  #   backtracking bug is exactly this) can outlive a bare SIGTERM and fall
  #   through to the enclosing CI job timeout instead of failing here with an
  #   attributable error.
  #
  # `timeoutSeconds = null` -- the default at every call site -- emits the
  # command completely unchanged. A time budget is a policy only the caller
  # can set; a guessed default would turn a slow-but-correct suite red on a
  # loaded runner, which is exactly the failure mode this feature exists to
  # make *legible*, not to create.
  #
  #   label   :: String -- what is being run, quoted into the diagnostic so
  #              a build log that scrolls past the command still attributes
  #              the failure.
  #   command :: String -- shell text, already quoted by the caller
  #              (`lib.escapeShellArgs` for argv lists). Deliberately not a
  #              list here: callers differ in how they build the command, and
  #              re-escaping an already-escaped string would corrupt it.
  withTimeLimit =
    {
      label,
      command,
      timeoutSeconds ? null,
      killAfterSeconds ? 30,
    }:
    if timeoutSeconds == null then
      command
    else if !builtins.isInt timeoutSeconds || timeoutSeconds <= 0 then
      throw "cl-nix-forge withTimeLimit: `timeoutSeconds` must be a positive integer or null, got ${builtins.toJSON timeoutSeconds}"
    else if !builtins.isInt killAfterSeconds || killAfterSeconds <= 0 then
      throw "cl-nix-forge withTimeLimit: `killAfterSeconds` must be a positive integer, got ${builtins.toJSON killAfterSeconds}"
    else
      let
        limit = toString timeoutSeconds;
        grace = toString killAfterSeconds;
        quotedLabel = lib.escapeShellArg label;
      in
      ''
        clNixForgeStatus=0
        timeout --kill-after=${grace}s ${limit}s ${command} || clNixForgeStatus=$?
        # 124 is coreutils' "the SIGTERM deadline expired"; 137 is 128+SIGKILL,
        # i.e. the process ignored SIGTERM long enough for --kill-after to fire.
        # 137 is also what an out-of-band SIGKILL (the OOM killer) produces, so
        # the message states the deadline it is reporting against instead of
        # asserting a cause the exit status cannot actually distinguish.
        if [ "$clNixForgeStatus" -eq 124 ] || [ "$clNixForgeStatus" -eq 137 ]; then
          echo "cl-nix-forge: TIMEOUT -- ${quotedLabel} exceeded its ${limit}s time limit" >&2
          echo "cl-nix-forge: SIGTERM was sent at ${limit}s, SIGKILL ${grace}s later; exit status $clNixForgeStatus" >&2
          echo "cl-nix-forge: this is a time limit, not a crash -- raise timeoutSeconds or fix the runaway" >&2
          exit "$clNixForgeStatus"
        fi
        if [ "$clNixForgeStatus" -ne 0 ]; then
          exit "$clNixForgeStatus"
        fi
      '';
}
