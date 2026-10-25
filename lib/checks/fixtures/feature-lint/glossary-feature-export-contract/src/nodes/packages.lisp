(defpackage "fixture/valid/nodes"
  (:use "CL")
  (:export "NODE" "MAKE-NODE" "FEATURE-ONLY"))

(defpackage "fixture/valid/facade"
  (:use "CL")
  (:import-from "fixture/valid/nodes" "MAKE-NODE" "NODE")
  (:export "MAKE-NODE" "NODE"))
