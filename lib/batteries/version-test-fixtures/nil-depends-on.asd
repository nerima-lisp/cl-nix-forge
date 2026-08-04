;; NIL *is* the empty list in Common Lisp, so `:depends-on nil` says exactly
;; what `:depends-on ()` says; ECL's own cmp.asd spells it the first way. The
;; reader upcases, so `NIL` and `nil` are the same symbol and both are here.
(defsystem "nil-depends"
  :depends-on nil
  :components ((:file "nil-depends")))

(defsystem "uppercase-nil-depends"
  :depends-on NIL)

(defsystem "nil-dependent"
  :depends-on ("nil-depends"))
