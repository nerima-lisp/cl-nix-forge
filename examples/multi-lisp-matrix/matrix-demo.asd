(asdf:defsystem "matrix-demo"
  :version "0.1.0"
  :description "Exercises core/matrix.nix's mkCheckMatrix under both SBCL and ECL, plus an externalBins dependency."
  :components ((:file "matrix-demo"))
  :in-order-to ((asdf:test-op (asdf:test-op "matrix-demo/test"))))

(asdf:defsystem "matrix-demo/test"
  :depends-on ("matrix-demo")
  :components ((:file "matrix-demo-test")))
