(defpackage :greeter
  (:use :cl)
  (:export :greet))
(in-package :greeter)

(defun greet (name)
  (format nil "Hello, ~A, from cl-nix-forge!" name))
