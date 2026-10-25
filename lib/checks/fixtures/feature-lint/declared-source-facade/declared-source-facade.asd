(asdf:defsystem "declared-source-facade"
  :components
  ((:module "src"
    :components
    ((:module "facades"
      :components
      ((:file "target-package"
        :pathname #p"../target-package.lisp")
       (:file "target-package-alt"
        :pathname #p"../target-package-alt.cl")))
     (:module "typed"
      :default-component-class :cl-source-file.cl
      :components
      ((:file "target-package-typed")
       (:cl-source-file.cl "target-package-explicit-type")))
     (module "symbol-module"
      :default-component-class cl-source-file.cl
      :components
      ((:file "target-package-symbol-module")))))
   (:file "shared-facade"
    :pathname #p"shared/facade.lisp")))

