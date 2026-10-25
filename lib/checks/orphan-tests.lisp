(require :asdf)

(defparameter +max-input-bytes+ (* 1024 1024))
(defparameter +max-total-asd-bytes+ (* 16 1024 1024))
(defparameter +max-tree-entries+ 50000)
(defparameter +max-tree-depth+ 128)

(progn (defvar *violations* nil) (defvar *source-root* nil))
(defvar *total-asd-bytes* 0)

(defun fail-closed (format-control &rest arguments)
  (error "~A" (apply #'format nil format-control arguments)))

(defun violation (category format-control &rest arguments)
  (push (format nil "[orphan-tests:~A] ~A"
                category (apply #'format nil format-control arguments))
        *violations*))

(defun starts-with (string prefix)
  (and (<= (length prefix) (length string))
       (string= string prefix :end1 (length prefix))))

(defun ends-with (string suffix)
  (and (<= (length suffix) (length string))
       (string= string suffix :start1 (- (length string) (length suffix)))))

(defun control-character-p (character)
  (or (< (char-code character) 32) (= (char-code character) 127)))

(defun proper-list-p (value)
  (and (listp value) (integerp (list-length value))))

(defun normalize-relative-path (path &key allow-trailing-slash)
  (let ((path (if (and allow-trailing-slash (ends-with path "/"))
                  (subseq path 0 (1- (length path)))
                path)))
    (unless (and (stringp path) (plusp (length path))
                 (not (char= (char path 0) #\/))
                 (not (find #\\ path))
                 (notany #'control-character-p path)
                 (notany (lambda (character) (find character "*?[]")) path)
                 (not (find #\: path)))
      (fail-closed "expected a portable relative path, got ~S" path))
    (let ((parts (uiop:split-string path :separator "/")))
      (unless (and parts
                   (every (lambda (part)
                            (and (plusp (length part))
                                 (not (string= part "."))
                                 (not (string= part ".."))))
                          parts))
        (fail-closed "path contains an empty or parent component: ~S" path)))
    path))

(defun normalize-root-option (path)
  (normalize-relative-path
   (if (ends-with path "/") (subseq path 0 (1- (length path))) path)))

(defun path-join (parent child)
  (let ((parts nil)
        (valid t))
    (labels ((add-segments (path)
               (unless (and (stringp path)
                            (not (starts-with path "/"))
                            (not (find #\\ path))
                            (not (find #\: path))
                            (notany #'control-character-p path)
                            (notany (lambda (character)
                                      (find character "*?[]"))
                                    path))
                 (setf valid nil))
               (when valid
                 (dolist (part (uiop:split-string path :separator "/"))
                   (cond
                     ((or (string= part "") (string= part ".")) nil)
                     ((string= part "..")
                      (if parts (pop parts) (setf valid nil)))
                     (t (push part parts)))))))
      (add-segments parent)
      (add-segments child)
      (if valid
          (format nil "~{~A~^/~}" (nreverse parts))
          (progn
            (violation "unverified"
                       "cannot resolve ASDF pathname ~S relative to ~S"
                       child parent)
            nil)))))

(defun canonical-directory (path context)
  (unless (uiop:directory-exists-p path)
    (fail-closed "~A is not an existing directory: ~A" context path))
  (uiop:ensure-directory-pathname (truename path)))

(defun canonical-namestring (path)
  (uiop:native-namestring (truename path)))

(defun contained-path-p (root path)
  (let ((root-name (uiop:native-namestring root))
        (path-name (canonical-namestring path)))
    (starts-with path-name root-name)))

(defun check-contained-path (root path context)
  (when (probe-file path)
    (unless (contained-path-p root path)
      (fail-closed "~A resolves outside --source-root: ~A" context path))))

(defun directory-relative-name (source-root path)
  (let ((relative (uiop:unix-namestring
                   (enough-namestring path source-root))))
    (let ((trimmed (string-right-trim "/" relative)))
      (if (member trimmed '("" ".") :test #'string=) "" trimmed))))

(defun safe-read-syntax-p (text path)
  (let ((length (length text))
        (index 0)
        (depth 0))
    (labels ((bad (message)
               (fail-closed "~A: ~A" path message))
             (skip-string ()
               (incf index)
               (loop while (< index length)
                     for character = (char text index)
                     do (incf index)
                        (cond ((char= character #\\)
                               (when (< index length) (incf index)))
                              ((char= character #\") (return))))
               (when (or (zerop index)
                         (not (char= (char text (1- index)) #\"))
                         (and (> index 1)
                              (char= (char text (- index 2)) #\\)))
                 (bad "unterminated string literal")))
             (skip-line-comment ()
               (loop while (< index length)
                     for character = (char text index)
                     do (incf index)
                        (when (char= character #\Newline) (return))))
             (skip-block-comment ()
               (incf index 2)
               (let ((comment-depth 1))
                 (loop while (and (< index length) (plusp comment-depth))
                       do (cond
                            ((and (char= (char text index) #\#)
                                  (< (1+ index) length)
                                  (char= (char text (1+ index)) #\|))
                             (incf comment-depth)
                             (incf index 2))
                            ((and (char= (char text index) #\|)
                                  (< (1+ index) length)
                                  (char= (char text (1+ index)) #\#))
                             (decf comment-depth)
                             (incf index 2))
                            (t (incf index))))
                 (unless (zerop comment-depth)
                   (bad "unterminated block comment"))))
             (skip-character-literal ()
               (incf index 2)
               (when (>= index length)
                 (bad "incomplete character literal"))
               (let ((character (char text index)))
                 (incf index)
                 (unless (or (find character '(#\Space #\Tab #\Newline #\Return
                                                #\( #\) #\" #\;))
                             (member character '(#\# #\\)))
                   (loop while (< index length)
                         for next = (char text index)
                         while (not (or (find next '(#\Space #\Tab #\Newline #\Return
                                                      #\( #\) #\" #\;))
                                        (char= next #\#)))
                         do (incf index))))))
      (loop while (< index length)
            for character = (char text index)
            do (cond
                 ((char= character #\") (skip-string))
                 ((char= character #\;) (skip-line-comment))
                 ((char= character #\#)
                  (when (>= (1+ index) length)
                    (bad "incomplete reader dispatch"))
                  (case (char text (1+ index))
                    (#\| (skip-block-comment))
                    (#\: (incf index 2))
                    (#\\ (skip-character-literal))
                    (#\; (incf index 2))
                    ((#\P #\p)
                     (incf index 2)
                     (unless (and (< index length)
                                  (char= (char text index) #\"))
                       (bad "#P pathname syntax requires a string literal")))
                    (#\. (bad "read-time evaluation is unsupported"))
                    ((#\+ #\-) (bad "reader conditionals are unsupported"))
                    (otherwise (bad "unsupported reader dispatch"))))
                 ((char= character #\() (incf depth) (incf index)
                  (when (> depth 256) (bad "form nesting exceeds 256 levels")))
                 ((char= character #\)) (decf depth) (incf index)
                  (when (minusp depth) (bad "unmatched closing parenthesis")))
                 (t (incf index))))
      (unless (zerop depth) (bad "unclosed list"))
      t)))

(defun read-bounded-string (path)
  (let ((size (or (ignore-errors (with-open-file (stream path :direction :input)
                                   (file-length stream)))
                  0)))
    (when (> size +max-input-bytes+)
      (fail-closed "~A exceeds the ~D-byte input limit" path +max-input-bytes+))
    (incf *total-asd-bytes* size)
    (when (> *total-asd-bytes* +max-total-asd-bytes+)
      (fail-closed "ASDF definitions exceed the ~D-byte total input limit"
                   +max-total-asd-bytes+)))
  (uiop:read-file-string path :external-format :utf-8))

(defun in-package-form-p (form)
  (and (proper-list-p form) (= (length form) 2)
       (eq (first form) 'cl:in-package)))

(defun update-read-package (form path)
  (unless (and (in-package-form-p form)
               (or (stringp (second form)) (symbolp (second form))))
    (fail-closed "~A has a malformed IN-PACKAGE form" path))
  (let* ((designator (second form))
         (name (if (stringp designator) designator (symbol-name designator)))
         (package (find-package (string-upcase name))))
    (unless package
      (fail-closed "~A names an unavailable package in IN-PACKAGE: ~S" path name))
    package))

(defun read-asd-forms (path)
  (let* ((text (read-bounded-string path))
         (*read-eval* nil)
         (*readtable* (copy-readtable nil))
         (*package* (find-package :cl-user))
         (eof (gensym "EOF"))
         (forms nil))
    (safe-read-syntax-p text path)
    (with-input-from-string (stream text)
      (loop for form = (read stream nil eof)
            until (eq form eof)
            do (when (in-package-form-p form)
                 (setf *package* (update-read-package form path)))
               (push form forms)
            when (> (length forms) 10000)
              do (fail-closed "~A contains too many top-level forms" path)))
    (nreverse forms)))

(defun recursive-files (root)
  (let ((seen (make-hash-table :test #'equal))
        (count 0))
    (labels ((walk (directory depth)
               (when (> depth +max-tree-depth+)
                 (fail-closed "directory nesting exceeds ~D levels under ~A"
                              +max-tree-depth+ directory))
               (check-contained-path root directory "directory")
               (let ((real (canonical-namestring directory)))
                 (when (gethash real seen)
                   (fail-closed "directory alias or cycle while scanning ~A" directory))
                 (setf (gethash real seen) t))
               (let ((files (uiop:directory-files directory))
                     (subdirectories (uiop:subdirectories directory)))
                 (incf count (+ (length files) (length subdirectories)))
                 (when (> count +max-tree-entries+)
                   (fail-closed "directory tree exceeds ~D entries under ~A"
                                +max-tree-entries+ directory))
                 (append files
                         (mapcan (lambda (child) (walk child (1+ depth)))
                                 subdirectories)))))
      (walk root 0))))

(defun asd-file-p (path)
  (and (pathname-type path)
       (string-equal (pathname-type path) "asd")))

(defun lisp-file-p (path)
  (and (pathname-type path)
       (string-equal (pathname-type path) "lisp")))

(defun operator-symbol-p (symbol name packages)
  (and (symbolp symbol)
       (string-equal (symbol-name symbol) name)
       (member (and (symbol-package symbol)
                    (package-name (symbol-package symbol)))
               packages :test #'string-equal)))

(defun defsystem-form-p (form)
  (and (proper-list-p form)
       (>= (length form) 2)
       (or (eq (first form) (find-symbol "DEFSYSTEM" :asdf))
           (operator-symbol-p (first form) "DEFSYSTEM"
                              (list "ASDF" "ASDF/DEFSYSTEM"
                                    "ASDF-USER" "CL-USER")))))

(defun system-name-string (value path &optional allow-nested-p)
  (let* ((symbol-name-p (symbolp value))
         (name (cond ((stringp value) value)
                     (symbol-name-p (string-downcase (symbol-name value)))
                     (t (fail-closed "~A has a non-literal system name" path)))))
    (labels ((simple-name-p (part)
               (and (plusp (length part))
                    (string= part (string-downcase part))
                    (not (find #\_ part))))
             (valid-name-p (start)
               (let ((slash (position #\/ name :start start)))
                 (and (simple-name-p (subseq name start slash))
                      (or (null slash)
                          (and (or allow-nested-p
                                   (not (position #\/ name :start (1+ slash))))
                               (valid-name-p (1+ slash))))))))
      (unless (valid-name-p 0)
        (fail-closed "~A has an invalid ASDF system name ~S" path value))
      (when (or (find #\: name)
                (find #\\ name)
                (some (lambda (character)
                        (find character "*?[]"))
                      name)
                (some (function control-character-p) name))
        (violation "unverified"
                   "~A has an ASDF system name that cannot be mapped to a portable path: ~S"
                   path value))
      name)))


(defun plist-options (plist context allowed &optional custom-component-p)
  (unless (proper-list-p plist)
    (fail-closed "~A options must be a proper list" context))
  (unless (evenp (length plist))
    (fail-closed "~A options must be key/value pairs" context))
  (let ((result (make-hash-table :test (function eq))))
    (loop for (key value) on plist by (function cddr)
          do (unless (keywordp key)
               (fail-closed "~A option key must be a keyword, got ~S" context key))
             (unless (member key allowed :test (function eq))
               (if custom-component-p
                   (violation "unverified"
                              "~A option ~S depends on the registered custom ASDF component type"
                              context key)
                   (fail-closed "~A has unsupported option ~S" context key)))
             (multiple-value-bind (old present-p) (gethash key result)
               (declare (ignore old))
               (unless present-p
                 (setf (gethash key result) value))))
    result))

(defun option (options key)
  (gethash key options))

(defparameter +system-options+
  (quote (:pathname :components :serial :depends-on :weakly-depends-on
    :description :long-description :version :author :maintainer
    :homepage :bug-tracker :long-name :mailto :source-control
    :in-order-to :perform :explain :output-files :operation-done-p
    :build-pathname :build-operation :defsystem-depends-on
    :default-component-class :class :entry-point :if-feature)))

(defparameter +system-compatibility-options+
  (quote (:licence :license)))

(defparameter +standard-component-options+
  (quote (:pathname :depends-on :if-feature :description :long-description
    :author :maintainer :default-component-class :perform :explain
    :output-files :operation-done-p :in-order-to)))

(defparameter +component-compatibility-options+
  (quote (:type)))

(defparameter +component-weak-dependency-option+
  (quote (:weakly-depends-on)))

(defparameter +file-component-options+
  (append +standard-component-options+
          +component-weak-dependency-option+
          +component-compatibility-options+))

(defparameter +module-component-options+
  (append +standard-component-options+
          +component-weak-dependency-option+
          (quote (:components :serial))))

(defparameter +static-component-options+
  (append +standard-component-options+
          +component-weak-dependency-option+
          +component-compatibility-options+))

(defun system-definitions (asd-files)
  (let ((definitions (make-hash-table :test #'equal)))
    (dolist (asd-file asd-files)
      (check-contained-path *source-root* asd-file "ASDF file")
      (let* ((relative-directory
               (directory-relative-name *source-root* (uiop:pathname-directory-pathname asd-file)))
             (forms (read-asd-forms asd-file)))
        (dolist (form forms)
          (cond
            ((in-package-form-p form) nil)
            ((defsystem-form-p form)
             (let* ((name (system-name-string (second form) asd-file))
                    (slash (position #\/ name)))
               (when slash
                 (let ((master (subseq name 0 slash))
                       (asd-master (string-downcase (or (pathname-name asd-file) ""))))
                   (unless (string= master asd-master)
                     (fail-closed
                      "complex ASDF system ~S has master ~S, but ~A is named ~S"
                      name master asd-file asd-master))))
               (when (gethash name definitions)
                 (fail-closed "ASDF system ~S is defined more than once" name))
               (setf (gethash name definitions)
                     (list :form form :base relative-directory :path asd-file))))
            (t (fail-closed "~A contains unsupported top-level form" asd-file))))))
    definitions))

(defun path-specifier-string (value context)
  (cond
    ((stringp value) (values value nil))
    ((symbolp value) (values (string-downcase (symbol-name value)) nil))
    ((pathnamep value)
     (if (or (uiop:logical-pathname-p value)
             (uiop:absolute-pathname-p value))
         (progn
           (violation "unverified"
                      "~A uses an absolute or logical pathname that cannot be mapped"
                      context)
           (values nil nil))
         (values (uiop:unix-namestring value)
                 t)))
    (t (fail-closed "~A must be a pathname, string, or symbol" context))))

(defun selected-system-data (definition name)
  (let* ((form (getf definition :form))
         (path (getf definition :path))
         (options (plist-options (cddr form) name (append +system-options+ +system-compatibility-options+)))
         (root (getf definition :base))
         (pathname (option options :pathname))
         (components (option options :components)))
    (when pathname
      (let ((relative (path-specifier-string
                       pathname (format nil "ASDF system ~S :pathname" name))))
        (setf root (and relative (path-join root relative)))))
    (unless (or (null components) (proper-list-p components))
      (fail-closed "ASDF system ~S :components must be a literal list" name))
    (list :name name :path path :root root :components components
          :class (option options :class)
          :analyzable (not (null root)))))


(defun component-name-string (value context)
  (let* ((symbol-name-p (symbolp value))
         (name (cond ((stringp value) value)
                     (symbol-name-p (string-downcase (symbol-name value)))
                     (t (fail-closed
                         "~A component name must be a literal string or symbol"
                         context))))
         (unmappable-p
           (or (find #\: name)
               (find #\\ name)
               (some (lambda (character)
                       (find character "*?[]"))
                     name)
               (some (function control-character-p) name))))
    (unless (and (plusp (length name))
                 (string= name (string-downcase name))
                 (not (find #\_ name))
                 (not (find #\/ name)))
      (fail-closed "~A has an invalid ASDF simple component name ~S"
                   context value))
    (when unmappable-p
      (violation "unverified"
                 "~A component name ~S cannot be mapped to a portable path"
                 context value))
    (unless unmappable-p name)))

(defun component-options (form context)
  (unless (and (proper-list-p form) (>= (length form) 2))
    (fail-closed "~A component must be a proper list with a name" context))
  (let* ((kind (first form))
         (kind-name (and (symbolp kind)
                         (string-upcase (symbol-name kind))))
         (normalized-kind
           (cond ((equal kind-name "MODULE") :module)
                 ((member kind-name (quote ("FILE" "CL-SOURCE-FILE")) :test (function equal)) :file)
                 ((equal kind-name "STATIC-FILE") :static-file)
                 (kind-name kind)
                 (t (fail-closed "~A component kind must be a symbol" context))))
         (allowed
           (case normalized-kind
             ((:module) +module-component-options+)
             ((:file) +file-component-options+)
             ((:static-file) +static-component-options+)
             (otherwise
              (append +standard-component-options+
                      +component-weak-dependency-option+
                      +component-compatibility-options+)))))
    (values normalized-kind (second form)
            (plist-options
             (cddr form) context allowed
             (not (member normalized-kind (quote (:module :file :static-file))
                           :test (function eq)))))))

(defun component-path (parent name pathname context &key directory)
  (declare (ignore directory))
  (multiple-value-bind (relative pathname-type-overridden)
      (if pathname
          (path-specifier-string pathname
                                 (format nil "~A :pathname" context))
          (values (component-name-string name context) nil))
    (values (when relative (path-join parent relative))
            pathname-type-overridden)))

(defun component-lisp-path (path type context &key pathname-type-overridden)
  (let* ((parsed (parse-namestring path))
         (extension (pathname-type parsed))
         (normalized-type (cond ((stringp type) (string-downcase type))
                                ((and (symbolp type) (keywordp type))
                                 (string-downcase (symbol-name type)))
                                ((null type) "lisp")
                                (t (fail-closed "~A :type must be a literal string or symbol"
                                                context)))))
    (when (ends-with path "/")
      (fail-closed "~A resolves to a directory, not a file" context))
    (cond
      (pathname-type-overridden
       (when (and extension (string-equal extension "lisp")) path))
      ((string-equal normalized-type "lisp")
       (cond
         ((null extension) (concatenate (quote string) path ".lisp"))
         ((string-equal extension "lisp") path)
         (t (concatenate (quote string) path ".lisp")))))))

(defun validate-component-path-in-roots (path test-roots context)
  (declare (ignore context))
  (and path
       (some (lambda (root)
               (or (string= path root)
                   (starts-with path (concatenate 'string root "/"))))
             test-roots)))

(defun collect-components (components parent system-name test-roots
                                      registered files uncertain)
  (unless (proper-list-p components)
    (fail-closed "ASDF system ~S has malformed :components" system-name))
  (labels ((mark-uncertain (path)
                           (setf (gethash :unverified uncertain) t)
                           (if path
                               (let ((prefix (concatenate 'string path "/"))
                                     (lisp-file (if (ends-with path ".lisp")
                                                    path
                                                  (concatenate 'string path ".lisp"))))
                                 (maphash (lambda (file ignored)
                                            (declare (ignore ignored))
                                            (when (and (stringp file)
                                                       (or (string= file path)
                                                           (string= file lisp-file)
                                                           (starts-with file prefix)))
                                              (setf (gethash file uncertain) t)))
                                          files))
                             (maphash (lambda (file ignored)
                                        (declare (ignore ignored))
                                        (when (stringp file)
                                          (setf (gethash file uncertain) t)))
                                      files)))
           (collect-nested (nested nested-parent)
                           (collect-components nested nested-parent system-name test-roots
                                               registered files uncertain)))
    (dolist (form components)
      (let ((context (format nil "ASDF system ~S" system-name)))
        (multiple-value-bind (kind name options)
            (component-options form context)
          (let ((pathname (option options :pathname)))
            (case kind
              (:module
               (let* ((module-path
                       (component-path parent name pathname context :directory t))
                      (nested (option options :components)))
                 (unless (proper-list-p nested)
                   (fail-closed "~A module must have a literal :components list" context))
                 (if module-path
                     (collect-nested nested module-path)
                   (mark-uncertain nil))))
              (:file
               (multiple-value-bind (file-path pathname-type-overridden)
                   (component-path parent name pathname context)
                 (let ((source-path
                        (when file-path
                          (component-lisp-path
                           file-path (option options :type) context
                           :pathname-type-overridden pathname-type-overridden))))
                   (cond
                    ((null file-path) (mark-uncertain nil))
                    ((and source-path
                          (validate-component-path-in-roots
                           source-path test-roots context))
                     (setf (gethash source-path registered) t))))))
              (:static-file
               (unless (component-path parent name pathname context)
                 (mark-uncertain nil)))
              (otherwise
               (let* ((custom-path (component-path parent name pathname context))
                      (nested (option options :components)))
                 (when (and custom-path
                            (validate-component-path-in-roots
                             custom-path test-roots context))
                   (violation
                    "unverified"
                    "ASDF system ~S uses custom component type ~S at ~S inside a test root"
                    system-name kind custom-path)
                   (mark-uncertain custom-path))
                 (unless custom-path
                   (mark-uncertain nil))
                 (when nested
                   (unless (proper-list-p nested)
                     (fail-closed "~A custom component has malformed :components" context))
                   (if custom-path
                       (collect-nested nested custom-path)
                     (mark-uncertain nil))))))))))
    ))

(defun collect-test-files (source-root test-roots)
  (let ((files (make-hash-table :test #'equal)))
    (dolist (root test-roots)
      (let* ((directory (merge-pathnames (uiop:ensure-directory-pathname root)
                                         source-root))
             (canonical (canonical-directory directory "--test-root")))
        (unless (contained-path-p source-root canonical)
          (fail-closed "--test-root resolves outside --source-root: ~A" root))
        (let ((count-before (hash-table-count files)))
          (dolist (file (recursive-files canonical))
            (check-contained-path source-root file "test file")
            (when (lisp-file-p file)
              (let* ((directory-name (directory-relative-name source-root
                                                              (uiop:pathname-directory-pathname file)))
                     (relative (if (string= directory-name "")
                                   (file-namestring file)
                                   (concatenate 'string directory-name "/"
                                                (file-namestring file)))))
                (normalize-relative-path relative)
                (unless (some (lambda (test-root)
                                (starts-with relative
                                             (concatenate 'string test-root "/")))
                              test-roots)
                  (fail-closed "discovered path is outside every test root: ~A" relative))
                (when (gethash relative files)
                  (fail-closed "overlapping test roots include ~A more than once" relative))
                (setf (gethash relative files) t))))
          (when (= count-before (hash-table-count files))
            (violation "empty" "test root ~S contains no .lisp files" root)))))
    files))

(defun validate-roots (source-root test-roots)
  (unless test-roots
    (fail-closed "at least one --test-root is required"))
  (when (> (length test-roots) 100)
    (fail-closed "at most 100 --test-root values are supported"))
  (let ((normalized (mapcar #'normalize-root-option test-roots)))
    (when (/= (length normalized) (length (remove-duplicates normalized :test #'string=)))
      (fail-closed "--test-root values must be unique"))
    (dolist (left normalized)
      (dolist (right normalized)
        (when (and (not (string= left right))
                   (starts-with right (concatenate 'string left "/")))
          (fail-closed "--test-root values must not overlap: ~S and ~S" left right))))
    (dolist (root normalized)
      (canonical-directory (merge-pathnames (uiop:ensure-directory-pathname root)
                                            source-root)
                           "--test-root"))
    normalized))

(defun validate-allowlist (allowlist roots files)
  (when (> (length allowlist) 1000)
    (fail-closed "at most 1000 --allowlist values are supported"))
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (path allowlist)
      (let ((safe (normalize-relative-path path)))
        (when (gethash safe seen)
          (fail-closed "duplicate --allowlist path: ~A" safe))
        (unless (some (lambda (root)
                        (starts-with safe (concatenate 'string root "/")))
                      roots)
          (fail-closed "--allowlist path is outside every --test-root: ~A" safe))
        (unless (gethash safe files)
          (fail-closed "--allowlist path is not an existing .lisp test file: ~A" safe))
        (setf (gethash safe seen) t)))
    seen))

(defun validate-systems (systems)
  (unless systems
    (fail-closed "at least one --test-system is required"))
  (when (> (length systems) 100)
    (fail-closed "at most 100 --test-system values are supported"))
  (let ((normalized (mapcar (lambda (system)
                              (system-name-string system "--test-system" t))
                            systems)))
    (when (/= (length normalized)
              (length (remove-duplicates normalized :test #'string=)))
      (fail-closed "--test-system values must be unique"))
    normalized))


(defun parse-options (arguments)
  (let ((result (make-hash-table :test #'equal))
        (repeatable '("--test-root" "--test-system" "--allowlist"))
        (allowed '("--source-root" "--test-root" "--test-system" "--allowlist"))
        (index 0))
    (loop while (< index (length arguments))
          for key = (nth index arguments)
          do (unless (member key allowed :test #'string=)
               (fail-closed "unknown option ~S" key))
             (incf index)
             (when (or (>= index (length arguments))
                       (member (nth index arguments) allowed :test #'string=))
               (fail-closed "option ~A requires a value" key))
             (let ((value (nth index arguments)))
               (if (member key repeatable :test #'string=)
                   (push value (gethash key result))
                   (if (gethash key result)
                       (fail-closed "option ~A may occur only once" key)
                       (setf (gethash key result) (list value))))
               (incf index)))
    (dolist (key '("--source-root" "--test-root" "--test-system"))
      (unless (gethash key result)
        (fail-closed "required option ~A is missing" key)))
    (maphash (lambda (key value)
               (when (member key repeatable :test #'string=)
                 (setf (gethash key result) (nreverse value))))
             result)
    result))

(defun command-arguments () (rest sb-ext:*posix-argv*))

(defun run-check (options)
  (let* ((source-argument (first (gethash "--source-root" options)))
         (source-pathname (pathname source-argument))
         (source-directory-p (and (stringp source-argument)
                                  (plusp (length source-argument))
                                  (notany #'control-character-p source-argument)
                                  (uiop:absolute-pathname-p source-pathname)
                                  (uiop:directory-exists-p source-pathname)))
         (source-root
           (progn
             (unless source-directory-p
               (fail-closed "--source-root must be an absolute existing directory"))
             (canonical-directory source-argument "--source-root")))
         (*source-root* source-root)
         (*total-asd-bytes* 0)
         (roots (validate-roots source-root (gethash "--test-root" options)))
         (systems (validate-systems (gethash "--test-system" options)))
         (all-files (recursive-files source-root))
         (asd-files (remove-if-not #'asd-file-p all-files))
         (definitions (system-definitions asd-files))
         (registered (make-hash-table :test #'equal))
         (files (collect-test-files source-root roots))
         (uncertain (make-hash-table :test #'equal)))
    (dolist (system systems)
      (let* ((definition (gethash system definitions))
             (slash (position #\/ system))
             (master-name (and slash (subseq system 0 slash)))
             (master-definition (and master-name (gethash master-name definitions)))
             (master-data (and master-definition
                               (selected-system-data master-definition master-name))))
        (cond
          (definition
           (let* ((data (selected-system-data definition system))
                  (components (getf data :components)))
             (if (getf data :analyzable)
                 (collect-components components (getf data :root) system roots
                                     registered files uncertain)
                 (progn
                   (setf (gethash :unverified uncertain) t)
                   (maphash (lambda (file ignored)
                              (declare (ignore ignored))
                              (setf (gethash file uncertain) t))
                            files)))))
          ((and master-data
                (symbolp (getf master-data :class))
                (string-equal (symbol-name (getf master-data :class))
                              "PACKAGE-INFERRED-SYSTEM"))
           (violation "unverified"
                      "ASDF package-inferred test system ~S cannot be analyzed statically"
                      system)
           (setf (gethash :unverified uncertain) t)
           (maphash (lambda (file ignored)
                      (declare (ignore ignored))
                      (setf (gethash file uncertain) t))
                    files))
          (t
           (fail-closed "requested ASDF test system ~S was not found" system)))))
    (let ((allowlist (validate-allowlist (gethash "--allowlist" options) roots files)))
      (when (and (zerop (hash-table-count registered))
                 (zerop (hash-table-count uncertain)))
        (violation "empty" "selected ASDF test systems register no Lisp components"))
      (when (zerop (hash-table-count files))
        (violation "empty" "configured test roots contain no .lisp files"))
      (maphash (lambda (path ignored)
                 (declare (ignore ignored))
                 (unless (or (gethash path registered)
                             (gethash path allowlist)
                             (gethash path uncertain))
                   (violation "unregistered" "test file ~S is not registered" path)))
               files)
      (maphash (lambda (path ignored)
                 (declare (ignore ignored))
                 (unless (gethash path files)
                   (violation "missing-component"
                              "registered Lisp component ~S does not exist" path)))
               registered))
    (nreverse *violations*)))


(defun main ()
  (handler-case
      (let* ((options (parse-options (command-arguments)))
             (violations (run-check options)))
        (dolist (message violations)
          (format *error-output* "~A~%" message))
        (if violations
            (uiop:quit 1)
            (progn
              (format t "orphan-tests: ~D ASDF test systems and all configured .lisp files agree.~%"
                      (length (gethash "--test-system" options)))
              (uiop:quit 0))))
    (error (condition)
      (format *error-output* "[orphan-tests:invalid] ~A~%" condition)
      (uiop:quit 1))))

(main)
