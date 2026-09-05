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
  # "result", and cannot predict the next artefact directory a
  # tool creates. A working tree that has had `sbcl --script run-tests.lisp`
  # run in it therefore hashes differently from a clean checkout, so every
  # local test run invalidates the whole build. That is not hypothetical:
  # cl-weave's tree accumulates `coverage-report-*/` and
  # `watch-forward-dependencies-*/` directories from local runs, none of
  # which any denylist written before those tools existed could have named.
  #
  # An allowlist by EXTENSION narrows that, it does not close it, and the
  # difference matters to anyone reading this as a promise. Of the two
  # directories above, `coverage-report-*/` is excluded (it holds HTML) and
  # `watch-forward-dependencies-*/` is NOT (it holds generated `.lisp`), so
  # `nix build path:.` still rehashes after a local watch run. What does
  # close it is the flake source being Git-backed: both directories are
  # gitignored, so `nix build .#` and CI never see either.
  #
  # A denylist cannot distinguish ignored files from files omitted by the
  # source filter. An allowlist includes `t/*.lisp` through the same rule as
  # `src/*.lisp`, so no special case is needed.
  #
  # So: name what an ASDF build reads (system definitions and Lisp source),
  # and let everything else be opted in. This is the same trade `crane`
  # makes with `cleanCargoSource`, for the same reason -- unrelated files
  # must not be able to trigger a rebuild.
  #
  #   root       :: the project root. A plain path or a store path (a
  #                 flake's own `self`) both work.
  #   extensions :: [ String ] ? [ "asd" "lisp" ] -- file extensions taken
  #                 as Lisp source anywhere under `root`. It does not include
  #                 `lsp` or `cl`: nothing here uses them, and a project that
  #                 does should add them explicitly.
  #   include    :: [ fileset ] ? [ ] -- other files the build
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
