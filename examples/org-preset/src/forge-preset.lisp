(defpackage :forge-preset
  (:use :cl)
  (:export #:describe-preset #:image-entry-point))

(in-package :forge-preset)

(defun describe-preset (name)
  (format nil "forge-preset builds ~A" name))

(defun image-entry-point ()
  "Toplevel of the binary `mkExecutable` delivers from this system.

Named by :ENTRY-POINT in forge-preset.asd, and reached by the check that
round trips `ctx.lispDerivationArgs` straight back into `mkExecutable`: that
call overrides nothing at all, so the system it delivers is the package's
own."
  (format t "~&~A~%" (describe-preset "a delivered image"))
  (finish-output)
  (uiop:quit 0))
