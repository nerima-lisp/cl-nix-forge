;;;; Lisp-level entry point for the forge-checks suite.
;;;;
;;;;     sbcl --script run-tests.lisp
;;;;
;;;; Every nerima-lisp package exposes this same file at its root, so tooling
;;;; that runs a package's tests never has to know how that package loads its
;;;; suite. See PACKAGE_STANDARD.md in nerima-lisp/.github. `mkScriptCheck`
;;;; defaults to this filename for exactly that reason.

(require "asdf")

(let ((root (uiop:pathname-directory-pathname
             (or *load-truename* *load-pathname* (uiop:getcwd)))))
  ;; Resolve forge-checks out of THIS checkout regardless of what the caller's
  ;; CL_SOURCE_REGISTRY points at, so the script can never silently test a
  ;; different copy of the code the working tree is changing.
  (asdf:initialize-source-registry
   `(:source-registry (:directory ,root) :inherit-configuration))

  ;; Load and run, never asdf:test-system -- forge-checks.asd defines a
  ;; test-op that errors on purpose. `uiop:symbol-call` because this whole
  ;; `let` is one top-level form: the :forge-checks/test package does not
  ;; exist yet when the form is READ.
  (asdf:load-system "forge-checks/test")
  (unless (uiop:symbol-call :forge-checks/test :run)
    (format *error-output* "~&forge-checks suite failed.~%")
    (finish-output *error-output*)
    (uiop:quit 1)))

(format t "~&forge-checks suite passed.~%")
(finish-output *standard-output*)
(uiop:quit 0)
