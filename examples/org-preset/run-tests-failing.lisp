;;;; The failing counterpart of run-tests.lisp, so a check can prove that the
;;;; preset's generated `checks.default` reports a red suite instead of
;;;; swallowing it. It takes the same load path as the real runner and then
;;;; fails an assertion, rather than exiting 1 immediately -- a check that
;;;; swallowed a Lisp-level failure but honoured an explicit `uiop:quit 1`
;;;; would still look correct.

(require "asdf")

(let ((root (uiop:pathname-directory-pathname
             (or *load-truename* *load-pathname* (uiop:getcwd)))))
  (asdf:initialize-source-registry
   `(:source-registry (:directory ,root) :inherit-configuration))

  (handler-case
      (progn
        (asdf:load-system "forge-preset/test")
        ;; `uiop:symbol-call`, not `forge-preset:describe-preset`: --script
        ;; reads each top-level form before evaluating it, so a
        ;; package-qualified symbol here would fail in the READER before
        ;; load-system had a chance to create the package -- which would make
        ;; this fixture "fail" for a reason unrelated to the suite.
        (unless (string= "this never matches"
                         (uiop:symbol-call :forge-preset :describe-preset "flakes"))
          (error "deliberate assertion failure")))
    (error (condition)
      (format *error-output* "~&forge-preset suite failed: ~A~%" condition)
      (finish-output *error-output*)
      (uiop:quit 1))))

(finish-output *standard-output*)
(uiop:quit 0)
