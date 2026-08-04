;; An unprefixed symbol in a dependency position. `defsystem cl-date-kit`
;; would be a legal system NAME, which is exactly why this has to be rejected
;; explicitly rather than fall through to the name reader: an option keyword
;; or a stray token misplaced into the list would otherwise arrive in the
;; registry as a system nobody can resolve.
(defsystem "bare-symbol"
  :depends-on (cl-date-kit))
