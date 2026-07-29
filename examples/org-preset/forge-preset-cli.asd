;;;; The delivered binary's system, in the shape cl-weave and cl-prolog use:
;;;; the .asd owns `:build-operation`, `:build-pathname` and `:entry-point`,
;;;; so `(asdf:operate 'asdf:program-op "forge-preset-cli")` in a REPL and
;;;; `mkPackageFlake`'s `executable` argument deliver the same binary.
;;;;
;;;; `:build-pathname` is resolved against the system's own pathname, which
;;;; is this file's directory -- hence the `:module "src"` rather than a
;;;; system-wide `:pathname "src"`, which would move the program into src/
;;;; and make `mkExecutable`'s default `programPath` wrong on the
;;;; `program-op` delivery path (and only there, so a Darwin-only run would
;;;; not notice).
;;;;
;;;; `forge-preset-support` is the dependency the Nix side must carry
;;;; through: it lives outside the preset's source tree, so this system does
;;;; not compile at all unless `lispDependencies` reached the delivery.

(defsystem "forge-preset-cli"
  :description "Delivered CLI half of the org-preset example"
  :license "MIT"
  :version "0.5.3"
  :depends-on ("forge-preset" "forge-preset-support")
  :build-operation "program-op"
  :build-pathname "forge-preset-cli"
  :entry-point "forge-preset/cli::image-entry-point"
  :components ((:module "src"
                :serial t
                :components ((:file "forge-preset-cli")))))
