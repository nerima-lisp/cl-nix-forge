(in-package #:asdf-user)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter *non-system-form-fixture* t))

(asdf:defsystem "forge-tests/alpha"
  :pathname "t/alpha/"
  :components ((:file "test-alpha")))

(asdf:defsystem "forge-tests/beta"
  :pathname "t/beta/"
  :components ((:file "test-beta")))
