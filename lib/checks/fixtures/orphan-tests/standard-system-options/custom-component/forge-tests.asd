(asdf:defsystem "forge-tests/alpha"
  :components ((:module "t"
                :components ((:module "alpha"
                              :components ((:forge-custom-source "custom" :custom-option "value"))))))
  :depends-on ("fixture-dependency"))
(asdf:defsystem "forge-tests/beta"
  :components ((:module "t"
                :components ((:module "beta"
                              :components ((:file "test-beta")))))))
