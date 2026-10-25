(asdf:defsystem "forge-tests/alpha"
  :components ((:module "t"
                :components ((:module "alpha"
                              :components ((:file "test_alpha")))))))

(asdf:defsystem "forge-tests/beta"
  :components ((:module "t"
                :components ((:module "beta"
                              :components ((:file "test-beta")))))))
