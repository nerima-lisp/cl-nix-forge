(in-package #:asdf-user)

(asdf:defsystem "forge-tests/alpha"
  :pathname "t/alpha/"
  :components ((:file "test-alpha"))
  :perform (compile-op (operation component)
             (declare (ignore operation component))
             (eval (list 'asdf:defsystem
                         "forge-tests/alpha/deep"
                         :pathname "t/alpha/"
                         :components nil))))

(asdf:defsystem "forge-tests/beta"
  :pathname "t/beta/"
  :components ((:file "test-beta")))
