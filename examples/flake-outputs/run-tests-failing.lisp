;;;; The failing counterpart of run-tests.lisp, so a check can prove that
;;;; `mkTestApp` propagates a red suite instead of reporting success. It takes
;;;; the same load path as the real runner and then fails an assertion, rather
;;;; than exiting 1 immediately -- a runner that swallowed a Lisp-level failure
;;;; but honoured an explicit `uiop:quit 1` would still look correct.

(require "asdf")

(let ((root (uiop:pathname-directory-pathname
             (or *load-truename* *load-pathname* (uiop:getcwd)))))
  (asdf:initialize-source-registry
   `(:source-registry (:directory ,root) :inherit-configuration))

  (handler-case
      (progn
        (asdf:load-system "forge-demo/test")
        ;; `uiop:symbol-call`, not `forge-demo:banner`: --script reads each
        ;; top-level form before evaluating it, so a package-qualified symbol
        ;; in this form would fail in the READER before load-system had a
        ;; chance to create the package -- which would make this fixture
        ;; "fail" for a reason that has nothing to do with the suite.
        (unless (string= "this never matches" (uiop:symbol-call :forge-demo :banner "Nix"))
          (error "deliberate assertion failure")))
    (error (condition)
      (format *error-output* "~&forge-demo suite failed: ~A~%" condition)
      (finish-output *error-output*)
      (uiop:quit 1))))

(finish-output *standard-output*)
(uiop:quit 0)
