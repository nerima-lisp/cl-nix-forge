;;;; The delivered image's toplevel, named by :ENTRY-POINT in
;;;; forge-preset-cli.asd.
;;;;
;;;; This is a copy of the discovery cl-weave's src/cli-image.lisp performs,
;;;; and it is the SUBJECT of the `installSource` checks in default.nix
;;;; rather than a helper for them: the contract `mkExecutable` documents is
;;;; "share/common-lisp/source/ exists under the prefix of the file this
;;;; image is running out of", and the only honest way to test that is to
;;;; have an image go looking for it exactly the way a real one does.

(defpackage :forge-preset/cli
  (:use :cl)
  (:export #:image-entry-point))

(in-package :forge-preset/cli)

(defun anchor-prefix-pathname (anchor)
  "The installation prefix ANCHOR sits under: the parent of its directory, so
that $prefix/bin/forge-preset-cli and $prefix/lib/forge-preset-cli.core both
yield $prefix/."
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname anchor)))

(defun image-anchor-pathnames ()
  "The files this image is running out of, most specific first.

SB-EXT:*RUNTIME-PATHNAME* is the executable itself on the `program-op` path,
where the image is dumped with :EXECUTABLE T, and the SBCL binary on the
Darwin fallback, where the image is a bare core started with --core;
SB-EXT:*CORE-PATHNAME* names that core. `mkExecutable` installs sources under
the prefix of BOTH, which is what makes one discovery work on two very
different delivery shapes."
  (remove-duplicates (remove nil (list sb-ext:*runtime-pathname*
                                       sb-ext:*core-pathname*))
                     :test #'equal))

(defun installed-source-root ()
  (loop for anchor in (image-anchor-pathnames)
        thereis (uiop:directory-exists-p
                 (merge-pathnames #p"share/common-lisp/source/"
                                  (anchor-prefix-pathname anchor)))))

(defun image-entry-point ()
  (let ((root (installed-source-root)))
    (setf *default-pathname-defaults* (uiop:getcwd))
    ;; UIOP caches the temporary directory, so an image carries the builder's
    ;; TMPDIR until this re-reads the environment.
    (uiop:setup-temporary-directory)
    ;; Proof that `lispDependencies` reached the DELIVERY and not just the
    ;; library: this call is compiled into the image, so a binary built from
    ;; arguments that omitted the dependency could not have been built at all.
    (format t "~&support=~A~%" (forge-preset-support:support-marker))
    (format t "~&preset=~A~%" (forge-preset:describe-preset "images"))
    (format t "~&source-root=~A~%" (or root "NONE"))
    (unless root
      (format *error-output* "~&forge-preset-cli: no source tree installed beside this image~%")
      (finish-output *error-output*)
      (uiop:quit 1))
    ;; :IGNORE-INHERITED-CONFIGURATION, where cl-weave inherits: a check runs
    ;; in an environment cl-nix-forge itself populates, and a registry that
    ;; fell back to CL_SOURCE_REGISTRY would pass whether or not anything had
    ;; been installed beside the image. Only the shipped tree may resolve the
    ;; system loaded below.
    (asdf:initialize-source-registry
     `(:source-registry (:tree ,root) :ignore-inherited-configuration))
    ;; The shipped sources are a read-only store path, so fasls must land in
    ;; a writable per-user cache no matter what the surrounding environment
    ;; asks for.
    (asdf:initialize-output-translations
     '(:output-translations (t (:home ".cache" "common-lisp" :implementation))
       :ignore-inherited-configuration))
    (handler-case
        (progn
          (asdf:load-system "forge-preset-runtime")
          (format t "~&runtime=~A~%"
                  (uiop:symbol-call :forge-preset/runtime :runtime-marker)))
      (error (condition)
        (format *error-output* "~&forge-preset-cli: loading forge-preset-runtime failed: ~A~%"
                condition)
        (finish-output *error-output*)
        (uiop:quit 1)))
    (finish-output)
    (uiop:quit 0)))
