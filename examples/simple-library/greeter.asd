(asdf:defsystem "greeter"
  :version "0.1.0"
  :description "A trivial single-system library, for exercising fromAsdSystem/mkTestCheck/mkDocsSite/mkDevShell."
  :components ((:file "greeter"))
  :in-order-to ((asdf:test-op (asdf:test-op "greeter/test"))))

(asdf:defsystem "greeter/test"
  :depends-on ("greeter")
  :components ((:file "greeter-test")))
