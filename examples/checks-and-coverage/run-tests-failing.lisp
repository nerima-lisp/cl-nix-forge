;;;; A run-tests.lisp-shaped entry point that fails on purpose.
;;;;
;;;; `checks.forge-checks-failing-entry-point-is-detected` runs this through
;;;; `mkScriptCheck` and asserts the resulting check really does fail. A test
;;;; harness that cannot report a failure is worse than no harness, and
;;;; nothing but an actually-failing run proves it can.

(require "asdf")

(let ((root (uiop:pathname-directory-pathname
             (or *load-truename* *load-pathname* (uiop:getcwd)))))
  (asdf:initialize-source-registry
   `(:source-registry (:directory ,root) :inherit-configuration))

  (asdf:load-system "forge-checks")
  (unless (= 99 (uiop:symbol-call :forge-checks :tally '(1 2 3)))
    (format *error-output* "~&forge-checks: deliberate failure, tally of (1 2 3) is not 99.~%")
    (finish-output *error-output*)
    (uiop:quit 1)))

(format *error-output* "~&forge-checks: the deliberate failure did not happen.~%")
(finish-output *error-output*)
(uiop:quit 0)
