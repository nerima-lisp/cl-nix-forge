;; The `:depends-on` element shapes that name a system: a string, a keyword or
;; uninterned-symbol designator, and a `(:version <name> <minimum>)` clause.
;; All four normalise the same way a system name does.
(defsystem "shapes"
  :depends-on ("cl-date-kit"
               :cl-cc-ast
               #:cl-prolog
               (:version "cl-weave" "1.1.0")))
