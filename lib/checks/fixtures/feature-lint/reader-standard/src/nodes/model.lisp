(in-package "fixture/valid/nodes")

(defstruct node)

(defparameter *reader-standard-forms*
  (list
   '(quoted (form 1))
   '(dotted . pair)
   `(backquoted ,value ,@values)
   "escaped quote: \" and backslash: \\"
   123 -45 3.5 1/3 1e3
   escaped\name |Mixed Case|
   unknown.reader.pkg:external unknown.reader.pkg::internal
   #:uninterned :keyword
   #\A #\Space #\Newline #\: #\(
   #'cl:identity
   #(target id)
   #*1010
   #b101 #o17 #xaf #36rZ
   #c(1 2)
   #2a((1 2) (3 4))
   #1a(1 . (2))
   #2a((1) . ((2)))
   #s(reader-record :slot value)
   #p"/tmp/reader-path"
   #1=(cycle . #1#)
   #+reader-feature included
   #-other-feature excluded
   #.(progn (error "read-time evaluation ran") 'unreachable)
   #;discarded-form
   ))

#| outer comment
   #| nested comment |#
|#
; line comment
