(defpackage :greeter-app
  (:use :cl)
  (:export :main))

(in-package :greeter-app)

(defun main ()
  (format t "~a~%" (greeter:greet "executable")))
