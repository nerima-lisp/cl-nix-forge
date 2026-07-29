(defpackage :matrix-demo-test
  (:use :cl))
(in-package :matrix-demo-test)

(assert (string= "matrix-probe: ready"
                 (string-trim '(#\Space #\Tab #\Newline #\Return)
                              (matrix-demo:run-matrix-probe))))
(format t "matrix-demo/test: passed on ~A~%" (lisp-implementation-type))
