;; `(:require ...)` pulls in an implementation-provided module, not an ASDF
;; system, so it contributes no dependency name.
(defsystem "requires"
  :depends-on ("cl-date-kit" (:require "sb-cover")))
