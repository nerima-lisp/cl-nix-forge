(defpackage :forge-demo-cli
  (:use :cl)
  (:export #:main))

(in-package :forge-demo-cli)

;;; Reports exactly what the Nix-side checks assert on, so `mkExecutable`'s
;;; single asdf:program-op delivery path (the same on every platform,
;;; including aarch64-darwin with SBCL) is held to its observable contract:
;;;
;;;   line 1  the .asd's :entry-point really ran
;;;   line 2  the user's arguments reached the image untouched -- an earlier,
;;;           now-removed Darwin fallback used to arrive with SBCL's own
;;;           --no-sysinit/--no-userinit prepended, and a leading
;;;           --dynamic-space-size was eaten outright
;;;   line 3  the image runs with the dynamic space size mkExecutable asked for
;;;   line 4  a module named in `imageRequires` survived into the dumped image
(defun main ()
  (format t "~A~%" (forge-demo:banner "executable"))
  (format t "args=~{~A~^ ~}~%" (uiop:command-line-arguments))
  (format t "dynamic-space-size=~A~%" (floor (sb-ext:dynamic-space-size) (* 1024 1024)))
  (format t "sb-cover=~A~%" (if (find-package "SB-COVER") "present" "absent"))
  (finish-output)
  (uiop:quit 0))
