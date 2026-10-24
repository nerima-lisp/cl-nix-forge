(in-package "fixture/valid/nodes")

(defstruct node)

(defparameter *escaped-package-marker-tokens*
  '( |pkg:name|:symbol
     pkg:|symbol:name|
     fixture/valid/unknown\:part:external-symbol))
