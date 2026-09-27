;;;; This form comes FIRST, before any defsystem. ASDF binds *package* to
;;;; ASDF-USER only for a file it loads itself; read any other way -- a REPL
;;;; `load`, an editor evaluating the buffer, flake.nix parsing :version --
;;;; the file is read in whatever package happens to be current, and an
;;;; unqualified `defsystem` then fails to read at all. See
;;;; docs/src/reference/architecture.md for the system layout.
(in-package #:asdf-user)

(defsystem "aitools"
  :description "An AI-agent-oriented replacement for cat/grep/sed/find/jq/tar and friends: JSON-only output, crash-safe writes, and a built-in undo history."
  :author "Example Author <author@example.invalid>"
  :maintainer "Example Author <author@example.invalid>"
  :license "MIT"
  :version "0.1.0"
  :homepage "https://github.com/nerima-lisp/aitools"
  :bug-tracker "https://github.com/nerima-lisp/aitools/issues"
  :source-control (:git "https://github.com/nerima-lisp/aitools.git")
  ;; Every context's domain/application/infrastructure layer, and the pure
  ;; and effectful kits any of them may depend on (EXECUTION.md 9.3's layer
  ;; table). Never cl-cli -- that is "aitools/cli" alone, below.
  :depends-on ("cl-json-kit" "cl-regex-kit" "cl-codec-kit"
               "cl-host-kit" "cl-boundary-kit" "cl-concurrent-kit" "cl-process-kit" "cl-vcs-kit")
  :pathname "."
  :around-compile (lambda (next)
                    (let ((*package* (or (find-package "AITOOLS") *package*)))
                      (funcall next)))
  ;; The data module comes first: data/package.lisp, then every context's
  ;; :DATA file in module order. Each is loaded before the library
  ;; components so a context's domain layer can reference the AITOOLS.DATA
  ;; specials the data file interns.
  :components ((:module "data"
                :pathname "data/"
                :components ((:file "package")
                             (:file "domain/protocol/error-catalog-data")
                             (:file "domain/protocol/redaction-patterns-data")
                             (:file "domain/protocol/command-placement-data")
                             (:file "domain/protocol/correspondence-table-data")
                             (:file "domain/protocol/selector-options-data")
                             (:file "domain/workspace/builtin-excludes-data")
                             (:file "domain/text/cp932-data")
                             (:file "domain/text/euc-jp-data")
                             (:file "domain/text/mime-data")
                             (:file "domain/text/language-data")
                             (:file "domain/search/build-files-data")
                             (:file "presentation/search/command-schema-data")
                             (:file "presentation/inspect/command-schema-data")
                             (:file "presentation/inspect/format-command-schema-data")
                             (:file "presentation/inspect/archive-command-schema-data")
                             (:file "presentation/journal/command-schema-data")
                             (:file "application/edit/command-spec-data")
                             (:file "presentation/process/command-schema-data")
                             (:file "presentation/vcs/command-schema-data")
                             (:file "domain/env/tools-data")
                             (:file "domain/util/util-tables-data")
                             (:file "presentation/util/command-schema-data")
                             (:file "presentation/env/command-schema-data")
                             (:file "presentation/edit/command-schema-data")))
               ;; Library modules follow the data module. Contexts appear in
               ;; EXECUTION.md 13 章's module order, which is also the load
               ;; order of the components a context contributes: a later
               ;; context's domain layer may depend on an earlier core
               ;; context's domain/application (EXECUTION.md 9.3's layer
               ;; table), and among features a context loads after every
               ;; context whose application package it calls -- journal
               ;; before edit (edit registers its tx replayers with journal
               ;; at load time), inspect before edit and vcs (they reuse its
               ;; selector resolution), edit before util (`util decode --to`
               ;; uses edit's write pipeline). Each module is rooted at its
               ;; context's own src/ directory.
               (:module "core-kernel"
                :pathname "packages/core/kernel/src/"
                :components ((:file "domain/package")
                             (:file "domain/path")
                             (:file "domain/selector")
                             (:file "domain/guard")
                             (:file "domain/duration")
                             (:file "domain/size")
                             (:file "domain/digest")
                             (:file "domain/token-estimate")
                             (:file "domain/unified-diff")
                             (:file "domain/unified-diff-patch")
                             (:file "domain/json")))
               (:module "core-protocol"
                :pathname "packages/core/protocol/src/"
                :components ((:file "domain/package")
                             (:file "domain/error-catalog")
                             (:file "domain/redaction")
                             (:file "domain/shell-words")
                             (:file "domain/command-placement")
                             (:file "domain/envelope")
                             (:file "domain/schema-model")
                             (:file "application/package")
                             (:file "application/command-result")
                             (:file "application/command-registry")
                             (:file "application/redaction-flow")
                             (:file "application/schema-flow")
                             (:file "application/unknown-name")
                             (:file "infrastructure/package")
                             (:file "infrastructure/json-writer")))
               (:module "core-workspace"
                :pathname "packages/core/workspace/src/"
                :components ((:file "domain/package")
                             (:file "domain/path-syntax")
                             (:file "domain/entry")
                             (:file "domain/wildmatch")
                             (:file "domain/gitignore")
                             (:file "domain/builtin-excludes")
                             (:file "domain/glob")
                             (:file "domain/git-config")
                             (:file "domain/git-index")
                             (:file "domain/repository")
                             (:file "domain/boundary")
                             (:file "application/package")
                             (:file "application/host")
                             (:file "application/real-path")
                             (:file "application/root")
                             (:file "application/boundary")
                             (:file "application/ignore-context")
                             (:file "application/scan")
                             (:file "infrastructure/package")
                             (:file "infrastructure/host")
                             (:file "infrastructure/ordered-mapper")
                             (:file "infrastructure/boundaries")))
               (:module "core-text"
                :pathname "packages/core/text/src/"
                :components ((:file "domain/package")
                             (:file "domain/binary")
                             (:file "domain/layout")
                             (:file "domain/line-index")
                             (:file "domain/utf8")
                             (:file "domain/charset")
                             (:file "domain/encoding-guess")
                             (:file "domain/mime")
                             (:file "domain/normalize")
                             (:file "domain/lines")
                             (:file "domain/language")
                             (:file "domain/codec-conditions")
                             (:file "domain/archive-model")
                             (:file "domain/codec-crc32")
                             (:file "domain/codec-deflate")
                             (:file "domain/codec-gzip")
                             (:file "domain/codec-zip")
                             (:file "domain/codec-tar")
                             (:file "domain/archive-data")
                             (:file "domain/archive-format")
                             (:file "application/package")
                             (:file "application/source")
                             (:file "infrastructure/package")
                             (:file "infrastructure/host-source")
                             (:file "infrastructure/boundaries")))
               (:module "core-store"
                :pathname "packages/core/store/src/"
                :components ((:file "domain/package")
                             (:file "domain/entry-state")
                             (:file "domain/layout")
                             (:file "domain/change")
                             (:file "domain/plan")
                             (:file "domain/journal")
                             (:file "domain/intent")
                             (:file "domain/tx-model")
                             (:file "domain/changes-json")
                             (:file "application/package")
                             (:file "application/port")
                             (:file "application/lock")
                             (:file "application/files")
                             (:file "application/journal")
                             (:file "application/blobs")
                             (:file "application/view")
                             (:file "application/write-completion")
                             (:file "application/write-preparation")
                             (:file "application/write-protocol")
                             (:file "application/recovery")
                             (:file "application/undo")
                             (:file "application/tx")
                             (:file "application/tx-stage")
                             (:file "application/tx-commit")
                             (:file "infrastructure/package")
                             (:file "infrastructure/posix-syscall")
                             (:file "infrastructure/posix-file-io")
                             (:file "infrastructure/posix-io")))
               (:module "feature-search"
                :pathname "packages/feature/search/src/"
                :components ((:file "domain/package")
                             (:file "domain/bytes")
                             (:file "domain/json")
                             (:file "domain/matcher")
                             (:file "domain/results")
                             (:file "domain/find")
                             (:file "domain/code")
                             (:file "domain/overview")
                             (:file "application/package")
                             (:file "application/ports")
                             (:file "application/session")
                             (:file "application/search-flow")
                             (:file "application/find-flow")
                             (:file "application/code-flow")
                             (:file "application/overview-flow")
                             (:file "infrastructure/package")
                             (:file "infrastructure/ports")))
               (:module "feature-inspect"
                :pathname "packages/feature/inspect/src/"
                :components ((:file "domain/package")
                             (:file "domain/json-values")
                             (:file "domain/lines")
                             (:file "domain/pattern")
                             (:file "domain/similarity")
                             (:file "domain/lisp-scan")
                             (:file "domain/outline")
                             (:file "domain/selection")
                             (:file "domain/read-render")
                             (:file "domain/file-facts")
                             (:file "domain/diff")
                             (:file "domain/json-query")
                             (:file "domain/table")
                             (:file "domain/table-build")
                             (:file "domain/table-query")
                             (:file "domain/table-agg")
                             (:file "domain/archive")
                             (:file "domain/snapshot")
                             (:file "application/package")
                             (:file "application/ports")
                             (:file "application/context")
                             (:file "application/files")
                             (:file "application/selector")
                             (:file "application/read-flow")
                             (:file "application/info-flow")
                             (:file "application/check-flow")
                             (:file "application/diff-flow")
                             (:file "application/json-flows")
                             (:file "application/table-flows")
                             (:file "application/archive-flows")
                             (:file "application/snapshot-flows")
                             (:file "infrastructure/package")
                             (:file "infrastructure/ports")))
               (:module "feature-journal"
                :pathname "packages/feature/journal/src/"
                :components ((:file "domain/package")
                             (:file "domain/command-line")
                             (:file "domain/render")
                             (:file "application/package")
                             (:file "application/ports")
                             (:file "application/replayers")
                             (:file "application/common")
                             (:file "application/history-flow")
                             (:file "application/undo-flow")
                             (:file "application/tx-flows")
                             (:file "infrastructure/package")
                             (:file "infrastructure/ports")))
               (:module "feature-edit"
                :pathname "packages/feature/edit/src/"
                :components ((:file "domain/package")
                             (:file "domain/refusal")
                             (:file "domain/document")
                             (:file "domain/old-match")
                             (:file "domain/template")
                             (:file "domain/transform")
                             (:file "domain/json-doc")
                             (:file "domain/regex")
                             (:file "domain/table")
                             (:file "domain/split")
                             (:file "domain/archive-plan")
                             (:file "application/package")
                             (:file "application/ports")
                             (:file "application/command-spec")
                             (:file "application/write-plan")
                             (:file "application/write-guards")
                             (:file "application/pipeline")
                             (:file "application/input")
                             (:file "application/scan")
                             (:file "application/edit-flows")
                             (:file "application/replace-flows")
                             (:file "application/apply-flows")
                             (:file "application/line-flows")
                             (:file "application/content-flows")
                             (:file "application/file-flows")
                             (:file "application/mktemp")
                             (:file "application/json-flows")
                             (:file "application/archive-flows")
                             (:file "application/commands")
                             (:file "infrastructure/package")
                             (:file "infrastructure/ports")))
               (:module "feature-process"
                :pathname "packages/feature/process/src/"
                :components ((:file "domain/package")
                             (:file "domain/json-values")
                             (:file "domain/shell-words")
                             (:file "domain/line-pattern")
                             (:file "domain/terminal-text")
                             (:file "domain/output-report")
                             (:file "domain/process-outcome")
                             (:file "domain/bg-record")
                             (:file "domain/log-slice")
                             (:file "domain/wait-condition")
                             (:file "application/package")
                             (:file "application/ports")
                             (:file "application/common")
                             (:file "application/run-flow")
                             (:file "application/bg-flow")
                             (:file "application/wait-flow")
                             (:file "infrastructure/package")
                             (:file "infrastructure/host")
                             (:file "infrastructure/runner")
                             (:file "infrastructure/bg-launcher")
                             (:file "infrastructure/ports")))
               (:module "feature-vcs"
                :pathname "packages/feature/vcs/src/"
                :components ((:file "domain/package")
                             (:file "domain/render")
                             (:file "domain/paths")
                             (:file "domain/status")
                             (:file "domain/log")
                             (:file "domain/blame")
                             (:file "domain/diff")
                             (:file "domain/blob")
                             (:file "application/package")
                             (:file "application/port")
                             (:file "application/flows")
                             (:file "application/blame-show-flows")
                             (:file "infrastructure/package")
                             (:file "infrastructure/git-port")))
               (:module "feature-env"
                :pathname "packages/feature/env/src/"
                :components ((:file "domain/package")
                             (:file "domain/civil-time")
                             (:file "domain/time-input")
                             (:file "domain/posix-tz")
                             (:file "domain/tzif")
                             (:file "domain/host-parsers")
                             (:file "domain/host-values")
                             (:file "application/package")
                             (:file "application/ports")
                             (:file "application/time-flows")
                             (:file "application/sys-flows")
                             (:file "infrastructure/package")
                             (:file "infrastructure/production-ports")))
               (:module "feature-util"
                :pathname "packages/feature/util/src/"
                :components ((:file "domain/package")
                             (:file "domain/codec")
                             (:file "domain/text-stats")
                             (:file "domain/calc")
                             (:file "domain/uuid")
                             (:file "domain/random-string")
                             (:file "application/package")
                             (:file "application/ports")
                             (:file "application/input")
                             (:file "application/flows")
                             (:file "infrastructure/package")
                             (:file "infrastructure/os-random")
                             (:file "infrastructure/ports"))))
  :in-order-to ((test-op (test-op "aitools/test"))))

(defsystem "aitools/cli"
  :description "Command-line executable for aitools."
  :author "Example Author <author@example.invalid>"
  :maintainer "Example Author <author@example.invalid>"
  :license "MIT"
  :version "0.1.0"
  :homepage "https://github.com/nerima-lisp/aitools"
  :bug-tracker "https://github.com/nerima-lisp/aitools/issues"
  :source-control (:git "https://github.com/nerima-lisp/aitools.git")
  :depends-on ("aitools" "cl-cli")
  :pathname "."
  ;; Each feature context's presentation layer (its cl-cli command
  ;; definitions), in module order, ahead of the CLI's own src/ module.
  :components ((:module "feature-search"
                :pathname "packages/feature/search/src/"
                :components ((:file "presentation/package")
                             (:file "presentation/commands")))
               (:module "feature-inspect"
                :pathname "packages/feature/inspect/src/"
                :components ((:file "presentation/package")
                             (:file "presentation/registry")
                             (:file "presentation/file-commands")
                             (:file "presentation/json-commands")
                             (:file "presentation/table-commands")
                             (:file "presentation/archive-commands")
                             (:file "presentation/snapshot-commands")))
               (:module "feature-journal"
                :pathname "packages/feature/journal/src/"
                :components ((:file "presentation/package")
                             (:file "presentation/commands")))
               (:module "feature-edit"
                :pathname "packages/feature/edit/src/"
                :components ((:file "presentation/package")
                             (:file "presentation/commands")))
               (:module "feature-process"
                :pathname "packages/feature/process/src/"
                :components ((:file "presentation/package")
                             (:file "presentation/commands")))
               (:module "feature-vcs"
                :pathname "packages/feature/vcs/src/"
                :components ((:file "presentation/package")
                             (:file "presentation/commands")))
               (:module "feature-env"
                :pathname "packages/feature/env/src/"
                :components ((:file "presentation/package")
                             (:file "presentation/env-commands")))
               (:module "feature-util"
                :pathname "packages/feature/util/src/"
                :components ((:file "presentation/package")
                             (:file "presentation/util-commands")))
               (:module "src"
                :pathname "src/"
                :components ((:file "package")
                             (:file "registry")
                             (:file "workspace-context")
                             (:file "context-registration")
                             (:file "schema")
                             (:file "dispatch")
                             (:file "batch")
                             (:file "app")
                             (:file "entry-point"))))
  :build-operation "program-op"
  :build-pathname "aitools"
  :entry-point "aitools/cli::image-entry-point")

(defsystem "aitools/test"
  :description "Test system for aitools."
  :author "Example Author <author@example.invalid>"
  :maintainer "Example Author <author@example.invalid>"
  :license "MIT"
  :version "0.1.0"
  :homepage "https://github.com/nerima-lisp/aitools"
  :bug-tracker "https://github.com/nerima-lisp/aitools/issues"
  :source-control (:git "https://github.com/nerima-lisp/aitools.git")
  ;; cl-weave is the org's only test framework (EXECUTION.md 2 章). Do not
  ;; introduce FiveAM, parachute, rove, or prove.
  :depends-on ("aitools" "aitools/cli" "cl-weave")
  :pathname "."
  ;; t/package and t/support come first, then every context's :TESTS file in
  ;; module order, then the cross-context integration and e2e modules last.
  :components ((:module "t"
                :pathname "t/"
                :components ((:file "package")
                             (:module "support"
                              :pathname "support/"
                              :components ((:file "package")
                                           (:file "json-assertions")))
                             (:file "unit/kernel/package")
                             (:file "unit/kernel/path-test")
                             (:file "unit/kernel/selector-test")
                             (:file "unit/kernel/guard-test")
                             (:file "unit/kernel/duration-test")
                             (:file "unit/kernel/size-test")
                             (:file "unit/kernel/digest-test")
                             (:file "unit/kernel/token-estimate-test")
                             (:file "unit/kernel/unified-diff-test")
                             (:file "unit/kernel/json-test")
                             (:file "unit/protocol/package")
                             (:file "unit/protocol/envelope-test")
                             (:file "unit/protocol/error-catalog-test")
                             (:file "unit/protocol/redaction-test")
                             (:file "unit/protocol/command-placement-test")
                             (:file "unit/protocol/redaction-flow-test")
                             (:file "unit/protocol/schema-flow-test")
                             (:file "unit/protocol/command-result-test")
                             (:file "unit/protocol/json-writer-test")
                             (:file "unit/workspace/package")
                             (:file "unit/workspace/fake-host")
                             (:file "unit/workspace/wildmatch-test")
                             (:file "unit/workspace/gitignore-test")
                             (:file "unit/workspace/root-boundary-test")
                             (:file "unit/workspace/git-data-test")
                             (:file "unit/workspace/scan-test")
                             (:file "integration/workspace-test-support")
                             (:file "integration/workspace-gitignore-parity-test")
                             (:file "integration/workspace-host-test")
                             (:file "unit/text/package")
                             (:file "unit/text/layout-test")
                             (:file "unit/text/charset-test")
                             (:file "unit/text/guess-test")
                             (:file "unit/text/codec-test")
                             (:file "unit/text/archive-test")
                             (:file "unit/text/source-test")
                             (:file "integration/text-archive-fixtures")
                             (:file "integration/text-archive-interop-test")
                             (:file "integration/text-host-source-test")
                             (:file "support/store-fault-injection")
                             (:file "unit/store/package")
                             (:file "unit/store/domain-test")
                             (:file "integration/store-write-protocol-test")
                             (:file "integration/store-recovery-test")
                             (:file "integration/store-lock-test")
                             (:file "integration/store-tx-test")
                             (:file "integration/store-mtime-test")
                             (:file "integration/store-security-test")
                             (:file "unit/search/package")
                             (:file "unit/search/fakes")
                             (:file "unit/search/matcher-test")
                             (:file "unit/search/search-flow-test")
                             (:file "unit/search/find-flow-test")
                             (:file "unit/search/code-flow-test")
                             (:file "unit/search/commands-test")
                             (:file "perf/search-allocation-test")
                             (:file "integration/search-host-test")
                             (:file "unit/inspect/package")
                             (:file "unit/inspect/support")
                             (:file "unit/inspect/read-test")
                             (:file "unit/inspect/json-query-test")
                             (:file "unit/inspect/table-test")
                             (:file "unit/inspect/archive-test")
                             (:file "unit/inspect/snapshot-test")
                             (:file "integration/inspect-snapshot-test")
                             (:file "unit/inspect/info-check-diff-test")
                             (:file "unit/inspect/selection-test")
                             (:file "integration/inspect-cli-test")
                             (:file "unit/journal/package")
                             (:file "unit/journal/domain-test")
                             (:file "unit/journal/changes-json-test")
                             (:file "integration/journal-flows-test")
                             (:file "integration/journal-tx-test")
                             (:file "integration/journal-cli-test")
                             (:file "unit/edit/package")
                             (:file "unit/edit/domain-test")
                             (:file "unit/edit/format-test")
                             (:file "integration/edit-text-test")
                             (:file "integration/edit-text-commands-test")
                             (:file "integration/edit-files-test")
                             (:file "integration/edit-tx-and-limits-test")
                             (:file "integration/edit-cli-test")
                             (:file "integration/edit-security-test")
                             (:file "unit/process/package")
                             (:file "unit/process/fakes")
                             (:file "unit/process/domain-test")
                             (:file "unit/process/flows-test")
                             (:file "integration/process-test")
                             (:file "integration/process-bg-test")
                             (:file "integration/process-ports-test")
                             (:file "unit/vcs/package")
                             (:file "unit/vcs/domain-test")
                             (:file "unit/vcs/flows-test")
                             (:file "integration/vcs-git-test")
                             (:file "unit/env/package")
                             (:file "unit/env/tzif-fixtures")
                             (:file "unit/env/support")
                             (:file "unit/env/civil-time-test")
                             (:file "unit/env/time-input-test")
                             (:file "unit/env/tzif-test")
                             (:file "unit/env/host-parsers-test")
                             (:file "unit/env/time-flows-test")
                             (:file "unit/env/sys-flows-test")
                             (:file "unit/env/env-commands-test")
                             (:file "integration/env-host-test")
                             (:file "unit/util/package")
                             (:file "unit/util/codec-test")
                             (:file "unit/util/calc-test")
                             (:file "unit/util/uuid-random-test")
                             (:file "unit/util/flows-test")
                             (:file "integration/util-cli-test")
                             (:module "integration"
                              :pathname "integration/"
                              :components ((:file "dispatch-test") (:file "batch-test")
                                           (:file "cli-schema-drift-test") (:file "structure-test")))
                             ;; meta-test last: cl-weave runs specs in definition
                             ;; order, and it checks that every correspondence-table
                             ;; row registered a case above it.
                             (:module "e2e"
                              :pathname "e2e/"
                              :components ((:file "package") (:file "harness")
                                           (:file "correspondence-rows")
                                           (:file "read-search-cases") (:file "edit-cases")
                                           (:file "format-cases") (:file "process-env-cases")
                                           (:file "meta-test"))))))
  :perform (test-op (op system)
             (declare (ignore op system))
             (unless (uiop:symbol-call :aitools/test :run-tests)
               (error "aitools self test suite failed."))))
