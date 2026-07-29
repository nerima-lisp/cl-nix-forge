{ lib }:
{
  # The `src` a Lisp build should actually see, as an ALLOWLIST.
  #
  # Why an allowlist and not `cleanSource` plus exclusions: the denylist
  # shape that every downstream repo independently arrived at is wrong in
  # both directions, and both failure modes are silent.
  #
  # Too permissive. `lib.cleanSourceFilter` keeps `.fasl`/`.core` (it only
  # drops `.o`/`.so`), keeps any directory whose name merely starts with
  # "result", and of course cannot know about the next artefact directory a
  # tool invents. A working tree that has had `sbcl --script run-tests.lisp`
  # run in it therefore hashes differently from a clean checkout, so every
  # local test run invalidates the whole build. That is not hypothetical:
  # cl-weave's tree accumulates `coverage-report-*/` and
  # `watch-forward-dependencies-*/` directories from local runs, none of
  # which any denylist written before those tools existed could have named.
  #
  # Too restrictive, apparently. cl-prolog's filter re-includes `t/` with
  # the note that `cleanSourceFilter` drops it. It does not -- verified
  # against nixpkgs' `lib/sources.nix`, which has no rule matching `t`. The
  # test sources really were missing, but because they were untracked in a
  # Git-backed flake input, which the same comment goes on to say a filter
  # cannot fix. A denylist gives you no way to tell those two causes apart;
  # an allowlist makes the question moot, because `t/*.lisp` is included by
  # the same rule as `src/*.lisp` and needs no special case at all.
  #
  # So: name what an ASDF build reads (system definitions and Lisp source),
  # and let everything else be opted in. This is the same trade `crane`
  # makes with `cleanCargoSource`, for the same reason -- unrelated files
  # must not be able to trigger a rebuild.
  #
  #   root       :: the project root. A plain path or a store path (a
  #                 flake's own `self`) both work.
  #   extensions :: [ String ] ? [ "asd" "lisp" ] -- file extensions taken
  #                 as Lisp source anywhere under `root`. Deliberately not
  #                 including "lsp"/"cl": nothing here uses them, and a
  #                 project that does should say so rather than have the
  #                 default quietly widen for everyone.
  #   include    :: [ fileset ] ? [ ] -- anything else the build genuinely
  #                 reads: `:static-file` fixtures, a CFFI grovel `.h`, the
  #                 `docs/` tree a `mkDocsSite` shares this source with.
  #   exclude    :: [ fileset ] ? [ ] -- subtracted last, for the rare
  #                 vendored-source-tree-we-do-not-build case.
  #
  # A missing fixture fails loudly at build or test time. A stray `.fasl`
  # silently changes a hash. The default errs toward the loud failure.
  mkLispSource =
    {
      root,
      extensions ? [
        "asd"
        "lisp"
      ],
      include ? [ ],
      exclude ? [ ],
    }:
    let
      lispSources = lib.fileset.fileFilter (file: lib.any file.hasExt extensions) root;
      included = lib.fileset.unions ([ lispSources ] ++ include);
    in
    lib.fileset.toSource {
      inherit root;
      fileset =
        if exclude == [ ] then included else lib.fileset.difference included (lib.fileset.unions exclude);
    };
}
