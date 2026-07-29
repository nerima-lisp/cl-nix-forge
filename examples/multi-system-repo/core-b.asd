(asdf:defsystem "core-b" :version "0.1.0" :description "Second system depending on the first" :depends-on ("core-a") :components ((:file "core-b")) :in-order-to ((asdf:test-op (asdf:test-op "core-b/test"))))

(asdf:defsystem "core-b/test" :depends-on ("core-b") :components ((:file "core-b-test")))
