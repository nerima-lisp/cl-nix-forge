(defpackage :matrix-demo-fail
  (:use :cl)
  (:export :always-wrong))
(in-package :matrix-demo-fail)

;; Loads cleanly on purpose: only `asdf:test-system` may fail, so a
;; negative check that passes proves the CHECK phase propagated a failure
;; rather than the build phase having fallen over first.
(defun always-wrong ()
  :wrong)
