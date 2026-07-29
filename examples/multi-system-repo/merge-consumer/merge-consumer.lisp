(defpackage :merge-consumer
  (:use :cl)
  (:export :run))
(in-package :merge-consumer)

(defun run () (format nil "merge-consumer sees: ~A" (core-b:run)))

;; Loading this file at all proves both halves of the merged derivation are
;; on CL_SOURCE_REGISTRY: core-b comes from the merge-consumer system's own
;; :depends-on, and core-a only from core-b's.
(assert (string= "merge-consumer sees: core-b says: pong from core-a" (run)))
