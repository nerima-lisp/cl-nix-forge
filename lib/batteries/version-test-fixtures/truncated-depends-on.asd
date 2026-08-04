;; A file cut off inside its `:depends-on` list. Paren balance is the Lisp
;; reader's job, so what was read is reported rather than raised as an error --
;; and the walk has to stop at end of input instead of indexing past it.
(defsystem "truncated"
  :version "8.0.0"
  :depends-on ("cl-date-kit"
