(defpackage :consumer1 (:use :cl) (:export #:native-answer))
(in-package :consumer1)

(cffi:define-foreign-library natlib (:darwin "libnatlib.dylib") (:unix "libnatlib.so"))

(cffi:use-foreign-library natlib)

(cffi:defcfun ("cl_nix_forge_native_answer" native-answer) :int)
