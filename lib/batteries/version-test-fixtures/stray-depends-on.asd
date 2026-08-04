;; A `:depends-on` keyword outside every `defsystem` form. `scan` attributes
;; an option only to a form open at its own paren depth, and this file is what
;; makes that guard observable: with it, the quoted template below is walked
;; through like any other code; without it the parenthesised value would be
;; swallowed whole as a dependency list.
;;
;; The template therefore contains a `defsystem`, and this lexer does not
;; understand `quote` -- so `template-inner` IS reported. That is the honest
;; behaviour of a lexer that never evaluates, and pinning it here is what
;; makes the difference between the two readings visible.
(defparameter *system-template*
  '(:depends-on ((defsystem "template-inner" :version "9.9.9"))))

(defsystem "stray-depends-on"
  :version "1.0.0"
  :depends-on ("cl-date-kit"))
