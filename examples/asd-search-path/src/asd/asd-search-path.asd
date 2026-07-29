(asdf:defsystem "asd-search-path"
  :version "0.1.0"
  :description "Exercises lispAsdPath with an ASDF definition below the source root"
  :components ((:file "asd-search-path"))
  :in-order-to ((asdf:test-op (asdf:test-op "asd-search-path/test"))))

(asdf:defsystem "asd-search-path/test"
  :depends-on ("asd-search-path")
  :components ((:file "asd-search-path-test")))
