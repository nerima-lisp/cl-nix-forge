((:feature "nodes"
  :source-dirs ("src/nodes")
  :test-dir "t/nodes"
  :facade-packages
  ("cl-cc/target" "cl-cc/target-alt" "cl-cc/target-typed"
   "cl-cc/target-explicit-type" "cl-cc/target-shared"
   "cl-cc/target-symbol-module")
  :domain-package "fixture/valid/nodes"
  :infra-package nil
  :depends-on ()))
