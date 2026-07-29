(defpackage :core-a
  (:use :cl)
  (:export :ping))
(in-package :core-a)

(defun ping () "pong from core-a")
