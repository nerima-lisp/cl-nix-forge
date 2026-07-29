(defpackage :greeter-test
  (:use :cl))
(in-package :greeter-test)

(assert (string= (greeter:greet "cl-nix-forge") "Hello, cl-nix-forge, from cl-nix-forge!"))
(format t "greeter/test: all assertions passed~%")
