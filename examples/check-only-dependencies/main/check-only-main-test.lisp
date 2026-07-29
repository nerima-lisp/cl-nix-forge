(defpackage :check-only-main-test
  (:use :cl))

(in-package :check-only-main-test)

(assert (string= "main build does not load test support" (check-only-main:message)))
(assert (string= "available only while testing" (check-only-support:expected-message)))
