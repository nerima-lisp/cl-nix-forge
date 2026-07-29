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
  t)
