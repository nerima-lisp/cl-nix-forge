(in-package "fixture/valid/nodes")

(defstruct node)

(defun invalid-facade-reference ()
  fixture/valid/facade::unforwarded)
