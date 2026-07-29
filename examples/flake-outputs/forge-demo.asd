(asdf:defsystem "forge-demo"
  :version "0.3.1"
  :description "Library half of the flake-outputs example"
  :components ((:file "forge-demo"))
  :in-order-to ((asdf:test-op (asdf:test-op "forge-demo/test"))))

(asdf:defsystem "forge-demo/test"
  :version "0.3.1"
  :description "Test system, deliberately kept under t/"
  :depends-on ("forge-demo")
  :pathname "t/"
  :components ((:file "forge-demo-test"))
  :perform (asdf:test-op (o c) (uiop:symbol-call :forge-demo/test :run)))
