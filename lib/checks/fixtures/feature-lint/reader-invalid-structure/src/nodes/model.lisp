(in-package "fixture/valid/nodes")

(defstruct node)

(defvar *malformed-structure* #S(reader-record :slot))

#| outer comment
   #| nested comment |#
|#
; line comment
