;;;; PACKAGE_STANDARD.md's canonical .asd shape: one file, two systems, the
;;;; test system named `<pkg>/test` and living under t/, and `:version`
;;;; declared once per system with both agreeing -- which is the unanimity
;;;; `fromAsdSystem` accepts and the drift it refuses.
;;;;
;;;; The operator is the bare `defsystem`, not `asdf:defsystem`: that is what
;;;; the org template writes (a .asd is read in ASDF-USER, where the symbol is
;;;; already accessible), and no other example exercises that spelling of the
;;;; form `fromAsdSystem` has to recognise.
;;;;
;;;; There is deliberately no `:in-order-to ((test-op (test-op ...)))` here.
;;;; `mkPackageFlake` drives run-tests.lisp through `mkScriptCheck`, so a
;;;; conforming package needs no `asdf:test-system` route at all, and this
;;;; suite passing is proof the preset never took one.

;;;; The exported system also declares how to deliver itself -- cl-weave's
;;;; shape, where one system is both the library a sibling depends on and the
;;;; binary the flake ships. That is what lets `mkExecutable { args =
;;;; ctx.lispDerivationArgs; }` be a LITERAL round trip in default.nix, with
;;;; nothing overridden.
;;;;
;;;; `:module "src"` rather than a system-wide `:pathname "src"`: the latter
;;;; would move `:build-pathname` into src/ as well, and
;;;; `mkExecutable`'s default `programPath` -- which is only consulted on the
;;;; `program-op` delivery path, i.e. the one no Darwin host runs -- would
;;;; then look in the wrong place.

(defsystem "forge-preset"
  :description "Package exercising cl-nix-forge's org flake preset end to end"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.5.3"
  :homepage "https://github.com/nerima-lisp/cl-nix-forge"
  :build-operation "program-op"
  :build-pathname "forge-preset"
  :entry-point "forge-preset::image-entry-point"
  :components ((:module "src"
                :serial t
                :components ((:file "forge-preset")))))

;;;; `forge-preset-harness` is a TEST-ONLY dependency, in the shape
;;;; cl-json-kit and cl-prolog both have: it is named by the `/test` system
;;;; and by nothing the library exports, so on the Nix side it reaches the
;;;; build only through `lispCheckDependencies`. Anything that has to run
;;;; this suite -- `checks.default`, `apps.test`, and `nix develop` -- must
;;;; carry it; anything that merely builds the library must not.
(defsystem "forge-preset/test"
  :description "Test system for forge-preset"
  :author "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.5.3"
  :depends-on ("forge-preset" "forge-preset-harness")
  :pathname "t"
  :serial t
  :components ((:file "forge-preset-test")))
