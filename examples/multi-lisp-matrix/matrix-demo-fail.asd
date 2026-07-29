(asdf:defsystem "matrix-demo-fail"
  :version "0.1.0"
  :description "A system whose test suite always fails, so the matrix can prove that a failure propagates as a non-zero exit under every Lisp implementation."
  :components ((:file "matrix-demo-fail"))
  :in-order-to ((asdf:test-op (asdf:test-op "matrix-demo-fail/test"))))

(asdf:defsystem "matrix-demo-fail/test"
  :depends-on ("matrix-demo-fail")
  :components ((:file "matrix-demo-fail-test")))
