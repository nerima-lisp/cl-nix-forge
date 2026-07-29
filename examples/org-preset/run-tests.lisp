;;;; The org-standard Lisp-level entry point.
;;;;
;;;;     sbcl --script run-tests.lisp
;;;;     nix run .#test
;;;;
;;;; `mkPackageFlake` drives this same file from BOTH `checks.default` (through
;;;; `mkScriptCheck`) and `apps.test` (through `mkTestApp`), which is the whole
;;;; reason the standard mandates it: the command a contributor runs by hand
;;;; and the gate CI runs cannot drift apart when there is only one of them.

(require "asdf")

(let ((root (uiop:pathname-directory-pathname
             (or *load-truename* *load-pathname* (uiop:getcwd)))))
  ;; Resolve forge-preset out of THIS tree regardless of what the caller's
  ;; CL_SOURCE_REGISTRY points at, so the suite can never end up testing a
  ;; released copy of the code the working tree is changing.
  (asdf:initialize-source-registry
   `(:source-registry (:directory ,root) :inherit-configuration))

  (handler-case
      (progn
        (asdf:load-system "forge-preset/test")
        (uiop:symbol-call :forge-preset/test :run))
    (error (condition)
      (format *error-output* "~&forge-preset suite failed: ~A~%" condition)
      (finish-output *error-output*)
      (uiop:quit 1))))

(format t "~&forge-preset suite passed.~%")
(finish-output *standard-output*)
(uiop:quit 0)
