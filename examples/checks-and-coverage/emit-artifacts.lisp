;;;; Packaged with `cl.lispScript`, so the command check runs a real installed
;;;; binary with an argv -- the shape cl-weave's artifact checks have, where
;;;; the thing under test is the delivered CLI and not a source file.

(require "asdf")
(asdf:load-system "forge-checks")

(destructuring-bind (json-path text-path parts-directory)
    (uiop:command-line-arguments)
  (uiop:symbol-call :forge-checks :emit-artifacts json-path text-path parts-directory))

(finish-output *standard-output*)
