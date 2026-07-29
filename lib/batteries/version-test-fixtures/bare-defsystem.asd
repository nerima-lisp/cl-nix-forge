;; The shape ASDF's own template emits: `defsystem` unqualified, resolved by
;; the surrounding `(in-package #:asdf-user)`.
(in-package #:asdf-user)

(defsystem "bare"
  :version "1.0")
