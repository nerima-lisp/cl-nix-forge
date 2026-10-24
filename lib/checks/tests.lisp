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

(defun run-checker (script arguments)
  (let* ((run-number (incf *contract-run-number*))
         (stdout-path (temporary-log-path run-number "stdout"))
         (stderr-path (temporary-log-path run-number "stderr")))
    (unwind-protect
         (let ((process
                 (sb-ext:run-program
                  "sbcl"
                  (append (list "--script" (contract-path script)) arguments)
                  :search t
                  :wait t
                  :output stdout-path
                  :error stderr-path)))
           (values (sb-ext:process-exit-code process)
                   (read-log-file stdout-path)
                   (read-log-file stderr-path)))
      (when (probe-file stdout-path)
        (delete-file stdout-path))
      (when (probe-file stderr-path)
        (delete-file stderr-path)))))

(defun feature-lint-arguments (fixture)
  (append
   (list "--source-root" (fixture-root "feature-lint" fixture)
         "--feature-definitions" "nix/feature-dependencies.sexp"
         "--glossary" "docs/glossary.md"
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

(defun orphan-test-arguments (fixture)
  (append
   (list "--source-root" (fixture-root "orphan-tests" fixture)
         "--test-root" "t")
   (loop for system in '("forge-tests/alpha" "forge-tests/beta")
         append (list "--test-system" system))))

(defun run-case (name script arguments expected-marker)
  (incf *contract-assertions*)
  (let ((exit-code nil)
        (combined-output "")
        (passed nil)
        (failure-detail nil))
    (handler-case
        (multiple-value-bind (status stdout stderr)
            (run-checker script arguments)
          (setf exit-code status
                combined-output (concatenate 'string stdout stderr)
                passed
                (if expected-marker
                    (and status
                         (/= status 0)
                         (search expected-marker combined-output))
                    (eql status 0))))
      (error (condition)
        (setf failure-detail (princ-to-string condition))))
    (format t "~&~A ~A~%" (if passed "PASS" "FAIL") name)
    (unless passed
      (incf *contract-failures*)
      (format *error-output* "  expected ~A; got exit ~A~%"
              (if expected-marker
                  (format nil "nonzero exit with ~A" expected-marker)
                  "exit 0")
              exit-code)
      (when failure-detail
        (format *error-output* "  runner error: ~A~%" failure-detail))
      (when (plusp (length combined-output))
        (format *error-output* "  checker output:~%~A" combined-output)))))

(defun run-feature-case (label fixture marker)
  (run-case label
            "lib/checks/feature-lint.lisp"
            (feature-lint-arguments fixture)
            marker))

(defun run-orphan-case (label fixture marker)
  (run-case label
            "lib/checks/orphan-tests.lisp"
            (orphan-test-arguments fixture)
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
(run-feature-case "feature-lint-07-glossary-export" "violation-07"
                  "[feature-lint:glossary-export]")
(run-orphan-case "orphan-tests-multi-system-nested" "multi-system-nested" nil)
(run-orphan-case "orphan-tests-unregistered" "unregistered-file"
                 "[orphan-tests:unregistered]")
(run-orphan-case "orphan-tests-missing-component" "missing-component"
                 "[orphan-tests:missing-component]")
(run-orphan-case "orphan-tests-empty" "empty" "[orphan-tests:empty]")

(format t "~&ASSERTIONS ~D~%FAILURES ~D~%"
        *contract-assertions*
        *contract-failures*)
(sb-ext:exit :code (if (zerop *contract-failures*) 0 1))
