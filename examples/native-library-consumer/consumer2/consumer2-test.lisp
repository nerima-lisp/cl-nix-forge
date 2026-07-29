(defpackage :consumer2-test
  (:use :cl))
(in-package :consumer2-test)

(assert (= 42 (consumer1:native-answer)) () "consumer2 must load consumer1 and its transitive native library")
(format t "consumer2/test: native library loaded and called two hops away as expected~%")
