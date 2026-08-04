;; An explicitly empty `:depends-on` is the same answer as no `:depends-on`.
;; The second system is not decoration: without it an implementation that
;; never looked at `:depends-on` at all would satisfy this fixture, because a
;; form with no dependency list already defaults to the empty one.
(defsystem "empty-depends"
  :depends-on ()
  :components ((:file "empty-depends")))

(defsystem "empty-dependent"
  :depends-on ("empty-depends"))
