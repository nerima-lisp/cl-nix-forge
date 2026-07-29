;; `:version` is not a required defsystem option; a system without one is
;; omitted from `asdSystemVersions` rather than recorded as null.
(defsystem "versioned"
  :version "7.0.0")

(defsystem "unversioned"
  :depends-on ("versioned"))
