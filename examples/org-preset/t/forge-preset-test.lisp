;;;; Under t/, per PACKAGE_STANDARD.md. `mkPackageFlake` derives its `src`
;;;; from `mkLispSource`, which keeps this directory by the same rule that
;;;; keeps src/ -- if it did not, every generated check would fail to FIND a
;;;; system rather than fail a test.

(defpackage :forge-preset/test
  (:use :cl)
  (:export #:run))

(in-package :forge-preset/test)

(defun run ()
  (let ((actual (forge-preset:describe-preset "flakes")))
    (unless (string= "forge-preset builds flakes" actual)
      (error "forge-preset:describe-preset returned ~S" actual)))
  ;; The test-only sibling, USED rather than merely declared: a suite that
  ;; only named `forge-preset-harness` in :DEPENDS-ON would still fail to load
  ;; without it, but nothing would prove the code came along. Printed, so the
  ;; dev-shell check can grep for it in the runner's own output.
  (format t "~&harness=~A~%" (forge-preset-harness:harness-marker))
  t)
