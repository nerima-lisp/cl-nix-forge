;;;; Lisp-level entry point for the forge-demo suite.
;;;;
;;;;     sbcl --script run-tests.lisp
;;;;     nix run .#test
;;;;
;;;; Every nerima-lisp package exposes this same file at its root, which is why
;;;; `mkTestApp` drives it rather than re-spelling an ASDF invocation in Nix.

(require "asdf")

(let ((root (uiop:pathname-directory-pathname
             (or *load-truename* *load-pathname* (uiop:getcwd)))))
  ;; Resolve forge-demo out of THIS tree regardless of what the caller's
  ;; CL_SOURCE_REGISTRY points at, so the suite can never end up testing a
  ;; released copy of the code the working tree is changing.
  (asdf:initialize-source-registry
   `(:source-registry (:directory ,root) :inherit-configuration))

  (handler-case
      (progn
        (asdf:load-system "forge-demo/test")
        (uiop:symbol-call :forge-demo/test :run))
    (error (condition)
      (format *error-output* "~&forge-demo suite failed: ~A~%" condition)
      (finish-output *error-output*)
      (uiop:quit 1))))

(finish-output *standard-output*)
(uiop:quit 0)
