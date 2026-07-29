(defpackage :forge-checks/test
  (:use :cl)
  (:export :run))

(in-package :forge-checks/test)

(defun run ()
  "Return T when every assertion holds, NIL otherwise.

Returning a boolean rather than signalling keeps the pass/fail decision in
run-tests.lisp, which is what the org-standard entry point owns."
  (and (= 0 (forge-checks:tally '()))
       (= 6 (forge-checks:tally '(1 2 3)))
       (= 15 (forge-checks:tally '(4 5 6)))))
