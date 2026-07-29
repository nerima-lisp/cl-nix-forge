;;;; A run-tests.lisp-shaped entry point that never terminates.
;;;;
;;;; `checks.forge-checks-timeout-kills-runaway` runs this under a small
;;;; `timeoutSeconds` and asserts the check dies at the deadline with an
;;;; attributable exit status (124 from SIGTERM, or 137 when the SIGKILL
;;;; escalation had to fire) rather than hanging until the CI job's own
;;;; timeout, where the failure has no owner.

(require "asdf")

(let ((root (uiop:pathname-directory-pathname
             (or *load-truename* *load-pathname* (uiop:getcwd)))))
  (asdf:initialize-source-registry
   `(:source-registry (:directory ,root) :inherit-configuration))
  (asdf:load-system "forge-checks"))

(format t "~&forge-checks: entering an uninterruptible loop on purpose.~%")
(finish-output *standard-output*)
(uiop:symbol-call :forge-checks :spin)
