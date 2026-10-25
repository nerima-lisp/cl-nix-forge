(asdf:defsystem "forge-tests/alpha"
  :defsystem-depends-on ("asdf")
  :weakly-depends-on ("optional-system")
  :class :system
  :build-pathname #p"build/forge-tests"
  :build-operation :program-op
  :homepage "https://example.invalid/forge"
  :bug-tracker "https://example.invalid/forge/issues"
  :mailto "maintainers@example.invalid"
  :long-name "Standard option fixture"
  :source-control (:git "https://example.invalid/forge.git")
  :version "0.7.3"
  :entry-point "forge-tests:main"
  :description "ASDF standard option fixture"
  :long-description "Exercises standard system and component options."
  :author ("Fixture Author")
  :maintainer "Fixture Maintainer"
  :pathname #p"."
  :default-component-class :cl-source-file
  :if-feature (:and :asdf :cl-nix-forge)
  :depends-on ("fixture-dependency")
  :in-order-to ((:test-op (:load-op "forge-tests/beta")))
  :perform (:test-op :after (operation component)
             (declare (ignore operation component)))
  :explain (:compile-op (operation component)
             (declare (ignore operation component)))
  :output-files (:compile-op (operation component)
                  (declare (ignore operation component))
                  nil)
  :operation-done-p (:compile-op (operation component)
                       (declare (ignore operation component))
                       nil)
  :components ((:module "t"
                :components ((:module "alpha"
                              :pathname #p"alpha/"
                              :serial t
                              :description "Component description"
                              :long-description "Component long description"
                              :author ("Component Author")
                              :maintainer "Component Maintainer"
                              :default-component-class :cl-source-file
                              :if-feature :cl-nix-forge
                              :weakly-depends-on ("optional-component")
                              :components ((:cl-source-file "test-alpha"
                                            :pathname test-alpha
                                            :depends-on ("support")
                                            :weakly-depends-on ("optional-file")
                                            :description "Test source"
                                            :long-description "Test source description"
                                            :author "Test Author"
                                            :maintainer ("Test Maintainer")
                                            :default-component-class :cl-source-file
                                            :if-feature (:or :asdf :cl-nix-forge)
                                            :perform (:test-op :after (operation component)
                                                    (declare (ignore operation component)))
                                            :explain (:compile-op (operation component)
                                                    (declare (ignore operation component)))
                                            :output-files (:compile-op (operation component)
                                                            (declare (ignore operation component))
                                                            nil)
                                            :operation-done-p (:compile-op (operation component)
                                                            (declare (ignore operation component))
                                                            nil))
                                          (:static-file "test-data"
                                           :depends-on ("test-alpha")
                                           :weakly-depends-on ("optional-data")))))))
) (asdf:defsystem "forge-tests/beta"
  :pathname t
  :components ((:module "beta"
                :components ((:file "test-beta")))))