(defpackage :check-only-main
  (:use :cl)
  (:export :message))

(in-package :check-only-main)

(defun message () "main build does not load test support")
