(in-package "fixture/valid/nodes")

(defstruct node)

(defparameter *numeric-reader-forms*
  (list
   #6(one two three four five six)
   #4*1010
   #b101/11
   #16r+D5))
