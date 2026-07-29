(asdf:defsystem "consumer2"
  :version "0.1.0"
  :description "Depends only on consumer1, NOT on natlib directly -- proves native.nix propagates the search path two hops, unlike prior art's one-hop, name-gated setup hook."
  :depends-on ("consumer1")
  :components ((:file "consumer2"))
  :in-order-to ((asdf:test-op (asdf:test-op "consumer2/test"))))

(asdf:defsystem "consumer2/test"
  :depends-on ("consumer2")
  :components ((:file "consumer2-test")))
