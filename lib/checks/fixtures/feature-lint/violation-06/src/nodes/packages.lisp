(defpackage "fixture/valid/nodes"
  (:use "CL" "fixture/valid/nodes/infra")
  (:export "NODE" "MAKE-NODE"))

(defpackage "fixture/valid/facade"
  (:use "CL")
  (:import-from "fixture/valid/nodes" "MAKE-NODE")
  (:export "MAKE-NODE"))

(defpackage "fixture/valid/nodes/infra"
  (:use "CL")
  (:export "HELP"))
