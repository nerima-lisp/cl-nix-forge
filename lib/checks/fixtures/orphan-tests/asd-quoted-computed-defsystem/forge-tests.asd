(in-package #:asdf-user)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (eval '(list (external-operator-provider)
             "forge-tests/dynamic"
             :pathname "t/alpha/"
             :components nil)))

(asdf:defsystem "forge-tests/alpha"
  :pathname "t/alpha/"
  :components ((:file "test-alpha")))

(asdf:defsystem "forge-tests/beta"
  :pathname "t/beta/"
  :components ((:file "test-beta")))
