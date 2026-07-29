(defpackage :matrix-demo-fail-test
  (:use :cl))
(in-package :matrix-demo-fail-test)

(format t "matrix-demo-fail/test: about to fail on ~A~%" (lisp-implementation-type))
(finish-output)

;; Dropped in the build tree, which `installPhase` copies to $out -- and
;; checkPhase runs before installPhase, so the file exists in the output
;; only if this suite actually ran. That is the positive control for
;; `expectedFailure`: without it, an `expectedFailure` entry that silently
;; skipped the check would look exactly like one that tolerated it.
(with-open-file (marker "matrix-demo-fail-ran"
                        :direction :output
                        :if-exists :supersede)
  (format marker "~A~%" (lisp-implementation-type)))

;; A failing ASSERT rather than a bare ERROR: this is how a real suite
;; fails, and ASSERT establishes a CONTINUE restart, so an implementation
;; whose non-interactive mode quietly took that restart would still exit 0.
;; That is precisely the trap these negative checks exist to catch.
(assert (eq :right (matrix-demo-fail:always-wrong)))

(format t "matrix-demo-fail/test: UNREACHABLE~%")
