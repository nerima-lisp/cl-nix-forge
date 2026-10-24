(defpackage "fixture/valid/nodes/helpers"
  (:use "CL")
  (:export "NODE" "MAKE-NODE"))

(defpackage "fixture/valid/facade"
  (:use "CL")
  (:import-from "fixture/valid/nodes/helpers" "MAKE-NODE")
  (:export "MAKE-NODE"))
