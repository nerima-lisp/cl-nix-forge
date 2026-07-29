;;;; A sibling library the SUITE needs and the library does not -- cl-weave's
;;;; role for both cl-json-kit and cl-prolog, whose `<pkg>/test` systems
;;;; depend on it and whose exported systems do not.
;;;;
;;;; Like support/, this directory is outside the preset's own source tree
;;;; (`common.sourceExclude` drops it), so `forge-preset/test` compiles only
;;;; when something put this system on CL_SOURCE_REGISTRY. The difference
;;;; from support/ is WHICH argument may do that: this one is reachable only
;;;; through `lispCheckDependencies`, which `lispDerivation` resolves when
;;;; `doCheck` is true and drops entirely when it is not. That is exactly the
;;;; asymmetry the dev shell used to get wrong.

(defsystem "forge-preset-harness"
  :description "Test-only sibling dependency of the org-preset example"
  :license "MIT"
  :version "0.5.3"
  :serial t
  :components ((:file "forge-preset-harness")))
