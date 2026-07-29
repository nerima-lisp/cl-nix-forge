(defpackage :check-only-support
  (:use :cl)
  (:export :expected-message))

(in-package :check-only-support)

(defun expected-message () "available only while testing")
