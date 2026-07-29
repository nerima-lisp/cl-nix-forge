(defpackage :matrix-demo
  (:use :cl)
  (:export :run-matrix-probe))
(in-package :matrix-demo)

(defun run-matrix-probe ()
  "Returns the output of the matrix-probe binary supplied by externalBins."
  (uiop:run-program '("matrix-probe") :output :string))
