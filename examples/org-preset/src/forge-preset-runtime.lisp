(defpackage :forge-preset/runtime
  (:use :cl)
  (:export #:runtime-marker))

(in-package :forge-preset/runtime)

(defun runtime-marker ()
  (format nil "~A|~A"
          (forge-preset-support:support-marker)
          (forge-preset:describe-preset "a system loaded at run time")))
