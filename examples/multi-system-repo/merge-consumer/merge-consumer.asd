(asdf:defsystem "merge-consumer"
  :version "0.1.0"
  :description "Depends on both systems of one source tree at once, which is what makes core/dedup.nix merge them into a single derivation."
  :depends-on ("core-b")
  :components ((:file "merge-consumer")))
