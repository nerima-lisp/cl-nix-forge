(defpackage "fixture/valid/nodes"
  (:use "CL")
  (:export "NODE"))

(defpackage "fixture/valid/facade"
  (:use "CL")
  (:import-from "fixture/valid/nodes" "NODE")
  (:export "NODE"))
