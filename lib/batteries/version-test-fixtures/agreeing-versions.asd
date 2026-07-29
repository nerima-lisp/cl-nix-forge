;; The org's mandated layout: one .asd at the repo root defining both `<pkg>`
;; and `<pkg>/test`, each repeating the same `:version`. Unanimous agreement is
;; the normal shape, not an ambiguity.
(in-package #:asdf-user)

(defsystem "agreeing"
  :version "1.1.0"
  :components ((:file "agreeing")))

(defsystem "agreeing/test"
  :version "1.1.0"
  :depends-on ("agreeing"))
