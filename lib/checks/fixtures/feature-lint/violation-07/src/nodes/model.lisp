(in-package "fixture/valid/nodes")

(defstruct node)

(defun make-node ()
  (make-instance 'node))
