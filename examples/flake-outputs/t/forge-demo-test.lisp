;;;; Lives under t/ on purpose: cl-prolog's hand-written source filter needed a
;;;; special clause to keep this directory, and mkLispSource must keep it with
;;;; no special clause at all. If the filter drops t/, every check that loads
;;;; forge-demo/test fails to find a system rather than failing a test.

(defpackage :forge-demo/test
  (:use :cl)
  (:export #:run))

(in-package :forge-demo/test)

(defun run ()
  (unless (string= "forge-demo greets Nix" (forge-demo:banner "Nix"))
    (error "forge-demo:banner returned ~S" (forge-demo:banner "Nix")))
  t)
