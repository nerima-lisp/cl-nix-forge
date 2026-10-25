(in-package #:cl-user)

(defparameter *contract-root*
  (truename
   (merge-pathnames #P"../../"
                    (make-pathname :name nil
                                   :type nil
                                   :defaults *load-truename*))))
(defparameter *contract-assertions* 0)
(defparameter *contract-failures* 0)
(defparameter *contract-run-number* 0)

(defun contract-path (relative)
  (namestring (merge-pathnames relative *contract-root*)))

(defun fixture-root (suite fixture)
  (namestring
   (truename
    (merge-pathnames
     (format nil "lib/checks/fixtures/~A/~A/" suite fixture)
     *contract-root*))))

(defun temporary-log-path (run-number stream-name)
  (let* ((directory (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
         (directory (if (char= #\/ (char directory (1- (length directory))))
                        directory
                        (concatenate 'string directory "/")))
         (name (format nil "cl-nix-forge-contract-~D-~D.~A"
                       (get-universal-time)
                       run-number
                       stream-name)))
    (namestring (merge-pathnames name (pathname directory)))))

(defun read-log-file (path)
  (with-open-file (input path :direction :input)
    (with-output-to-string (output)
      (loop for line = (read-line input nil nil)
            while line
            do (write-line line output)))))

(progn
  (defparameter *checker-timeout-seconds* 10)
  (defun wait-for-process (process timeout-seconds)
    (let ((started (get-internal-real-time))
          (timeout-ticks (* timeout-seconds internal-time-units-per-second)))
      (loop
        for status = (sb-ext:process-status process)
        when (member status (list :exited :signaled))
          do (progn
               (sb-ext:process-wait process)
               (return-from wait-for-process nil))
        when (>= (- (get-internal-real-time) started) timeout-ticks)
          do (progn
               (sb-ext:process-kill process 9)
               (sb-ext:process-wait process)
               (return-from wait-for-process t))
        do (sleep 0.05))))
  (defun run-checker (script arguments)
    (let* ((run-number (incf *contract-run-number*))
           (stdout-path (temporary-log-path run-number "stdout"))
           (stderr-path (temporary-log-path run-number "stderr")))
      (unwind-protect
           (let* ((process
                    (sb-ext:run-program
                     "sbcl"
                     (append (list "--script" (contract-path script)) arguments)
                     :search t
                     :wait nil
                     :output stdout-path
                     :error stderr-path))
                  (timed-out-p (wait-for-process process *checker-timeout-seconds*)))
             (values (unless timed-out-p (sb-ext:process-exit-code process))
                     (read-log-file stdout-path)
                     (read-log-file stderr-path)
                     timed-out-p))
        (when (probe-file stdout-path)
          (delete-file stdout-path))
        (when (probe-file stderr-path)
          (delete-file stderr-path))))))

(defun feature-lint-arguments (fixture &optional (glossary-path "docs/glossary.md"))
  (append
   (list "--source-root" (fixture-root "feature-lint" fixture)
         "--feature-definitions" "nix/feature-dependencies.sexp"
         "--glossary" glossary-path
         "--glossary-heading-prefix" "## "
         "--export-surface" "t/export-surface.txt"
         "--mode" "strict"
         "--legacy-internal-refs" "t/legacy-internal-refs.sexp"
         "--package-prefix" "fixture/valid/"
         "--infra-suffix" "/infra")
   (loop for name in '("phases" "misc" "utils" "helpers")
         append (list "--forbidden-name" name))
   (loop for prefix in '("FR-" "W")
         append (list "--numbered-prefix" prefix))))

(defun orphan-test-arguments (fixture &optional systems)
  (append
   (list "--source-root" (fixture-root "orphan-tests" fixture)
         "--test-root" "t")
   (loop for system in (or systems '("forge-tests/alpha" "forge-tests/beta"))
         append (list "--test-system" system))))


(defun run-case (name script arguments expected-marker
                 &optional (expected-exit-code (if expected-marker 1 0)))
  (incf *contract-assertions*)
  (let ((exit-code nil)
        (combined-output "")
        (passed nil)
        (failure-detail nil))
    (handler-case
        (multiple-value-bind (status stdout stderr timed-out-p)
            (run-checker script arguments)
          (setf exit-code status
                combined-output (concatenate 'string stdout stderr)
                failure-detail
                (when timed-out-p
                  (format nil "checker timed out after ~D seconds"
                          *checker-timeout-seconds*))
                passed
                (and (not timed-out-p)
                     (if expected-marker
                         (and status
                              (eql status expected-exit-code)
                              (search expected-marker combined-output))
                         (eql status expected-exit-code)))))
      (error (condition)
        (setf failure-detail (princ-to-string condition))))
    (format t "~&~A ~A~%" (if passed "PASS" "FAIL") name)
    (unless passed
      (incf *contract-failures*)
      (format *error-output* "  expected ~A; got exit ~A~%"
              (if expected-marker
                  (format nil "exit ~D with ~A" expected-exit-code expected-marker)
                  (format nil "exit ~D" expected-exit-code))
              exit-code)
      (when failure-detail
        (format *error-output* "  runner error: ~A~%" failure-detail))
      (when (plusp (length combined-output))
        (format *error-output* "  checker output:~%~A" combined-output)))))

(defun run-feature-case (label fixture marker &optional (glossary-path "docs/glossary.md"))
  (run-case label
            "lib/checks/feature-lint.lisp"
            (feature-lint-arguments fixture glossary-path)
            marker))

(defun run-orphan-case (label fixture marker &optional systems)
  (run-case label
            "lib/checks/orphan-tests.lisp"
            (orphan-test-arguments fixture systems)
            marker))


(run-feature-case "feature-lint-valid" "valid" nil)
(run-feature-case "feature-lint-01-feature-set" "violation-01"
                  "[feature-lint:feature-set]")
(run-feature-case "feature-lint-02-banned-name" "violation-02"
                  "[feature-lint:banned-name]")
(run-feature-case "feature-lint-03-dependency" "violation-03"
                  "[feature-lint:dependency]")
(run-feature-case "feature-lint-04-facade" "violation-04"
                  "[feature-lint:facade]")
(run-feature-case "feature-lint-05-internal-reference" "violation-05"
                  "[feature-lint:internal-reference]")
(run-feature-case "feature-lint-06-domain-infra" "violation-06"
                  "[feature-lint:domain-infra]")
(progn
  (run-feature-case "feature-lint-07-glossary-export" "violation-07"
                    "[feature-lint:glossary-export]")
  (run-feature-case "feature-lint-package-designators-facade-outside"
                    "package-designators"
                    nil)
  (run-feature-case "feature-lint-glossary-multi-package"
                    "glossary-multi-package"
                    nil)
  (run-feature-case "feature-lint-glossary-package-mismatch"
                    "glossary-multi-package"
                    "[feature-lint:feature-set]"
                    "docs/glossary-single-package.md")
  (progn
    (run-feature-case "feature-lint-glossary-api-backticks"
                      "glossary-api-backticks"
                      nil)
    (run-feature-case "feature-lint-glossary-unmatched-backticks"
                      "glossary-api-backticks"
                      "[feature-lint:glossary-export]"
                      "docs/glossary-unmatched.md"))
  (progn
    (run-feature-case "feature-lint-08-reader-label" "violation-08" nil)
    (run-feature-case "feature-lint-reader-standard-syntax" "reader-standard" nil)
    (progn
      (run-feature-case "feature-lint-reader-unknown-package" "reader-unknown-package" nil)
      (run-case "feature-lint-reader-empty-uninterned-symbol"
                "lib/checks/feature-lint.lisp"
                (feature-lint-arguments "reader-invalid-empty-uninterned")
                "uninterned symbol requires a name"
                2)
      (run-case "feature-lint-reader-empty-character"
                "lib/checks/feature-lint.lisp"
                (feature-lint-arguments "reader-invalid-empty-character")
                "character literal requires a character or name after #\\"
                2)
      (run-case "feature-lint-reader-character-package-token"
                "lib/checks/feature-lint.lisp"
                (feature-lint-arguments "reader-invalid-character-package-token")
                "character name must not contain a package marker"
                2)
      (run-case "feature-lint-reader-package-single-colon"
                "lib/checks/feature-lint.lisp"
                (feature-lint-arguments "reader-invalid-package-single-colon")
                "malformed package marker pattern"
                2)
      (run-case "feature-lint-reader-package-double-colon"
                "lib/checks/feature-lint.lisp"
                (feature-lint-arguments "reader-invalid-package-double-colon")
                "malformed package marker pattern"
                2)
      (progn
        (run-case "feature-lint-reader-self-referential-label"
                  "lib/checks/feature-lint.lisp"
                  (feature-lint-arguments "reader-invalid-reader-label-self-reference")
                  "reader label reference cannot be the labeled object"
                  2)
        (run-case "feature-lint-reader-self-reference-after-discard"
                  "lib/checks/feature-lint.lisp"
                  (feature-lint-arguments "reader-invalid-reader-label-discard-self-reference")
                  "reader label reference cannot be the labeled object"
                  2))
      (run-case "feature-lint-reader-conditional-malformed-package-token"
                "lib/checks/feature-lint.lisp"
                (feature-lint-arguments "reader-invalid-conditional-package")
                "malformed package marker pattern"
                2))
    (run-case "feature-lint-reader-unreadable-object"
              "lib/checks/feature-lint.lisp"
              (feature-lint-arguments "reader-invalid-unreadable")
              "unreadable reader syntax #<"
              2)
    (run-case "feature-lint-reader-unsupported-dispatch"
              "lib/checks/feature-lint.lisp"
              (feature-lint-arguments "reader-invalid-dispatch")
              "unsupported reader dispatch syntax #Q"
              2)
    (run-case "feature-lint-reader-unterminated-vector"
              "lib/checks/feature-lint.lisp"
              (feature-lint-arguments "reader-invalid-vector")
              "unterminated vector literal"
              2)
    (run-case "feature-lint-reader-unterminated-string"
              "lib/checks/feature-lint.lisp"
              (feature-lint-arguments "reader-invalid-string")
              "unterminated string"
              2)
    (run-case "feature-lint-reader-invalid-bit-vector"
              "lib/checks/feature-lint.lisp"
              (feature-lint-arguments "reader-invalid-bit-vector")
              "invalid bit-vector literal"
              2)
    (progn
      (run-case "feature-lint-reader-unterminated-block-comment"
                "lib/checks/feature-lint.lisp"
                (feature-lint-arguments "reader-invalid-comment")
                "unterminated block comment"
                2)
      (run-feature-case "feature-lint-reader-numeric-syntax" "reader-numeric" nil)
      (run-case "feature-lint-reader-vector-count-exceeded"
                "lib/checks/feature-lint.lisp"
                (feature-lint-arguments "reader-invalid-vector-count")
                "vector literal exceeds declared length"
                2)
      (run-case "feature-lint-reader-bit-count-exceeded"
                "lib/checks/feature-lint.lisp"
                (feature-lint-arguments "reader-invalid-bit-count")
                "bit-vector literal length exceeds declared length"
                2)
      (run-case "feature-lint-reader-zero-ratio-denominator"
                "lib/checks/feature-lint.lisp"
                (feature-lint-arguments "reader-invalid-ratio")
                "radix denominator is zero in #b101/0"
                2)
      (run-case "feature-lint-reader-array-missing-rank"
                "lib/checks/feature-lint.lisp"
                (feature-lint-arguments "reader-invalid-array-rank")
                "array reader dispatch requires a numeric rank"
                2)
      (run-case "feature-lint-reader-binary-numeric-argument"
                "lib/checks/feature-lint.lisp"
                (feature-lint-arguments "reader-invalid-binary-arg")
                "numeric argument is not permitted for reader dispatch #2B"
                2)
      (run-case "feature-lint-reader-pathname-numeric-argument"
                "lib/checks/feature-lint.lisp"
                (feature-lint-arguments "reader-invalid-pathname-arg")
                "numeric argument is not permitted for reader dispatch #2P"
                2)
      (progn
        (run-feature-case
                          "feature-lint-reader-escaped-case"
                          "reader-escaped-case"
                          "unknown feature package fixture/valid/unknown:part referenced in src/nodes/model.lisp")
        (run-case "feature-lint-reader-complex-non-real-components"
                  "lib/checks/feature-lint.lisp"
                  (feature-lint-arguments "reader-invalid-complex")
                  "complex reader dispatch requires real components"
                  2)
        (run-case "feature-lint-reader-structure-malformed-pairs"
                  "lib/checks/feature-lint.lisp"
                  (feature-lint-arguments "reader-invalid-structure")
                  "structure reader dispatch requires a name and slot/value pairs"
                  2)
        (run-case "feature-lint-reader-array-inconsistent-dimensions"
                  "lib/checks/feature-lint.lisp"
                  (feature-lint-arguments "reader-invalid-array-shape")
                  "array reader dispatch contents have inconsistent dimensions"
                  2)
        (progn
          (run-case "feature-lint-reader-array-non-sequence-data"
                    "lib/checks/feature-lint.lisp"
                    (feature-lint-arguments "reader-invalid-array-data")
                    "array reader dispatch requires sequence data"
                    2)
          (run-case "feature-lint-reader-array-dotted-list-data"
                    "lib/checks/feature-lint.lisp"
                    (feature-lint-arguments "reader-invalid-array-dotted-list")
                    "array reader dispatch requires sequence data"
                    2)))))
  (run-case "feature-lint-unknown-leading-option"
            "lib/checks/feature-lint.lisp"
            (append (quote ("--unrecognized-flag" "ignored"))
                    (feature-lint-arguments "valid"))
            "[feature-lint:error] unknown option"
            2))
(run-orphan-case "orphan-tests-multi-system-nested" "multi-system-nested" nil)
(run-orphan-case "orphan-tests-unregistered" "unregistered-file"
                 "[orphan-tests:unregistered]")
(run-orphan-case "orphan-tests-missing-component" "missing-component"
                 "[orphan-tests:missing-component]")
(progn
  (run-orphan-case "orphan-tests-empty" "empty" "[orphan-tests:empty]")
  (run-case "orphan-tests-unknown-leading-option"
            "lib/checks/orphan-tests.lisp"
            (append (quote ("--unrecognized-flag" "ignored"))
                    (orphan-test-arguments "multi-system-nested"))
            "[orphan-tests:invalid] unknown option")
  (run-feature-case "feature-lint-declared-source-facade" "declared-source-facade" nil)
  (run-orphan-case "orphan-tests-standard-system-options" "standard-system-options/valid" nil)
  (run-orphan-case "orphan-tests-string-pathname-default-type"
                   "standard-system-options/string-pathname-default-type" nil)
  (run-orphan-case "orphan-tests-pathname-object-type-override"
                   "standard-system-options/pathname-object-type-override"
                   "[orphan-tests:unregistered]")
  (run-orphan-case "orphan-tests-pathname-object-without-type"
                   "standard-system-options/pathname-object-without-type"
                   "[orphan-tests:unregistered]")
  (run-orphan-case "orphan-tests-custom-component-type"
                   "standard-system-options/custom-component" "[orphan-tests:unverified]")
  (run-orphan-case "orphan-tests-compatibility-options"
                   "standard-system-options/compatibility-options" nil)
  (run-orphan-case "orphan-tests-component-class-not-system"
                   "standard-system-options/component-class-not-system"
                   "[orphan-tests:invalid]")
  (run-orphan-case "orphan-tests-unknown-system-option" "unknown-system-option"
                   "[orphan-tests:invalid]")
  (run-orphan-case "orphan-tests-unknown-component-option" "unknown-component-option"
                   "[orphan-tests:invalid]")
  (run-orphan-case "orphan-tests-invalid-system-name"
                   "standard-system-options/invalid-system-name"
                   "[orphan-tests:invalid]")
  (run-orphan-case "orphan-tests-invalid-component-name"
                   "standard-system-options/invalid-component-name"
                   "[orphan-tests:invalid]")
  (run-orphan-case "orphan-tests-wrong-complex-master"
                   "standard-system-options/wrong-complex-master"
                   "[orphan-tests:invalid]")
  (progn
  (run-case "orphan-tests-unportable-system-name"
            "lib/checks/orphan-tests.lisp"
            (list "--source-root"
                  (fixture-root "orphan-tests"
                                "standard-system-options/unportable-system-name")
                  "--test-root" "t" "--test-system" "forge-tests*")
            "[orphan-tests:unverified]")
  (run-orphan-case "orphan-tests-package-inferred-nested-name"
                   "package-inferred-system"
                   "[orphan-tests:unverified]"
                   '("forge-tests/alpha/test-alpha"
                     "forge-tests/beta/test-beta")))

  (run-case "orphan-tests-unportable-system-name"
            "lib/checks/orphan-tests.lisp"
            (list "--source-root"
                  (fixture-root "orphan-tests"
                                "standard-system-options/unportable-system-name")
                  "--test-root" "t" "--test-system" "forge-tests*")
            "[orphan-tests:unverified]"))

(progn
  (let ((process
          (sb-ext:run-program
           "sbcl"
           (list "--noinform" "--non-interactive" "--eval" "(loop do (sleep 1))")
           :search t
           :wait nil
           :output nil
           :error nil)))
    (incf *contract-assertions*)
    (if (wait-for-process process 0.1)
        (format t "~&PASS checker-runner-timeout~%")
        (progn
          (incf *contract-failures*)
          (format t "~&FAIL checker-runner-timeout~%")
          (format *error-output* "  expected the child process to time out~%"))))
  (format t "~&ASSERTIONS ~D~%FAILURES ~D~%"
          *contract-assertions*
          *contract-failures*))
(sb-ext:exit :code (if (zerop *contract-failures*) 0 1))
