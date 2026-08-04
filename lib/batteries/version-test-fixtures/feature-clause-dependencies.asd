;; ASDF's own spelling of the reader conditional. `dependency-def` is
;; `simple-component-name | (:feature <feature-expression> <dependency-def>)
;; | (:version <name> <spec>) | (:require <module>)`, and the third element is
;; itself a dependency-def -- hence the nested `(:version ...)` and
;; `(:require ...)` below. `cl+ssl`, `usocket`, `cffi` and `bordeaux-threads`
;; all ship this shape, so it has to answer the same as `#+`/`#-` does.
(defsystem "feature-clauses"
  :depends-on ("cl-date-kit"
               (:feature :sbcl "cl-sbcl-only")
               (:feature (:not :sbcl) "cl-not-sbcl")
               (:feature (:or :sbcl :ccl) (:version "cl-weave" "1.1.0"))
               (:feature :ecl (:require "serve-event"))))
