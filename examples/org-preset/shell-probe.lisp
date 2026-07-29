;;;; What a dev shell can actually LOAD, reported one line per system.
;;;;
;;;; Run inside the environment `mkPackageFlake`'s generated `devShells.default`
;;;; exports (see default.nix), where it distinguishes the two dependency
;;;; kinds the preset takes: `forge-preset-support` arrives through
;;;; `lispDependencies`, `forge-preset-harness` only through
;;;; `lispCheckDependencies`. Neither lives in this tree, so neither can be
;;;; resolved by the `$PWD` entry the shell puts first.
;;;;
;;;; Deliberately NO `asdf:initialize-source-registry` -- unlike
;;;; run-tests.lisp, which anchors on its own directory so a released copy on
;;;; the registry cannot be tested by mistake. Here the exported
;;;; CL_SOURCE_REGISTRY IS the subject, so configuring anything would test
;;;; this file instead of the shell.
;;;;
;;;; It exits 0 either way, on purpose: a missing system must be reported as
;;;; a line the caller greps for, not as a build failure indistinguishable
;;;; from the fifty other ways a Lisp run can die.

(require "asdf")

(defun probe (system package symbol)
  (handler-case
      (progn
        (asdf:load-system system)
        (format t "~&probe: ~A=~A~%" system (uiop:symbol-call package symbol)))
    (error (condition)
      (format t "~&probe: ~A=MISSING (~A)~%" system (type-of condition)))))

(probe "forge-preset-support" :forge-preset-support :support-marker)
(probe "forge-preset-harness" :forge-preset-harness :harness-marker)

(finish-output *standard-output*)
(uiop:quit 0)
