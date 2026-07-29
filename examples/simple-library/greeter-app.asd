(asdf:defsystem "greeter-app"
  :version "0.1.0"
  :description "A delivered executable that uses greeter"
  :depends-on ("greeter")
  :build-operation "program-op"
  :build-pathname "greeter-app"
  :entry-point "greeter-app:main"
  :components ((:file "greeter-app")))
