;;;; A system NOTHING builds into the delivered image: it is compiled for the
;;;; first time by the running binary, out of the sources `installSource` put
;;;; beside that binary. It depends on both halves of what has to be
;;;; installed for that to work -- `forge-preset`, which travels in the
;;;; delivered system's own source tree, and `forge-preset-support`, which is
;;;; a separate store path reachable only through the installed dependency
;;;; closure.

(defsystem "forge-preset-runtime"
  :description "Loaded at run time from the tree installed beside the image"
  :license "MIT"
  :version "0.5.3"
  :depends-on ("forge-preset" "forge-preset-support")
  :components ((:module "src"
                :serial t
                :components ((:file "forge-preset-runtime")))))
