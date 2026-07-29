(defpackage :forge-preset-harness
  (:use :cl)
  (:export #:harness-marker))

(in-package :forge-preset-harness)

(defun harness-marker ()
  "FORGE-PRESET-HARNESS-REACHED-THE-SHELL")
