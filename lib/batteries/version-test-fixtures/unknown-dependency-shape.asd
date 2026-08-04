;; A list whose head is not a recognised clause keyword is not something whose
;; dependency name can be guessed at.
(defsystem "unknown-shape"
  :depends-on (("cl-date-kit")))
