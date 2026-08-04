;; A `:components` entry may carry its own `:depends-on` naming a sibling
;; component; only the option at the defsystem form's own depth is the system's
;; dependency list.
(defsystem "nested-depends"
  :depends-on ("cl-date-kit")
  :components ((:file "a")
               (:file "b" :depends-on ("a"))))

(defsystem "nested-depends/component-only"
  :components ((:file "c")
               (:file "d" :depends-on ("c"))))
