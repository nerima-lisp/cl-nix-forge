(defpackage "fixture/valid/nodes"
  (:use "CL")
  (:export "NODE" "MAKE-NODE"))

(defpackage "fixture/valid/facade"
  (:use "CL")
  (:import-from "fixture/valid/nodes" "MAKE-NODE")
  (:export "MAKE-NODE"))

(defpackage "fixture/valid/spare"
  (:use "CL"))
