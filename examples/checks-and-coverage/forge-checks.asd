(asdf:defsystem "forge-checks"
  :version "0.1.0"
  :description "A library exercised only through run-tests.lisp, for mkScriptCheck/mkCommandCheck/mkCoverageReport."
  :components ((:file "forge-checks"))
  :in-order-to ((asdf:test-op (asdf:test-op "forge-checks/test"))))

;; This test-op deliberately errors. It stands in for cl-weave's real
;; constraint: a suite that itself performs test-op cannot also be driven BY
;; an enclosing test-op, because ASDF then sees the same operation twice on
;; one plan and rejects it as a circular dependency. Because this errors, a
;; passing `mkScriptCheck` over this system is by itself proof that the check
;; did not route through `asdf:test-system`.
(asdf:defsystem "forge-checks/test"
  :depends-on ("forge-checks")
  :components ((:file "forge-checks-test"))
  :perform (asdf:test-op (o c)
             (declare (ignore o c))
             (error "forge-checks/test is driven by run-tests.lisp, never by asdf:test-system")))
