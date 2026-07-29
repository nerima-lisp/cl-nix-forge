(defpackage :consumer-app
  (:use :cl)
  (:export :main))

(in-package :consumer-app)

(defun main ()
  (format t "~d~%" (consumer1:native-answer)))
