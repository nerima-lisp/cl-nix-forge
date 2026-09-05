(defpackage :matrix-demo-fail
  (:use :cl)
  (:export :always-wrong))
(in-package :matrix-demo-fail)

;; Loads cleanly: only `asdf:test-system` may fail. The negative check
;; must therefore show that the CHECK phase propagated the failure rather
;; than the build phase failing first.
(defun always-wrong ()
  :wrong)
