(asdf:defsystem "check-only-main"
  :version "0.1.0"
  :description "A main system whose test system has a check-only dependency"
  :components ((:file "check-only-main"))
  :in-order-to ((asdf:test-op (asdf:test-op "check-only-main/test"))))

(asdf:defsystem "check-only-main/test"
  :depends-on ("check-only-main" "check-only-support")
  :components ((:file "check-only-main-test")))
