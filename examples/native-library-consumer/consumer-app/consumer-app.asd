(asdf:defsystem "consumer-app"
  :version "0.1.0"
  :description "An executable that loads a transitive native library"
  :depends-on ("consumer2")
  :build-operation "program-op"
  :build-pathname "consumer-native-app"
  :entry-point "consumer-app:main"
  :components ((:file "consumer-app")))
