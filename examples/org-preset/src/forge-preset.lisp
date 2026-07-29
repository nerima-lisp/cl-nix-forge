(defpackage :forge-preset
  (:use :cl)
  (:export #:describe-preset))

(in-package :forge-preset)

(defun describe-preset (name)
  (format nil "forge-preset builds ~A" name))
