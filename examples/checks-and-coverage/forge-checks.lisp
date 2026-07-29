(defpackage :forge-checks
  (:use :cl)
  (:export :tally :spin :emit-artifacts))

(in-package :forge-checks)

(defun tally (numbers)
  "Sum NUMBERS. Branches, so an sb-cover report over this file is non-trivial."
  (if (null numbers)
      0
      (+ (first numbers) (tally (rest numbers)))))

(defun spin ()
  "Loop forever, allocating nothing, and never return.

SBCL defers signals to safepoints, so a loop like this is exactly the shape
that outlives a bare SIGTERM -- which is what makes the SIGKILL escalation in
`timeoutSeconds`/`killAfterSeconds` worth testing rather than assuming."
  (declare (optimize (speed 3) (safety 0) (debug 0)))
  (let ((counter 0))
    (declare (type (unsigned-byte 32) counter))
    (loop (setf counter (ldb (byte 32 0) (1+ counter))))))

(defun emit-artifacts (json-path text-path parts-directory)
  "Write one artifact of each shape a command check has to handle: a JSON
file, a plain-text file, and a non-empty directory."
  (with-open-file (out json-path :direction :output :if-exists :supersede)
    (format out "{\"schemaVersion\":1,\"kind\":\"forge-report\",\"tally\":~D}~%"
            (tally '(1 2 3))))
  (with-open-file (out text-path :direction :output :if-exists :supersede)
    (format out "forge-report ok~%"))
  (let ((parts (uiop:ensure-directory-pathname parts-directory)))
    (ensure-directories-exist parts)
    (with-open-file (out (merge-pathnames "part-1.txt" parts)
                         :direction :output :if-exists :supersede)
      (format out "part 1 of the forge-checks report~%"))))
