;;;; A sibling library, deliberately OUTSIDE the preset's own source tree
;;;; (`common.sourceExclude` drops this directory), so the only route by
;;;; which the delivered binary can reach it is `mkPackageFlake`'s
;;;; `lispDependencies` argument. That is what makes the `executable` check
;;;; in default.nix mean something: an `mkExecutable` built from re-spelled
;;;; arguments instead of the preset's own resolved ones would not have this
;;;; system on its registry at all.

(defsystem "forge-preset-support"
  :description "Sibling dependency of the org-preset example's delivered CLI"
  :license "MIT"
  :version "0.5.3"
  :serial t
  :components ((:file "forge-preset-support")))
