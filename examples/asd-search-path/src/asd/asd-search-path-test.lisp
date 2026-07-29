(defpackage :asd-search-path-test
  (:use :cl))

(in-package :asd-search-path-test)

(assert (= 42 (asd-search-path:answer)))
