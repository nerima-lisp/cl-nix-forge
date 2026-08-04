;; Four `:depends-on` options this lexer refuses, each on a system that also
;; carries the same `:version`. The point of the file is the SEPARATION:
;; `fromAsdSystem` and `asdSystemVersions` share the parse with
;; `asdSystemDependencies`, so a dependency shape nobody can read must poison
;; only the dependency answer. Nineteen repositories ask this file only for
;; "6.0.0" and would break if it did anything else.
(defsystem "malformed-non-list"
  :version "6.0.0"
  :depends-on "cl-date-kit")

(defsystem "malformed-unknown-shape"
  :version "6.0.0"
  :depends-on (("cl-date-kit")))

(defsystem "malformed-bare-symbol"
  :version "6.0.0"
  :depends-on (cl-date-kit))

(defsystem "malformed-dangling-conditional"
  :version "6.0.0"
  :depends-on ("cl-date-kit" #+sbcl))
