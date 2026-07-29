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

(defsystem "forge-preset"
  :description "Package exercising cl-nix-forge's org flake preset end to end"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.5.3"
  :homepage "https://github.com/nerima-lisp/cl-nix-forge"
  :pathname "src"
  :serial t
  :components ((:file "forge-preset")))

(defsystem "forge-preset/test"
  :description "Test system for forge-preset"
  :author "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.5.3"
  :depends-on ("forge-preset")
  :pathname "t"
  :serial t
  :components ((:file "forge-preset-test")))
