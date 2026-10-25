(asdf:defsystem "forge-tests/alpha"
  :licence "MIT"
  :license "MIT"
  :components ((:module "t"
                :components ((:module "alpha"
                              :components ((:file "test-alpha"
                                            :type "lisp")))))))

(asdf:defsystem "forge-tests/beta"
  :components ((:module "t"
                :components ((:module "beta"
                              :components ((:file "test-beta")))))))
