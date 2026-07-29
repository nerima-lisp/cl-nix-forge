{
  lib,
  pkgs,
  dedup,
  native,
}:
let
  inherit (dedup) ancestryWalker;
  inherit (native) nativeLibraryEnv;

  # Everything cl-nix-forge knows about a Lisp implementation lives in this
  # ONE table. Adding an implementation is a one-row change: nothing else in
  # this file (or in matrix.nix, or in script-check.nix, or in
  # batteries/app.nix) branches on implementation name, and there is no
  # second table that could drift out of agreement with this one.
  #
  # That claim survived first contact. Adding CCL, CLISP, ABCL and Clasp
  # needed no new conditional anywhere -- but it did need `scriptFlagsOf` to
  # shell-quote each word instead of joining them raw, because ABCL's row is
  # the first whose flags contain a space. That was the row VOCABULARY being
  # too weak, not the abstraction leaking: every consumer still just asks
  # for "the flags" and appends a file.
  #
  #   scriptFlags :: [ String ] -- the argv words that make the
  #     implementation run, non-interactively, the script file named by the
  #     immediately following argument. A list of words rather than one
  #     command string because the two consumers need it at different
  #     levels: `lispDerivation` splices a whole shell command into a build
  #     phase, while `lispScript` bakes argv words into a makeWrapper
  #     `--add-flags`. Expressing the flags once and deriving both (see
  #     `scriptFlagsOf` and `invoke`) is what keeps the row authoritative.
  #     A list, not a single string, because implementations disagree on
  #     arity here -- SBCL's `--script` is one word, CCL's row needs four,
  #     and ABCL's needs an entire Lisp form as a single word.
  #
  # THE property every row must have, and the one that is worth measuring
  # rather than assuming: a script that signals must make the process exit
  # NON-ZERO. A row that runs the script but always exits 0 is worse than no
  # row at all, because `asdf:test-system` failures then look like passes.
  # ABCL's obvious invocation (`--batch --load FILE`) has exactly that bug --
  # it enters the debugger, hits EOF and exits 0 -- which is why its row
  # looks nothing like the others.
  #
  # Two shapes appear below, because implementations disagree on whether a
  # script file is an operand of a flag or a bare argument:
  #   * ends in a flag taking the file (`--script`, `--load`), or ends in
  #     nothing at all (CLISP takes a bare lispfile operand);
  #   * ends in `--`, for implementations whose only failure-propagating
  #     entry point is a `--eval` form; the form reads the file back out of
  #     the post-`--` argument list. ABCL is the only such row.
  # Both shapes satisfy the contract above -- "the script file named by the
  # immediately following argument" -- so no consumer has to know which
  # shape a row uses.
  lispImplementations = {
    # `--script` implies --no-sysinit/--no-userinit/--disable-debugger, and
    # --disable-debugger is what turns an unhandled condition into exit 1.
    sbcl.scriptFlags = [ "--script" ];

    # ECL's `--shell` is its batch script mode; an error during the script
    # aborts initialization and exits non-zero.
    ecl.scriptFlags = [ "--shell" ];

    # CCL has no `--script`, and rejects a bare filename outright
    # ("Unrecognized non-option arguments"), so the file is `--load`'s
    # operand. `--batch` is read by the C kernel (and elided before the Lisp
    # argument parser sees it); it is what routes an unhandled condition to
    # `abnormal-application-exit`, i.e. `(quit -1)` -> exit status 255.
    #
    # Caveat, deliberately accepted: once the loaded file returns, `--batch`
    # still reads a listener from stdin and only exits at EOF. Every build
    # phase gets stdin from /dev/null, so `lispDerivation` and `mkScriptCheck`
    # exit immediately -- but a `lispScript` wrapper run on a terminal will
    # sit at a prompt after the script finishes. CCL offers no way to say
    # "and then quit" without putting a flag AFTER the file, which is not a
    # shape this table can express.
    ccl.scriptFlags = [
      "--batch"
      "--quiet"
      "--no-init"
      "--load"
    ];

    # CLISP takes the script as a bare operand, which by itself selects
    # batch mode: an unhandled condition prints and exits 1, no flag needed.
    # `-q` silences the banner (parity with `--script`) and `-norc` skips
    # ~/.clisprc so a delivered `lispScript` cannot pick up user state.
    clisp.scriptFlags = [
      "-q"
      "-norc"
    ];

    # ABCL is the awkward one. `--batch --load FILE` runs the file and exits
    # 0 even when it signals, and `*debugger-hook*` cannot be pre-set from
    # `--eval` because ABCL rebinds it around every top-level form. What
    # does work is catching the condition below the debugger entirely:
    # `handler-case` around the `load`, with the file taken from the
    # post-`--` argument list, so the row still ends where a file argument
    # belongs.
    abcl.scriptFlags = [
      "--noinform"
      "--noinit"
      "--nosystem"
      "--batch"
      "--eval"
      ''(handler-case (load (first ext:*command-line-argument-list*)) (error (c) (format *error-output* "cl-nix-forge: unhandled ~A: ~A~%" (type-of c) c) (finish-output *error-output*) (ext:quit :status 1)))''
      "--"
    ];

    # Clasp's `--script` implies --norc/--noinform/--non-interactive and
    # disables the debugger; with the debugger disabled an unhandled
    # condition reaches `non-debugger`, which prints a backtrace and calls
    # `(core:quit 1)`.
    clasp.scriptFlags = [ "--script" ];
  };

  # Single lookup point, so every entry point reports an unsupported
  # implementation with the same actionable message. `context` names the
  # public function the caller actually reached this through.
  implementationOf =
    context: implementation:
    lispImplementations.${implementation}
      or (throw "cl-nix-forge ${context}: unsupported lispImplementation \"${implementation}\"; add a row for it to lib/core/asdf-derivation.nix's `lispImplementations` table");

  # The argv words preceding the script path, each shell-quoted and then
  # whitespace-joined: exactly what belongs on a shell command line before
  # the file argument, and also exactly what makeWrapper's `--add-flags`
  # takes -- `--add-flags` is copied verbatim into a Bash wrapper and
  # re-parsed by Bash at run time, so the two consumers agree on quoting.
  #
  # Quoting each word rather than joining them raw is what lets a row hold a
  # word containing spaces (ABCL's `--eval` form) without it splitting into
  # several arguments. Before any row needed that, raw joining happened to
  # produce the same string, so this is the `[ String ]` contract finally
  # being honoured rather than a new one.
  scriptFlagsOf =
    context: implementation: lib.escapeShellArgs (implementationOf context implementation).scriptFlags;

  # Non-interactive invocation of a Lisp implementation on a script file,
  # as a shell command for a build phase.
  #
  # `file` is escaped, not merely double-quoted: this file's own callers
  # always pass a `builtins.toFile` store path, but `invoke` is public and
  # script-check.nix hands it a caller-written repository-relative path,
  # where a `$` would silently expand to nothing and a `"` would end the
  # quoting outright. `lib.escapeShellArg` preserves string context, which
  # is load-bearing -- a generated script's context is the only reason Nix
  # makes it an input of the derivation whose buildPhase names it.
  invoke =
    context: implementation: lisp: file:
    "${lib.getExe lisp} ${scriptFlagsOf context implementation} ${lib.escapeShellArg file}";

  # Arguments `lispDerivation` interprets itself rather than forwarding to
  # mkDerivation -- and, for exactly the same reason, the arguments a merge
  # is allowed to disagree about: each one is either unioned by `doMerge`
  # or part of `dedupKey`, so two derivations that merge at all provably
  # agree on it. Everything outside this list reaches mkDerivation
  # untouched and has only one survivor per merge; see `doMerge`.
  interpretedArgs = [
    "lispSystem"
    "lispSystems"
    "lispDependencies"
    "lispCheckDependencies"
    "nativeLibraries"
    "lisp"
    "lispImplementation"
    "lispBuildOp"
    "lispAsdPath"
    "CL_SOURCE_REGISTRY"
    "src"
    "doCheck"
    "_lispOrigSrc"
    "_lispOrigSystems"
    "_lispDontDeduplicate"
  ];

  # Context-DISCARDED string identity of a source tree, for use ONLY as a
  # dedup.nix attrset key (dictionary-key equality, never embedded in a
  # build script or env var -- that must keep string context so Nix still
  # knows to build the referenced derivation; see `registryPathOf` below).
  identityOf =
    src:
    builtins.unsafeDiscardStringContext (
      toString (if builtins.isPath src then builtins.path { path = src; } else src)
    );

  # Context-PRESERVING path of an already-built dependency derivation, for
  # embedding directly in CL_SOURCE_REGISTRY. `registrySuffix` lets a
  # foreign (non-cl-nix-forge) dependency opt into ASDF's recursive `//`
  # search, since we can't control a foreign package's output layout the
  # way we control our own (see external.nix).
  registryPathOf = drv: "${drv}${drv.registrySuffix or ""}";

  # A consumer needs both the system it explicitly requested and every
  # system in that derivation's already-computed dependency closure. The
  # built output intentionally contains only its own source tree, so
  # registering the root alone would make lispWithSystems work for leaves
  # but fail as soon as an ASDF dependency is loaded at runtime.
  registryPathsFor = drv: [ (registryPathOf drv) ] ++ (map registryPathOf (drv.ancestry.deps or [ ]));

  # Deduplication is safe only when every ASDF registry entry that can affect
  # compilation is identical. Keep list order: ASDF resolves duplicate system
  # names according to registry order.
  dependencyClosureKey =
    dependencies:
    map (dependency: {
      identity = dependency.dedupKey or (identityOf (dependency._lispOrigSrc or dependency));
      registryPaths = registryPathsFor dependency;
    }) dependencies;

  mkAsdfScript =
    name: operations: systems:
    builtins.toFile "cl-nix-forge-${lib.strings.sanitizeDerivationName name}.lisp" ''
      (require "asdf")
      ${lib.concatMapStringsSep "\n" (
        operation: lib.concatMapStringsSep "\n" (system: "(${operation} ${builtins.toJSON system})") systems
      ) operations}
    '';
in
rec {
  # The implementation table and its two derived accessors are public, so a
  # module outside this file (lib/core/script-check.nix runs an arbitrary
  # entry point as a build phase) can reuse the single table instead of
  # rebuilding a command from `scriptFlags` -- which would be exactly the
  # second construction site this file exists to not have. `implementationOf`
  # stays internal on purpose: it hands back a raw row, and a caller holding
  # a row would once again be branching on the table's shape. Anything a
  # consumer legitimately needs from a row gets an accessor here instead.
  inherit
    lispImplementations
    invoke
    scriptFlagsOf
    identityOf
    registryPathOf
    ;

  # Build one or more ASDF systems from a single source tree as a single
  # Nix derivation, whose result ("$out") is source plus compiled fasls
  # side by side -- directly reusable as a `lispDependencies` entry, or as
  # an interactive `nix develop` shell.
  #
  # Dependency arguments (why there are four, not one):
  #   lispDependencies      -- other lispDerivation results (or
  #                            external.nix-wrapped foreign derivations)
  #                            this needs at compile/load time. Resolved
  #                            purely into CL_SOURCE_REGISTRY; NEVER
  #                            injected into Nix's own buildInputs. A
  #                            Lisp-level dependency and a Nix-level build
  #                            input are different things, and conflating
  #                            them (as prior art does) means every
  #                            transitive Lisp dependency silently becomes
  #                            part of your derivation's rebuild-trigger
  #                            set even when nothing native changed.
  #   lispCheckDependencies -- like lispDependencies, but only pulled in
  #                            when doCheck is true.
  #   nativeLibraries       -- see native.nix. Propagates transitively
  #                            through the same dependency walk as
  #                            lispDependencies, so a consumer three hops
  #                            away from the actual producer still finds
  #                            it on LD_LIBRARY_PATH/DYLD_LIBRARY_PATH.
  #   buildInputs/nativeBuildInputs -- ordinary Nix meaning, untouched.
  lispDerivation =
    {
      lispSystem ? null,
      lispSystems ? null,
      lispDependencies ? [ ],
      lispCheckDependencies ? [ ],
      nativeLibraries ? [ ],
      lisp ? pkgs.sbcl,
      lispImplementation ? lib.getName lisp,
      lispBuildOp ? [ "asdf:load-system" ],
      lispAsdPath ? [ ],
      CL_SOURCE_REGISTRY ? "",
      src,
      doCheck ? false,
      _lispOrigSrc ? src,
      _lispOrigSystems ? null,
      _lispDontDeduplicate ? false,
      ...
    }@args:
    let
      lispSystems' =
        if lispSystem != null && lispSystems != null then
          throw "cl-nix-forge lispDerivation: pass exactly one of `lispSystem` or `lispSystems`"
        else if lispSystem != null then
          if builtins.isString lispSystem then
            [ lispSystem ]
          else
            throw "cl-nix-forge lispDerivation: `lispSystem` must be a string"
        else if lispSystems == null then
          throw "cl-nix-forge lispDerivation: pass exactly one of `lispSystem` or `lispSystems`"
        else if
          !builtins.isList lispSystems || lispSystems == [ ] || !lib.all builtins.isString lispSystems
        then
          throw "cl-nix-forge lispDerivation: `lispSystems` must be a non-empty list of strings"
        else
          lispSystems;

      actualLispImplementation = lib.getName lisp;

      origSystems = if _lispOrigSystems != null then _lispOrigSystems else lispSystems';

      invokeLisp = invoke "lispDerivation" lispImplementation lisp;

      # The same table row `invokeLisp` uses, pulled out on its own so the
      # `builtins.seq` at the end of this function can force it. Without
      # that, an implementation with no row would only be noticed when the
      # lazily-built `buildPhase` string is forced -- long after the two
      # assertions below, and after `tryEval` on the derivation itself has
      # already reported success.
      scriptFlags = scriptFlagsOf "lispDerivation" lispImplementation;

      # A source tree can safely share compiled output only when the
      # compiler/runtime and the requested ASDF operations also match.
      # Source identity alone would incorrectly merge SBCL and ECL FASLs.
      dedupKey = builtins.unsafeDiscardStringContext (
        lib.concatStringsSep "|" [
          (identityOf _lispOrigSrc)
          lispImplementation
          (identityOf lisp)
          pkgs.stdenv.hostPlatform.system
          (builtins.toJSON lispAsdPath)
          (builtins.toJSON lispBuildOp)
          (builtins.toJSON CL_SOURCE_REGISTRY)
          (builtins.toJSON doCheck)
          (builtins.toJSON (dependencyClosureKey lispDependencies))
          (builtins.toJSON (dependencyClosureKey checkDeps))
        ]
      );

      passthroughArgs = removeAttrs args interpretedArgs;

      checkDeps = lib.optionals doCheck lispCheckDependencies;

      incompatibleLispDependencies = lib.filter (
        dependency:
        dependency ? clNixForgeLispImplementation
        && dependency.clNixForgeLispImplementation != lispImplementation
      ) (lispDependencies ++ checkDeps);

      ancestry = ancestryWalker {
        keyOf = drv: drv.dedupKey or (identityOf drv._lispOrigSrc);
        myKey = dedupKey;
        me = me;
        merge = doMerge;
        dependencies = lispDependencies ++ checkDeps;
      };

      transitiveNativeLibraries = lib.unique (
        nativeLibraries ++ (lib.concatMap (d: d.nativeLibraries or [ ]) ancestry.deps)
      );

      searchPath = [ "$PWD" ] ++ (map (p: "$PWD/${p}") lispAsdPath) ++ (map registryPathOf ancestry.deps);

      configuredSearchPath = lib.optionals (CL_SOURCE_REGISTRY != "") [ CL_SOURCE_REGISTRY ];

      resolvedSearchPath = configuredSearchPath ++ searchPath;

      setAsdfPathPhase = ''
        export CL_SOURCE_REGISTRY="''${CL_SOURCE_REGISTRY:+$CL_SOURCE_REGISTRY:}${lib.concatStringsSep ":" resolvedSearchPath}"
      '';

      doMerge =
        other:
        let
          otherArgs = other.args or { };
          mergedSystems = lib.unique (lispSystems' ++ other.lispSystems);
          otherDoCheck = otherArgs.doCheck or false;
          mergedDoCheck = doCheck || otherDoCheck;

          # Deliberately conservative: a `false` here never means "these
          # differ", it means "not provably identical". Nix reports two
          # functions as unequal even when they are the same lambda, and a
          # comparison can itself raise (so it runs under tryEval), while
          # derivations compare cheaply by output path. Everything `==`
          # will not vouch for therefore counts as a conflict: a false
          # positive is an error the caller fixes by aligning two
          # arguments, whereas a false negative is exactly the silent,
          # merge-order-dependent data loss this check exists to remove.
          provablyEqual =
            a: b:
            let
              comparison = builtins.tryEval (a == b);
            in
            comparison.success && comparison.value;

          # Whichever branch below wins, the merged derivation carries just
          # ONE side's arguments outside `interpretedArgs` -- and which side
          # that is depends on the order dedup.nix happened to fold the
          # dependency subtrees in. Rather than let a disagreement decide
          # itself that way, refuse the merge and say so.
          conflictingArgs = lib.filter (
            name: !(provablyEqual (args.${name} or null) (otherArgs.${name} or null))
          ) (lib.subtractLists interpretedArgs (builtins.attrNames (args // otherArgs)));
        in
        if conflictingArgs != [ ] then
          throw ''
            cl-nix-forge: cannot merge ASDF systems ${lib.concatStringsSep ", " lispSystems'} and ${lib.concatStringsSep ", " other.lispSystems}.
            They share a source tree and a dependency closure, so they build as one derivation (see lib/core/dedup.nix) -- but they disagree on the non-dependency argument(s): ${lib.concatStringsSep ", " conflictingArgs}.
            Only one value of each could survive that merge. Give both systems identical values for those arguments, or move them into separate source trees (separate `src`, separate `lispDerivation` calls).
          ''
        else if mergedSystems == other.lispSystems && mergedDoCheck == otherDoCheck then
          other
        else if mergedSystems == lispSystems' && mergedDoCheck == doCheck then
          me
        else
          lispDerivation (
            (removeAttrs args [ "lispSystem" ])
            // {
              _lispDontDeduplicate = true;
              inherit _lispOrigSrc;
              _lispOrigSystems = origSystems;
              lispSystems = mergedSystems;
              doCheck = mergedDoCheck;
              lispDependencies = lib.unique (lispDependencies ++ (otherArgs.lispDependencies or [ ]));
              lispCheckDependencies = lib.unique (
                lispCheckDependencies ++ (otherArgs.lispCheckDependencies or [ ])
              );
              nativeLibraries = lib.unique (nativeLibraries ++ (otherArgs.nativeLibraries or [ ]));
              # The crux of the dedup trick (see dedup.nix): the merged
              # derivation's source IS the other, already-built derivation,
              # so ASDF finds prebuilt fasls in place instead of
              # recompiling raw source a second time.
              src = other;
            }
          );

      me =
        assert lib.assertMsg (incompatibleLispDependencies == [ ])
          "cl-nix-forge lispDerivation: dependencies built by cl-nix-forge must use ${lispImplementation}; incompatible implementations: ${
            lib.concatStringsSep ", " (
              map (dependency: dependency.clNixForgeLispImplementation) incompatibleLispDependencies
            )
          }";
        pkgs.stdenv.mkDerivation (
          passthroughArgs
          // {
            pname = args.pname or (lib.concatStringsSep "-" lispSystems');
            inherit src doCheck;

            nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [ lisp ];
            # Lisp dependencies are made available through ASDF's registry,
            # not nixpkgs setup hooks. Their string context in `searchPath`
            # still makes them build dependencies of this derivation.
            buildInputs = args.buildInputs or [ ];

            # Identity translation: fasls land beside their .lisp source
            # inside the build tree. This is what makes the built derivation
            # directly reusable, unmodified, as a source-registry entry for
            # whoever depends on it next -- no separate output-translation
            # directory to keep in sync.
            ASDF_OUTPUT_TRANSLATIONS = "/:/";

            preConfigurePhases = (args.preConfigurePhases or [ ]) ++ [ "setAsdfPathPhase" ];
            inherit setAsdfPathPhase;

            env =
              let
                providedEnv = args.env or { };
              in
              if transitiveNativeLibraries != [ ] && builtins.hasAttr native.libraryPathVar providedEnv then
                throw "cl-nix-forge: do not set ${native.libraryPathVar} in env when nativeLibraries are present; use a wrapper or add the library to nativeLibraries"
              else
                providedEnv // nativeLibraryEnv transitiveNativeLibraries;

            buildPhase = ''
              runHook preBuild
              ${invokeLisp (mkAsdfScript (lib.concatStringsSep "-" lispSystems') lispBuildOp lispSystems')}
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              cp -R . "$out"
              runHook postInstall
            '';

            checkPhase = ''
              runHook preCheck
              ${invokeLisp (
                mkAsdfScript "${lib.concatStringsSep "-" lispSystems'}-check" [ "asdf:test-system" ] origSystems
              )}
              runHook postCheck
            '';

            shellHook = ''
              eval "$setAsdfPathPhase"
            ''
            + (args.shellHook or "");

            passthru = (args.passthru or { }) // {
              inherit ancestry;
              lispSystems = lispSystems';
              args = args // {
                inherit _lispOrigSrc;
              };
              _lispOrigSrc = _lispOrigSrc;
              nativeLibraries = transitiveNativeLibraries;
              enableCheck = if doCheck then me else lispDerivation (args // { doCheck = true; });
              # The resolved, colon-joined CL_SOURCE_REGISTRY this derivation
              # built with (including the literal, unexpanded "$PWD" token --
              # harmless to repeat verbatim in a consuming shell). Lets a
              # derivation built FROM this one as its `src` (e.g.
              # batteries/app.nix's delivery step) reload the exact same
              # dependency graph without recomputing it.
              registryPath = lib.concatStringsSep ":" resolvedSearchPath;
              clNixForgeLispImplementation = lispImplementation;
              inherit dedupKey;
            };

            meta = (args.meta or { }) // {
              broken = (args.meta.broken or false) || (builtins.any (d: d.meta.broken or false) ancestry.deps);
            };
          }
        );
    in
    assert lib.assertMsg (lispImplementation == actualLispImplementation)
      "cl-nix-forge lispDerivation: lispImplementation `${lispImplementation}` does not match lisp `${actualLispImplementation}`";
    builtins.seq lispSystems' (
      builtins.seq scriptFlags (if _lispDontDeduplicate then me else ancestry.me)
    );

  # One source tree, several exported ASDF systems as separate Nix outputs,
  # automatically deduplicated (see dedup.nix) if they depend on each
  # other. `systems.<name>` is an attrset of extra/overriding arguments for
  # that system's own `lispDerivation` call (its `lispSystem` defaults to
  # the attribute name).
  #
  # Two systems here merge into a single derivation whenever they resolve
  # to the same `dedupKey` (same source tree, implementation, ASDF
  # operations and dependency closure) and something depends on both. Since
  # one derivation can only have one `buildInputs`, one `patches`, one
  # `version`, ..., such a pair must also agree on every argument outside
  # `interpretedArgs`. Disagreement is an evaluation error naming the
  # offending arguments and both systems (see `doMerge`) -- upstream
  # cl-nix-lite instead let whichever side merged last win silently, which
  # made the surviving value depend on dependency-walk order. Give systems
  # that merge identical non-dependency arguments, or split them into
  # separate source trees.
  lispMultiDerivation =
    args:
    lib.mapAttrs (
      name: system:
      let
        nameArg = lib.optionalAttrs (!(system ? lispSystem || system ? lispSystems)) {
          lispSystem = name;
        };
      in
      assert lib.assertMsg (!(system ? src))
        "cl-nix-forge lispMultiDerivation: systems must share the parent src; use separate lispDerivation calls for distinct source trees";
      lispDerivation ((removeAttrs args [ "systems" ]) // nameArg // system)
    ) args.systems;

  # A Lisp implementation binary wrapped so it can `(require "asdf")` and
  # load any of `systems` without further setup -- the basis for
  # lispScript and for an interactive, batteries-included REPL.
  lispWithSystems =
    {
      systems,
      lisp ? pkgs.sbcl,
    }:
    let
      lispImplementation = lib.getName lisp;
      incompatibleLispSystems = lib.filter (
        system:
        system ? clNixForgeLispImplementation && system.clNixForgeLispImplementation != lispImplementation
      ) systems;
      searchPath = lib.unique (lib.concatMap registryPathsFor systems);
      transitiveNativeLibraries = lib.unique (
        lib.concatMap (
          system:
          (system.nativeLibraries or [ ])
          ++ (lib.concatMap (d: d.nativeLibraries or [ ]) (system.ancestry.deps or [ ]))
        ) systems
      );
    in
    assert lib.assertMsg (incompatibleLispSystems == [ ])
      "cl-nix-forge lispWithSystems: systems built by cl-nix-forge must use ${lispImplementation}; incompatible implementations: ${
        lib.concatStringsSep ", " (
          map (system: system.clNixForgeLispImplementation) incompatibleLispSystems
        )
      }";
    pkgs.stdenv.mkDerivation {
      pname = "${lib.getName lisp}-with-systems";
      version = lib.getVersion lisp;
      dontUnpack = true;
      dontBuild = true;
      nativeBuildInputs = [ pkgs.makeWrapper ];
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/bin"
        for f in ${lisp}/bin/*; do
          [ -x "$f" ] && [ -f "$f" ] || continue
          makeWrapper "$f" "$out/bin/$(basename "$f")" \
            --prefix CL_SOURCE_REGISTRY : "${lib.concatStringsSep ":" searchPath}" \
            --set ASDF_OUTPUT_TRANSLATIONS "/:/" \
            ${lib.concatStringsSep " \\\n            " (
              native.nativeLibraryWrapperArgs transitiveNativeLibraries
            )}
        done
        runHook postInstall
      '';
      passthru = {
        nativeLibraries = transitiveNativeLibraries;
      };
    };

  # A Common Lisp script invoked through a lispWithSystems environment, so
  # its declared ASDF dependencies remain available after installation.
  lispScript =
    {
      name,
      src,
      dependencies ? [ ],
      lisp ? pkgs.sbcl,
      lispImplementation ? lib.getName lisp,
      ...
    }@args:
    let
      lispEnvironment = lispWithSystems {
        systems = dependencies;
        inherit lisp;
      };
      actualLispImplementation = lib.getName lisp;
      # Same table row `lispDerivation`'s build phase runs through, consumed
      # one level lower: makeWrapper wants argv words, not a command.
      scriptFlags = scriptFlagsOf "lispScript" lispImplementation;
    in
    assert lib.assertMsg (lispImplementation == actualLispImplementation)
      "cl-nix-forge lispScript: lispImplementation `${lispImplementation}` does not match lisp `${actualLispImplementation}`";
    # Forced here rather than from the lazily-built `installPhase`, so an
    # implementation with no row fails while the caller's own expression is
    # being evaluated. See the matching `builtins.seq` in `lispDerivation`.
    builtins.seq scriptFlags (
      pkgs.stdenv.mkDerivation (
        (removeAttrs args [
          "name"
          "src"
          "dependencies"
          "lisp"
          "lispImplementation"
        ])
        // {
          inherit name src;
          dontUnpack = true;
          nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];
          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin" "$out/lib"
            cp "$src" "$out/lib/${name}.lisp"
            makeWrapper "${lispEnvironment}/bin/${lib.getName lisp}" "$out/bin/${name}" \
              --add-flags "${scriptFlags} $out/lib/${name}.lisp"
            runHook postInstall
          '';
          meta = (args.meta or { }) // {
            mainProgram = name;
          };
        }
      )
    );
}
