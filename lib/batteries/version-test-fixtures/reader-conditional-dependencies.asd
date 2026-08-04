;; A reader conditional is EVALUATED against the caller's feature list, not
;; skipped over. The cl-cli shape is the reason: `#+sbcl "cl-host-kit"` must
;; contribute the name on SBCL and nothing at all on ECL, because each name
;; here becomes a derivation built for one implementation.
;;
;; Every element shape the evaluator has to get right is present once:
;; an inline feature name, its `#-` complement, a compound expression that
;; lexes as the bare atom `#+` followed by a list, both empty connectives --
;; `#-(and)` is the standard comment-out idiom because `(and)` is TRUE, and
;; `#+(or)` is its mirror because `(or)` is FALSE -- a stacked pair of
;; conditionals, and a guarded LIST element that has to be stepped over whole
;; when it is excluded.
(defsystem "conditional"
  :depends-on ("cl-date-kit"
               #+sbcl "cl-sbcl-only"
               #-sbcl :cl-not-sbcl
               #+(or sbcl ccl) "cl-sbcl-or-ccl"
               #+(and sbcl unix) "cl-sbcl-and-unix"
               #-(and) "cl-commented-out"
               #+(or) "cl-never"
               #+(not sbcl) "cl-not-sbcl-compound"
               #+sbcl #+unix "cl-stacked"
               #+sbcl (:require "sb-rotate-byte")
               #-sbcl (:version "cl-weave" "1.1.0")))
