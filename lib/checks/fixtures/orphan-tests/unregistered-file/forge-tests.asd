(asdf:defsystem "forge-tests/alpha"
  :description "Alpha's static orphan-test fixture"
  :pathname "t/alpha/"
  :serial t
  :components ((:file "package")
               (:file "helpers")
               (:module "nested"
                :serial t
                :components ((:file "deep-helper")))))

(asdf:defsystem "forge-tests/beta"
  :description "Beta's static orphan-test fixture"
  :pathname "t/beta/"
  :serial t
  :components ((:file "package")
               (:file "assertions")
               (:module "nested"
                :serial t
                :components ((:file "support")))))
