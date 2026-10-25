(asdf:defsystem "forge-tests/alpha"
  :components ((:module "t"
                :components ((:module "alpha"
                              :components ((:file "test-alpha"
                                            :unrecognized-component-option t))))))
) (asdf:defsystem "forge-tests/beta"
  :components ((:module "t"
                :components ((:module "beta"
                              :components ((:file "test-beta")))))))