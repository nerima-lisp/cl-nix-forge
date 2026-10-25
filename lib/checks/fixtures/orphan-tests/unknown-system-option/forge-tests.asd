(asdf:defsystem "forge-tests/alpha"
  :unrecognized-system-option t
  :components ((:module "t"
                :components ((:module "alpha"
                              :components ((:file "test-alpha"))))))
) (asdf:defsystem "forge-tests/beta"
  :components ((:module "t"
                :components ((:module "beta"
                              :components ((:file "test-beta")))))))