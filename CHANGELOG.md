# Changelog

## [0.7.4]

- Read `.asd` forms as data, accept `in-package` and unrelated top-level forms,
  and reject nested or computed `DEFSYSTEM` references.
  Accept declared system names with multiple slash-separated segments.
- Treat existing `.lisp` files used by literal-path file operations in test
  code as support files.
- Check glossary types and functions against feature domain package exports;
  the snapshot contract checks facade export-surface membership.

## [0.7.3]

- Discover facade packages in declared source directories and ASDF components without assuming a filename.
- Align `orphan-tests` with the ASDF defsystem grammar for system options, component options, names, and pathnames.
- Validate every package listed in a feature glossary entry against its declared domain and infrastructure packages.
