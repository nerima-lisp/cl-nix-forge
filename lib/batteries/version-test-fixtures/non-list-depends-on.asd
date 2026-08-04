;; `:depends-on` takes a list of dependency designators; a bare designator is
;; not the abbreviation it looks like.
(defsystem "atom-depends"
  :depends-on "cl-date-kit")
