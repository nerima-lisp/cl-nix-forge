(asdf:defsystem "forge-demo-cli"
  :version "0.3.1"
  :description "Delivered executable half of the flake-outputs example"
  :depends-on ("forge-demo" "uiop")
  ;; The .asd, not Nix, decides HOW the binary is built. mkExecutable only
  ;; controls the invocation of the Lisp that performs the dump.
  :build-operation "program-op"
  :build-pathname "forge-demo-cli"
  :entry-point "forge-demo-cli:main"
  :components ((:file "forge-demo-cli")))
