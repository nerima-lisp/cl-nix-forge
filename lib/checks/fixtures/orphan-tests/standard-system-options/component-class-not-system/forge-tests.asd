(asdf:defsystem "forge-tests/alpha"
  :components ((:module "t"
                :components ((:module "alpha"
                              :components ((:file "test-alpha"
                                            :class :cl-source-file))))))

) (asdf:defsystem "forge-tests/beta"
  :components ((:module "t"
                :components ((:module "beta"
                              :components ((:file "test-beta")))))))