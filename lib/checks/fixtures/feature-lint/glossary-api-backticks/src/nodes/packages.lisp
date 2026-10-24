(defpackage "fixture/valid/nodes"
  (:use "CL")
  (:export "NODE" "MAKE-NODE" "TWIG" "MAKE-TWIG" "SAPLING"))

(defpackage "fixture/valid/facade"
  (:use "CL")
  (:import-from "fixture/valid/nodes" "MAKE-NODE")
  (:export "MAKE-NODE"))
