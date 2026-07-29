(defpackage :core-b-test
  (:use :cl))
(in-package :core-b-test)

(assert (string= "core-b says: pong from core-a" (core-b:run)))
