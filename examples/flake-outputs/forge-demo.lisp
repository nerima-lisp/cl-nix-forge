(defpackage :forge-demo
  (:use :cl)
  (:export #:banner))

(in-package :forge-demo)

(defun banner (name)
  (format nil "forge-demo greets ~A" name))
