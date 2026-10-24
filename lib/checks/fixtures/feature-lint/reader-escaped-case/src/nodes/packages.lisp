(defpackage #:|Fixture/Valid/Nodes|
  (:use "CL")
  (:export "NODE" "MAKE-NODE"))

(defpackage "fixture/valid/facade"
  (:use "CL")
  (:import-from "fixture/valid/nodes" "MAKE-NODE")
  (:export "MAKE-NODE"))
