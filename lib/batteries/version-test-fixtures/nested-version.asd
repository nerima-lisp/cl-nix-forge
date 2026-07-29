;; A component may carry its own `:version`; only the option at the defsystem
;; form's own depth is the system's version.
(defsystem "nested"
  :version "5.0.0"
  :components ((:file "a" :version "9.9.9")))
