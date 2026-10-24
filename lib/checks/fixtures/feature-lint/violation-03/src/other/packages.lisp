(defpackage "fixture/valid/other"
  (:use "CL")
  (:export "OTHER" "MAKE-OTHER"))

(defpackage "fixture/valid/other-facade"
  (:use "CL")
  (:import-from "fixture/valid/other" "MAKE-OTHER")
  (:export "MAKE-OTHER"))
