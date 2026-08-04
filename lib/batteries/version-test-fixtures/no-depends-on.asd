;; `:depends-on` is not a required defsystem option. Unlike a missing
;; `:version`, which drops the system from `asdSystemVersions` entirely, a
;; system with no dependencies is still reported -- with an empty list.
(defsystem "standalone"
  :components ((:file "standalone")))

(defsystem "dependent"
  :version "1.0.0"
  :depends-on ("standalone"))
