(defpackage :core-b (:use :cl) (:export :run :run-tests))
(in-package :core-b)

(defun run () (format nil "core-b says: ~A" (core-a:ping)))

(defun run-tests () (assert (string= "core-b says: pong from core-a" (run)) () "core-b must load core-a from the merged derivation"))
