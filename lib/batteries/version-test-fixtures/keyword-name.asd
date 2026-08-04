;; System designator given as a keyword. The `:depends-on` entry is spelled
;; as a keyword too, so the assertion pins BOTH sides of the normalisation --
;; and so that an implementation which never read `:depends-on` would fail it
;; rather than pass on the empty-list default.
(defsystem :foo
  :version "2.0"
  :depends-on (:cl-date-kit))
