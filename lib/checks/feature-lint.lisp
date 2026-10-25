(require :asdf)

(defstruct feature
  slug source-dirs test-dir facade-packages domain-package infra-package depends-on)

(defstruct lexeme kind text line)
(defstruct syntax-node kind value children line)
(defstruct package-info
  name feature layer exports interns imports uses file)
(defstruct package-reference package symbol internal-p line)
(defstruct graph-edge from to kind path)

(defvar *violations* nil)

(defun fail-closed (format-control &rest arguments)
  (error "~A" (apply #'format nil format-control arguments)))

(defun violation (category format-control &rest arguments)
  (let ((label (cdr (assoc category
                           '(("01" . "feature-set") ("02" . "banned-name")
                             ("03" . "dependency") ("04" . "facade")
                             ("05" . "internal-reference") ("06" . "domain-infra")
                             ("07" . "glossary-export"))
                           :test #'string=))))
    (unless label
      (fail-closed "unknown feature violation category ~S" category))
    (push (format nil "[feature-lint:~A] [check ~A] ~A" label category
                  (apply #'format nil format-control arguments))
          *violations*)))

(defun starts-with (string prefix)
  (and (<= (length prefix) (length string))
       (string= prefix string :end2 (length prefix))))

(defun ends-with (string suffix)
  (and (<= (length suffix) (length string))
       (string= suffix string :start1 (- (length string) (length suffix)))))

(defun trim-space (string)
  (string-trim '(#\Space #\Tab #\Newline #\Return) string))

(defun normalize-name (string)
  (string-downcase string))

(defun normalize-path-string (string)
  (substitute #\/ #\\ string))

(defun relative-pathname (root path)
  (normalize-path-string (enough-namestring path (uiop:ensure-directory-pathname root))))

(defun safe-relative-path (path)
  (unless (and (stringp path) (plusp (length path))
               (not (char= (char path 0) #\/))
               (not (and (> (length path) 1) (char= (char path 1) #\:)))
               (notany (lambda (part) (eq part :up))
                       (or (pathname-directory (pathname path)) nil)))
    (fail-closed "expected a nonempty relative path without parent traversal, got ~S" path))
  path)

(defun resolve-path (root path)
  (merge-pathnames (pathname (safe-relative-path path))
                   (uiop:ensure-directory-pathname root)))

(defun recursive-files (root)
  (labels ((walk (directory)
             (append (uiop:directory-files directory)
                     (mapcan #'walk (uiop:subdirectories directory)))))
    (walk (uiop:ensure-directory-pathname root))))

(defun lisp-file-p (path)
  (and (pathname-type path)
       (string-equal (pathname-type path) "lisp")))

(defun read-safe-forms (path)
  (let ((*read-eval* nil)
        (*package* (find-package :cl-user))
        (*readtable* (copy-readtable nil))
        (eof (gensym "EOF")))
    (with-open-file (stream path :direction :input)
      (loop for form = (read stream nil eof)
            until (eq form eof)
            collect form))))

(defun read-safe-one (path)
  (let ((forms (read-safe-forms path)))
    (unless (= (length forms) 1)
      (fail-closed "~A must contain exactly one readable S-expression" path))
    (first forms)))

(defun safe-plist-p (value)
  (and (listp value)
       (evenp (length value))
       (every #'keywordp (loop for (key value) on value by #'cddr collect key))))

(defun plist-value (plist key &optional default)
  (loop for (candidate value) on plist by #'cddr
        when (eq candidate key) do (return value)
        finally (return default)))

(defun require-string (value context)
  (unless (stringp value)
    (fail-closed "~A must be a string, got ~S" context value))
  value)

(defun require-string-list (value context)
  (unless (and (listp value) (every #'stringp value))
    (fail-closed "~A must be a list of strings, got ~S" context value))
  value)

(defun command-arguments () (rest sb-ext:*posix-argv*))

(defun parse-options (arguments allowed repeatable required)
  (let ((result (make-hash-table :test #'equal))
        (index 0))
    (loop while (< index (length arguments))
          for option = (nth index arguments)
          do (unless (member option allowed :test #'string=)
               (fail-closed "unknown option ~S" option))
             (incf index)
             (when (or (>= index (length arguments))
                       (member (nth index arguments) allowed :test #'string=))
               (fail-closed "option ~A requires a value" option))
             (let ((value (nth index arguments)))
               (if (member option repeatable :test #'string=)
                   (push value (gethash option result))
                   (if (gethash option result)
                       (fail-closed "option ~A may occur only once" option)
                       (setf (gethash option result) (list value))))
               (incf index)))
    (dolist (option required)
      (unless (gethash option result)
        (fail-closed "required option ~A is missing" option)))
    (maphash (lambda (key value)
               (when (member key repeatable :test #'string=)
                 (setf (gethash key result) (nreverse value))))
             result)
    result))

(defun one-option (options name)
  (first (gethash name options)))

(defun many-options (options name)
  (gethash name options))

(defun line-end-p (character)
  (char= character #\Newline))

(defun source-syntax-error (path line format-control &rest arguments)
  (fail-closed "~A:~D: ~A" path line (apply #'format nil format-control arguments)))

(defun scan-source (text path)
  (let ((position 0)
        (line 1)
        (length (length text))
        (tokens nil))
    (labels ((at (offset)
               (when (< (+ position offset) length)
                 (char text (+ position offset))))
             (advance ()
               (let ((character (char text position)))
                 (incf position)
                 (when (line-end-p character) (incf line))
                 character))
             (emit (kind &optional (value "") (token-line line))
               (push (make-lexeme :kind kind :text value :line token-line) tokens))
             (delimiter-p (character)
               (or (find character '(#\Space #\Tab #\Newline #\Return #\Page
                                     #\( #\) #\" #\; #\' #\` #\, #\#))
                   (null character)))
             (skip-line-comment ()
               (loop while (and (< position length)
                                (not (line-end-p (char text position))))
                     do (advance)))
             (skip-block-comment ()
               (let ((start-line line)
                     (depth 0))
                 (advance) (advance)
                 (setf depth 1)
                 (loop while (and (< position length) (> depth 0))
                       do (cond
                            ((and (char= (char text position) #\#)
                                  (eql (at 1) #\|))
                             (advance) (advance) (incf depth))
                            ((and (char= (char text position) #\|)
                                  (eql (at 1) #\#))
                             (advance) (advance) (decf depth))
                            (t (advance))))
                 (when (> depth 0)
                   (source-syntax-error path start-line "unterminated block comment"))))
             (read-string-token ()
               (let ((start-line line)
                     (raw (make-string-output-stream)))
                 (write-char (advance) raw)
                 (loop
                   (when (>= position length)
                     (source-syntax-error path start-line "unterminated string"))
                   (let ((character (advance)))
                     (write-char character raw)
                     (cond
                       ((char= character #\\)
                        (when (>= position length)
                          (source-syntax-error path start-line "unterminated string escape"))
                        (write-char (advance) raw))
                       ((char= character #\")
                        (return (emit :string (get-output-stream-string raw) start-line))))))))
             (read-character-token ()
               (let ((start-line line)
                     (raw (make-string-output-stream)))
                 (write-char (advance) raw)
                 (write-char (advance) raw)
                 (when (>= position length)
                   (source-syntax-error path start-line
                                        "character literal requires a character or name after #\\"))
                 (let ((first (advance))
                       (in-bars nil)
                       (escaped nil))
                   (write-char first raw)
                   (unless (or (delimiter-p first)
                               (and (or (char= first #\\) (char= first #\|))
                                    (or (>= position length)
                                        (delimiter-p (char text position)))))
                     (when (char= first #\|)
                       (setf in-bars t))
                     (when (char= first #\\)
                       (setf escaped t))
                     (loop while (< position length)
                           for character = (char text position)
                           do (cond
                                (escaped
                                 (write-char (advance) raw)
                                 (setf escaped nil))
                                ((char= character #\\)
                                 (write-char (advance) raw)
                                 (setf escaped t))
                                ((char= character #\|)
                                 (write-char (advance) raw)
                                 (setf in-bars (not in-bars)))
                                ((and (not in-bars) (delimiter-p character))
                                 (return))
                                (t (write-char (advance) raw))))
                     (when (or escaped in-bars)
                       (source-syntax-error path start-line
                                            "unterminated escaped character name")))
                   (let ((token (get-output-stream-string raw)))
                     (when (> (length token) 3)
                       (let ((in-bars nil)
                             (escaped nil))
                         (loop for character across (subseq token 2)
                               do (cond
                                    (escaped (setf escaped nil))
                                    ((char= character #\\) (setf escaped t))
                                    ((char= character #\|) (setf in-bars (not in-bars)))
                                    ((and (not in-bars) (char= character #\:))
                                     (source-syntax-error path start-line
                                                          "character name must not contain a package marker ~A"
                                                          token))))))
                     (emit :literal token start-line)))))
             (read-atom ()
               (let ((start-line line)
                     (start-position position)
                     (raw (make-string-output-stream))
                     (in-bars nil)
                     (escaped nil))
                 (loop while (< position length)
                       for character = (char text position)
                       do (cond
                            (escaped
                             (write-char (advance) raw)
                             (setf escaped nil))
                            ((char= character #\\)
                             (write-char (advance) raw)
                             (setf escaped t))
                            ((char= character #\|)
                             (write-char (advance) raw)
                             (setf in-bars (not in-bars)))
                            ((and (not in-bars)
                                  (delimiter-p character)
                                  (not (and (= position start-position)
                                            (eql (at 1) #\:))))
                             (return))
                            (t (write-char (advance) raw)))
                       finally
                          (when (or escaped in-bars)
                            (source-syntax-error path start-line "unterminated escaped symbol")))
                 (let ((text (get-output-stream-string raw)))
                   (when (zerop (length text))
                     (source-syntax-error path start-line "empty token"))
                   (when (string= text "#:")
                     (source-syntax-error path start-line "uninterned symbol requires a name"))
                   (emit :atom text start-line))))
             (read-dispatch-body (spelling start-line &optional allow-empty)
               (let ((raw (make-string-output-stream)))
                 (loop while (and (< position length)
                                  (not (delimiter-p (char text position))))
                       do (write-char (advance) raw))
                 (let ((body (get-output-stream-string raw)))
                   (when (and (zerop (length body)) (not allow-empty))
                     (source-syntax-error path start-line
                                          "incomplete reader dispatch syntax ~A" spelling))
                   body)))
             (radix-digit-value (character)
               (let* ((code (char-code character))
                      (code (if (<= (char-code #\a) code (char-code #\z))
                                (- code (- (char-code #\a) (char-code #\A)))
                                code)))
                 (cond
                   ((<= (char-code #\0) code (char-code #\9))
                    (- code (char-code #\0)))
                   ((<= (char-code #\A) code (char-code #\Z))
                    (+ 10 (- code (char-code #\A))))
                   (t nil))))
             (radix-rational-status (token radix)
               (let* ((start (if (and (plusp (length token))
                                     (find (char token 0) "+-"))
                                1
                                0))
                      (slash (position #\/ token :start start)))
                 (labels ((digits-p (from to)
                            (and (< from to)
                                 (loop for index from from below to
                                       for digit = (radix-digit-value (char token index))
                                       always (and digit (< digit radix)))))
                          (nonzero-digit-p (from to)
                            (loop for index from from below to
                                  for digit = (radix-digit-value (char token index))
                                  thereis (and digit (plusp digit)))))
                   (if slash
                       (if (and (null (position #\/ token :start (1+ slash)))
                                (digits-p start slash)
                                (digits-p (1+ slash) (length token)))
                           (if (nonzero-digit-p (1+ slash) (length token))
                               :valid
                               :zero-denominator)
                           :invalid)
                       (if (digits-p start (length token)) :valid :invalid)))))
             (radix-value (digits)
               (let ((value 0)
                     (valid t))
                 (loop for character across digits
                       for digit = (radix-digit-value character)
                       do (unless digit
                            (setf valid nil)
                            (return))
                          (setf value (+ (* value 10) digit))
                          (when (> value 36)
                            (setf valid nil)
                            (return)))
                 (and valid value)))
             (canonical-label (digits)
               (let ((label (string-left-trim "0" digits)))
                 (if (plusp (length label)) label "0")))
             (decimal-token-at-least-p (digits count)
               (let* ((normalized (canonical-label digits))
                      (count-text (write-to-string count)))
                 (or (> (length normalized) (length count-text))
                     (and (= (length normalized) (length count-text))
                          (not (string< normalized count-text))))))
             (read-dispatch ()
               (let ((start-line line)
                     (prefix (make-string-output-stream)))
                 (write-char (advance) prefix)
                 (let ((digits (make-string-output-stream)))
                   (loop while (ascii-digit-p (at 0))
                         do (write-char (advance) digits))
                   (let* ((digits (get-output-stream-string digits))
                          (dispatch (at 0)))
                     (unless dispatch
                       (source-syntax-error path start-line
                                            "incomplete reader dispatch syntax ~A"
                                            (get-output-stream-string prefix)))
                     (write-string digits prefix)
                     (write-char (advance) prefix)
                     (let* ((spelling (get-output-stream-string prefix))
                            (code (char-upcase dispatch)))
                       (case code
                         (#\(
                          (emit :vector-open spelling start-line))
                         (#\*
                          (let ((bits (read-dispatch-body spelling start-line t)))
                            (unless (every (lambda (character)
                                             (find character "01"))
                                           bits)
                              (source-syntax-error path start-line
                                                   "invalid bit-vector literal ~A"
                                                   (concatenate 'string spelling bits)))
                            (when (and (plusp (length digits))
                                       (not (decimal-token-at-least-p digits (length bits))))
                              (source-syntax-error path start-line
                                                   "bit-vector literal length exceeds declared length ~A"
                                                   spelling))
                            (when (and (plusp (length digits))
                                       (decimal-token-at-least-p digits 2)
                                       (zerop (length bits)))
                              (source-syntax-error path start-line
                                                   "bit-vector literal requires bits for declared length ~A"
                                                   spelling))
                            (emit :literal (concatenate 'string spelling bits) start-line)))
                         ((#\B #\O #\X)
                          (when (plusp (length digits))
                            (source-syntax-error path start-line
                                                 "numeric argument is not permitted for reader dispatch ~A"
                                                 spelling))
                          (let* ((radix (case code (#\B 2) (#\O 8) (#\X 16)))
                                 (number (read-dispatch-body spelling start-line))
                                 (status (radix-rational-status number radix)))
                            (unless (eq status :valid)
                              (source-syntax-error path start-line
                                                   (if (eq status :zero-denominator)
                                                       "radix denominator is zero in ~A"
                                                       "invalid radix rational literal ~A")
                                                   (concatenate 'string spelling number)))
                            (emit :literal (concatenate 'string spelling number) start-line)))
                         (#\R
                          (let ((radix (and (plusp (length digits))
                                            (radix-value digits))))
                            (unless (and radix (<= 2 radix 36))
                              (source-syntax-error path start-line
                                                   "invalid radix dispatch syntax ~A"
                                                   spelling))
                            (let* ((number (read-dispatch-body spelling start-line))
                                   (status (radix-rational-status number radix)))
                              (unless (eq status :valid)
                                (source-syntax-error path start-line
                                                     (if (eq status :zero-denominator)
                                                         "radix denominator is zero in ~A"
                                                         "invalid radix rational literal ~A")
                                                     (concatenate 'string spelling number)))
                              (emit :literal (concatenate 'string spelling number) start-line))))
                         (#\A
                          (unless (plusp (length digits))
                            (source-syntax-error path start-line
                                                 "array reader dispatch requires a numeric rank ~A"
                                                 spelling))
                          (emit :dispatch-literal spelling start-line))
                         ((#\C #\P #\S)
                          (when (plusp (length digits))
                            (source-syntax-error path start-line
                                                 "numeric argument is not permitted for reader dispatch ~A"
                                                 spelling))
                          (emit :dispatch-literal spelling start-line))
                         ((#\= #\#)
                          (unless (plusp (length digits))
                            (source-syntax-error path start-line
                                                 "malformed reader label syntax ~A"
                                                 spelling))
                          (emit (if (char= code #\=) :label-definition :label-reference)
                                (canonical-label digits) start-line))
                         (#\.
                          (when (plusp (length digits))
                            (source-syntax-error path start-line
                                                 "numeric argument is not permitted for reader dispatch ~A"
                                                 spelling))
                          (emit :dispatch-literal spelling start-line))
                         (#\<
                          (source-syntax-error path start-line
                                               "unreadable reader syntax ~A" spelling))
                         (otherwise
                          (source-syntax-error path start-line
                                               "unsupported reader dispatch syntax ~A"
                                               spelling)))))))))
      (loop while (< position length)
            for character = (char text position)
            for token-line = line
            do (cond
                 ((find character '(#\Space #\Tab #\Newline #\Return #\Page))
                  (advance))
                 ((char= character #\;) (advance) (skip-line-comment))
                 ((and (char= character #\#) (eql (at 1) #\|)) (skip-block-comment))
                 ((char= character #\") (read-string-token))
                 ((char= character #\() (advance) (emit :open "(" token-line))
                 ((char= character #\)) (advance) (emit :close ")" token-line))
                 ((char= character #\') (advance) (emit :prefix "'" token-line))
                 ((char= character #\`) (advance) (emit :prefix "`" token-line))
                 ((char= character #\,)
                  (advance)
                  (if (and (< position length) (char= (char text position) #\@))
                      (progn (advance) (emit :prefix ",@" token-line))
                      (emit :prefix "," token-line)))
                 ((and (char= character #\#) (eql (at 1) #\\)) (read-character-token))
                 ((and (char= character #\#) (eql (at 1) #\:)) (read-atom))
                 ((and (char= character #\#) (eql (at 1) #\'))
                  (advance) (advance) (emit :prefix "#'" token-line))
                 ((and (char= character #\#) (member (at 1) '(#\+ #\-)))
                  (let ((prefix (coerce (list (advance) (advance)) 'string)))
                    (emit :conditional prefix token-line)))
                 ((and (char= character #\#) (eql (at 1) #\;))
                  (advance) (advance) (emit :discard "#;" token-line))
                 ((char= character #\#) (read-dispatch))
                 (t (read-atom))))
      (nreverse tokens))))
(defun parse-source-tokens (tokens path)
  (let ((remaining tokens)
        (defined-labels (make-hash-table :test #'equal)))
    (labels ((next-line ()
               (if remaining (lexeme-line (first remaining)) 1))
             (decimal-token-at-least-p (digits count)
               (let* ((normalized (string-left-trim "0" digits))
                      (normalized (if (plusp (length normalized)) normalized "0"))
                      (count-text (write-to-string count)))
                 (or (> (length normalized) (length count-text))
                     (and (= (length normalized) (length count-text))
                          (not (string< normalized count-text))))))
             (decimal-token-zero-p (digits)
               (every (lambda (character) (char= character #\0)) digits))
             (parse-one ()
               (unless remaining
                 (source-syntax-error path (next-line) "missing source form"))
               (let* ((token (pop remaining))
                      (kind (lexeme-kind token))
                      (line (lexeme-line token)))
                 (case kind
                   (:open (parse-delimited token :list))
                   (:vector-open (parse-delimited token :literal))
                   (:close
                    (source-syntax-error path line "unexpected closing parenthesis"))
                   (:prefix
                    (unless remaining
                      (source-syntax-error path line "missing form after reader prefix ~A"
                                           (lexeme-text token)))
                    (make-syntax-node :kind :prefix :value (lexeme-text token)
                                      :children (list (parse-one)) :line line))
                   (:conditional
                    (unless remaining
                      (source-syntax-error path line "missing feature expression after ~A"
                                           (lexeme-text token)))
                    (let ((feature-expression (parse-one)))
                      (unless remaining
                        (source-syntax-error path line "missing form after feature expression ~A"
                                             (lexeme-text token)))
                      (make-syntax-node :kind :conditional :value (lexeme-text token)
                                        :children (list feature-expression (parse-one))
                                        :line line)))
                   (:discard
                    (unless remaining
                      (source-syntax-error path line "missing form after reader comment #;"))
                    (make-syntax-node :kind :discard :children (list (parse-one)) :line line))
                   (:dispatch-literal
                    (unless remaining
                      (source-syntax-error path line "missing form after reader dispatch ~A"
                                           (lexeme-text token)))
                    (let* ((value (lexeme-text token))
                           (child (parse-one))
                           (dispatch (char-upcase (char value (1- (length value))))))
                      (labels
 ((ascii-digits-p (raw start end)
    (and (< start end)
         (loop for index from start below end
               always (<= (char-code #\0) (char-code (char raw index))
                          (char-code #\9)))))
  (canonical-decimal (digits)
    (let ((digits (string-left-trim "0" digits)))
      (if (plusp (length digits)) digits "0")))
  (one-p (digits) (string= (canonical-decimal digits) "1"))
  (decrement-decimal (digits)
    (let* ((copy (copy-seq (canonical-decimal digits)))
           (index (1- (length copy))))
      (loop while (char= (char copy index) #\0)
            do (setf (char copy index) #\9)
               (decf index))
      (setf (char copy index)
            (code-char (1- (char-code (char copy index)))))
      (canonical-decimal copy)))
  (real-token-p (raw)
    (let* ((length (length raw))
           (start (if (and (plusp length) (find (char raw 0) "+-")) 1 0)))
      (labels ((digits-p (from to) (ascii-digits-p raw from to))
               (marker-p (character) (find character "sSfFdDlLeE")))
        (and (< start length)
             (not (find (code-char 92) raw))
             (not (find (code-char 124) raw))
             (not (find (code-char 58) raw))
             (let ((slash (position #\/ raw :start start)))
               (if slash
                   (and (null (position #\/ raw :start (1+ slash)))
                        (null (position-if #'marker-p raw :start start))
                        (digits-p start slash)
                        (digits-p (1+ slash) length)
                        (loop for index from (1+ slash) below length
                              thereis (not (char= (char raw index) #\0))))
                   (let* ((marker (position-if #'marker-p raw :start start))
                          (end (or marker length))
                          (dot (position #\. raw :start start :end end)))
                     (and (or (null marker)
                              (let* ((exp-start (1+ marker))
                                     (exp-digits
                                       (if (and (< exp-start length)
                                                (find (char raw exp-start) "+-"))
                                           (1+ exp-start)
                                           exp-start)))
                                (digits-p exp-digits length)))
                          (if dot
                              (if marker
                                  (and (or (digits-p start dot) (digits-p (1+ dot) end)) (or (= (1+ dot) end) (digits-p (1+ dot) end)))
                                  (if (= dot (1- length))
                                      (digits-p start dot)
                                      (and (or (digits-p start dot) (= start dot))
                                           (digits-p (1+ dot) length))))
                              (digits-p start end))))))))))
  (label-reference-p (value)
    (and (> (length value) 2)
         (char= (char value 0) #\#)
         (char= (char value (1- (length value))) #\#)
         (ascii-digits-p value 1 (1- (length value)))))
  (radix-number-p (value)
    (and (> (length value) 2)
         (char= (char value 0) #\#)
         (or (find (char-upcase (char value 1)) "BOX")
             (let ((index 1))
               (loop while (and (< index (length value))
                                (<= (char-code #\0) (char-code (char value index))
                                    (char-code #\9)))
                     do (incf index))
               (and (> index 1)
                    (< index (length value))
                    (char-equal (char value index) #\R))))))
  (real-status (node)
    (case (syntax-node-kind node)
      (:atom (if (real-token-p (syntax-node-value node)) :real :not-real))
      (:literal
       (let ((value (syntax-node-value node)))
         (cond
           ((radix-number-p value) :real)
           ((starts-with value "#\\") :not-real)
           ((member (string-upcase value) (list "#P" "#A" "#S") :test (function string=))
            :not-real)
           ((and (> (length value) 1)
                 (char= (char value 0) #\#)
                 (char= (char value (1- (length value))) #\()
                 (every (lambda (character) (ascii-digit-p character))
                        (subseq value 1 (1- (length value)))))
            :not-real)
           ((let ((star (position #\* value :start 1)))
              (and star
                   (char= (char value 0) #\#)
                   (every (lambda (character) (ascii-digit-p character))
                          (subseq value 1 star))))
            :not-real)
           ((and (> (length value) 2)
                 (char= (char value 0) #\#)
                 (ascii-digits-p value 1 (1- (length value)))
                 (char-equal (char value (1- (length value))) #\A))
            :not-real)
           (t :unknown))))
      (:prefix
       (let ((value (syntax-node-value node)))
         (if (and (> (length value) 2)
                  (char= (char value 0) #\#)
                  (char= (char value (1- (length value))) #\=)
                  (ascii-digits-p value 1 (1- (length value))))
             (real-status (first (syntax-node-children node)))
             :not-real)))
      (:conditional :unknown)
      (otherwise :not-real)))
  (symbol-status (node)
    (case (syntax-node-kind node)
      (:atom (if (real-token-p (syntax-node-value node)) :not-symbol :symbol))
      (:prefix
       (let ((value (syntax-node-value node)))
         (if (and (> (length value) 2)
                  (char= (char value 0) #\#)
                  (char= (char value (1- (length value))) #\=)
                  (ascii-digits-p value 1 (1- (length value))))
             (symbol-status (first (syntax-node-children node)))
             :unknown)))
      (:literal
       (let ((value (syntax-node-value node)))
         (if (or (string= value "#.") (label-reference-p value))
             :unknown
             :not-symbol)))
      (:conditional :unknown)
      (otherwise :not-symbol)))
  (slot-status (node)
    (case (syntax-node-kind node)
      (:string :valid)
      (:atom (if (real-token-p (syntax-node-value node)) :invalid :valid))
      (:prefix
       (let ((value (syntax-node-value node)))
         (if (and (> (length value) 2)
                  (char= (char value 0) #\#)
                  (char= (char value (1- (length value))) #\=)
                  (ascii-digits-p value 1 (1- (length value))))
             (slot-status (first (syntax-node-children node)))
             :unknown)))
      (:literal
       (let ((value (syntax-node-value node)))
         (cond ((and (> (length value) 2)
                     (char= (char value 0) #\#)
                     (char= (char value 1) (code-char 92)))
                :valid)
               ((or (string= value "#.") (label-reference-p value)) :unknown)
               (t :invalid))))
      (:conditional :unknown)
      (otherwise :invalid)))
  (proper-list-info (node)
    (case (syntax-node-kind node)
      (:list
       (values :known (length (syntax-node-children node))
               (syntax-node-children node)))
      (:dotted-list
       (let* ((children (syntax-node-children node))
              (prefix (butlast children))
              (tail (car (last children))))
         (multiple-value-bind (status tail-length tail-contents)
             (proper-list-info tail)
           (case status
             (:known
              (values :known (+ (length prefix) tail-length)
                      (append prefix tail-contents)))
             (:unknown (values :unknown nil nil))
             (otherwise (values :nonsequence nil nil))))))
      (:atom
       (if (string= (reader-name (syntax-node-value node)) "nil")
           (values :unknown nil nil)
           (values :nonsequence nil nil)))
      (:conditional (values :unknown nil nil))
      (:prefix (values :unknown nil nil))
      (:literal
       (let ((value (syntax-node-value node)))
         (if (or (string= value "#.") (label-reference-p value))
             (values :unknown nil nil)
             (values :nonsequence nil nil))))
      (otherwise (values :nonsequence nil nil))))
  (sequence-info (node)
    (case (syntax-node-kind node)
      (:list
       (values :known (write-to-string (length (syntax-node-children node)))
               (syntax-node-children node)))
      (:dotted-list
       (multiple-value-bind (status count contents)
           (proper-list-info node)
         (values status (and count (write-to-string count)) contents)))
      (:atom
       (if (string= (reader-name (syntax-node-value node)) "nil")
           (values :unknown nil nil)
           (values :nonsequence nil nil)))
      (:conditional (values :unknown nil nil))
      (:string (values :unknown nil nil))
      (:literal
       (let* ((value (syntax-node-value node))
              (length (length value)))
         (cond
           ((and (> length 1)
                 (char= (char value 0) #\#)
                 (char= (char value (1- length)) (code-char 40)))
            (let ((digits (subseq value 1 (1- length))))
              (values :known
                      (if (plusp (length digits))
                          (canonical-decimal digits)
                          (write-to-string (length (syntax-node-children node))))
                      (syntax-node-children node))))
           ((or (string= value "#.")
                (label-reference-p value)
                (and (char= (char value 0) #\#)
                     (or (char-equal (char value (1- length)) #\A)
                         (let ((star (position #\* value :start 1)))
                           (and star
                                (or (= star 1)
                                    (ascii-digits-p value 1 star)))))))
            (values :unknown nil nil))
           (t (values :nonsequence nil nil)))))
      (otherwise (values :nonsequence nil nil)))) (array-shape (node rank)
    (let ((kind (syntax-node-kind node))
          (value (syntax-node-value node)))
      (cond
        ((string= (canonical-decimal rank) "0") (values :valid nil))
        ((and (eq kind :prefix)
              (> (length value) 2)
              (char= (char value 0) #\#)
              (char= (char value (1- (length value))) #\=)
              (ascii-digits-p value 1 (1- (length value))))
         (array-shape (first (syntax-node-children node)) rank))
        ((and (eq kind :literal) (string= value "#."))
         (values :unknown nil))
        ((eq kind :conditional) (values :unknown nil))
        (t
         (multiple-value-bind (sequence-status length children)
             (sequence-info node)
           (case sequence-status
             (:unknown (values :unknown nil))
             (:nonsequence (values :not-sequence nil))
             (:known
              (cond
                ((string= length "0") (values :valid (list "0")))
                ((one-p rank) (values :valid (list length)))
                (t
                 (let* ((next-rank (decrement-decimal rank))
                        (child-shapes
                          (mapcar (lambda (child)
                                    (multiple-value-list (array-shape child next-rank)))
                                  children)))
                   (cond
                     ((some (lambda (item)
                              (eq (first item) :inconsistent-dimensions))
                            child-shapes)
                      (values :inconsistent-dimensions nil))
                     ((some (lambda (item)
                              (member (first item) '(:not-sequence :rank-mismatch)))
                            child-shapes)
                      (values :rank-mismatch nil))
                     ((some (lambda (item) (eq (first item) :unknown)) child-shapes)
                      (values :unknown nil))
                     ((null child-shapes) (values :unknown nil))
                     ((not (every (lambda (item)
                                    (equal (second item) (second (first child-shapes))))
                                  (rest child-shapes)))
                      (values :inconsistent-dimensions nil))
                     (t (values :valid
                                (cons length (second (first child-shapes))))))))))))))))
 ) (case dispatch
   (#\A
    (let ((rank (subseq value 1 (1- (length value)))))
      (multiple-value-bind (status shape) (array-shape child rank)
        (declare (ignore shape))
        (case status
          (:not-sequence
           (source-syntax-error path line
                                "array reader dispatch requires sequence data ~A" value))
          (:inconsistent-dimensions
           (source-syntax-error path line
                                "array reader dispatch contents have inconsistent dimensions ~A"
                                value))
          (:rank-mismatch
           (source-syntax-error path line
                                "array reader dispatch contents do not match rank ~A" value)))))) (#\C
    (unless (and (eq (syntax-node-kind child) :list)
                 (= (length (syntax-node-children child)) 2))
      (source-syntax-error path line
                           "complex reader dispatch requires two data forms ~A" value))
    (when (some (lambda (component)
                  (eq (real-status component) :not-real))
                (syntax-node-children child))
      (source-syntax-error path line
                           "complex reader dispatch requires real components ~A" value))) (#\P
    (unless (eq (syntax-node-kind child) :string)
      (source-syntax-error path line
                           "pathname reader dispatch requires a string ~A" value))) (#\S
    (unless (eq (syntax-node-kind child) :list)
      (source-syntax-error path line
                           "structure reader dispatch requires a list ~A" value))
    (let ((children (syntax-node-children child)))
      (unless (and children
                   (not (eq (symbol-status (first children)) :not-symbol)))
        (source-syntax-error path line
                             "structure reader dispatch requires a symbol name ~A" value))
      (unless (evenp (1- (length children)))
        (source-syntax-error path line
                             "structure reader dispatch requires a name and slot/value pairs ~A"
                             value))
      (loop for slots on (rest children) by #'cddr
            when (eq (slot-status (first slots)) :invalid)
              do (source-syntax-error path line
                                      "structure reader dispatch requires string-designator slot names ~A"
                                      value))))
)
)
                      (make-syntax-node :kind :literal :value value
                                        :children (list child) :line line)))
                   (:label-definition
                     (let ((label (lexeme-text token)))
                       (when (gethash label defined-labels)
                         (source-syntax-error path line "duplicate reader label #~A=" label))
                       (loop while (and remaining
                                        (eq (lexeme-kind (first remaining)) :discard))
                             do (parse-one))
                       (unless remaining
                         (source-syntax-error path line "missing form after reader label #~A=" label))
                       (when (and (eq (lexeme-kind (first remaining)) :label-reference)
                                  (string= label (lexeme-text (first remaining))))
                         (source-syntax-error path line
                                              "reader label reference cannot be the labeled object #~A#"
                                              label))
                       (setf (gethash label defined-labels) t)
                       (make-syntax-node
                        :kind :prefix :value (concatenate (quote string) "#" label "=")
                        :children (list (parse-one)) :line line)))
                   (:label-reference
                    (let ((label (lexeme-text token)))
                      (unless (gethash label defined-labels)
                        (source-syntax-error path line "undefined reader label #~A#" label))
                      (make-syntax-node :kind :literal :value (concatenate 'string "#" label "#")
                                        :line line)))
                   (:atom
                    (make-syntax-node :kind :atom :value (lexeme-text token) :line line))
                   (:string
                    (make-syntax-node :kind :string :value (lexeme-text token) :line line))
                   (:literal
                    (make-syntax-node :kind :literal :value (lexeme-text token) :line line))
                   (otherwise
                    (source-syntax-error path line "unsupported token kind ~S" kind)))))
             (parse-delimited (token node-kind)
               (let ((children nil)
                     (line (lexeme-line token))
                     (dotted-p nil)
                     (tail nil))
                 (loop
                   (when (null remaining)
                     (source-syntax-error path line
                                          (if (eq node-kind :literal)
                                              "unterminated vector literal"
                                              "unterminated list")))
                   (when (eq (lexeme-kind (first remaining)) :close)
                     (pop remaining)
                     (return))
                   (when (and (eq node-kind :list)
                              (eq (lexeme-kind (first remaining)) :atom)
                              (string= (lexeme-text (first remaining)) "."))
                     (let ((dot-line (lexeme-line (pop remaining))))
                       (unless children
                         (source-syntax-error path dot-line
                                              "dotted list requires a preceding object"))
                       (loop while (and remaining
                                        (eq (lexeme-kind (first remaining)) :discard))
                             do (parse-one))
                       (when (or (null remaining)
                                 (eq (lexeme-kind (first remaining)) :close))
                         (source-syntax-error path dot-line
                                              "dotted list requires one tail object"))
                       (loop
                         (let ((child (parse-one)))
                           (unless (eq (syntax-node-kind child) :discard)
                             (when (and (eq (syntax-node-kind child) :atom)
                                        (string= (syntax-node-value child) "."))
                               (source-syntax-error path dot-line
                                                    "invalid dotted list tail"))
                             (setf tail child)
                             (return))))
                       (loop while (and remaining
                                        (eq (lexeme-kind (first remaining)) :discard))
                             do (parse-one))
                       (unless (and remaining
                                    (eq (lexeme-kind (first remaining)) :close))
                         (source-syntax-error path dot-line
                                              "dotted list must end after one tail object"))
                       (pop remaining)
                       (setf dotted-p t))
                     (return))
                   (let ((child (parse-one)))
                     (unless (eq (syntax-node-kind child) :discard)
                       (push child children))))
                 (let* ((children (nreverse children))
                        (contents (if dotted-p (append children (list tail)) children))
                        (value (when (eq node-kind :literal) (lexeme-text token)))
                        (digits (when value
                                  (subseq value 1 (1- (length value))))))
                   (when (and digits (plusp (length digits)))
                     (unless (decimal-token-at-least-p digits (length contents))
                       (source-syntax-error path line
                                            "vector literal exceeds declared length ~A"
                                            value))
                     (when (and (zerop (length contents))
                                (not (decimal-token-zero-p digits)))
                       (source-syntax-error path line
                                            "nonempty vector literal required for declared length ~A"
                                            value)))
                   (make-syntax-node :kind (if dotted-p :dotted-list node-kind)
                                     :value value :children contents :line line))))
             (parse-list ()
               (loop while remaining
                     collect (progn
                               (setf defined-labels (make-hash-table :test #'equal))
                               (parse-one)))))
      (parse-list))))
(defun reader-name (raw)
  (let ((raw (if (starts-with raw "#:") (subseq raw 2) raw))
        (in-bars nil)
        (escaped nil)
        (output (make-string-output-stream)))
    (loop for character across raw
          do (cond
               (escaped (write-char character output) (setf escaped nil))
               ((char= character #\\) (setf escaped t))
               ((char= character #\|) (setf in-bars (not in-bars)))
               (in-bars (write-char character output))
               (t (write-char (char-downcase character) output))))
    (get-output-stream-string output)))
(defun atom-name (node)
  (when (and node (eq (syntax-node-kind node) :atom))
    (reader-name (syntax-node-value node))))
(defun node-designator (node)
  (case (syntax-node-kind node)
    (:string
     (handler-case
         (let ((*read-eval* nil))
           (string-downcase (read-from-string (syntax-node-value node))))
       (error () (fail-closed "invalid string literal at line ~D" (syntax-node-line node)))))
    (:atom
     (let ((name (reader-name (syntax-node-value node))))
       (if (starts-with name ":")
           (subseq name 1)
           name)))
    (otherwise nil)))
(defun list-op-name (node)
  (when (and (eq (syntax-node-kind node) :list) (syntax-node-children node))
    (atom-name (first (syntax-node-children node)))))
(defun keyword-name (node)
  (let ((name (atom-name node)))
    (when (and name (starts-with (syntax-node-value node) ":"))
      name)))
(defun find-forms (forms names)
  (let ((found nil))
    (labels ((walk (node quoted-p)
               (case (syntax-node-kind node)
                 (:list
                  (let* ((operator (list-op-name node))
                         (children (syntax-node-children node)))
                    (unless (or (member operator (list "quote" "function") :test (function string=))
                                (eq (syntax-node-kind node) :discard))
                      (dolist (child children)
                        (walk child quoted-p)))
                    (when (and (not quoted-p) (member operator names :test (function string=)))
                      (push node found))))
                 (:dotted-list
                  (dolist (child (syntax-node-children node))
                    (walk child quoted-p)))
                 (:prefix
                  (if (member (syntax-node-value node) '("'" "#'") :test #'string=)
                      (walk (first (syntax-node-children node)) t)
                      (walk (first (syntax-node-children node)) quoted-p)))
                 (:conditional
                  (when (second (syntax-node-children node))
                    (walk (second (syntax-node-children node)) quoted-p))))))
      (dolist (form forms) (walk form nil))
      (nreverse found))))
(defun package-reference-from-atom (raw path line)
  (let ((in-bars nil)
        (escaped nil)
        (separators nil)
        (uninterned-p (starts-with raw "#:")))
    (loop for index from (if uninterned-p 2 0) below (length raw)
          for character = (char raw index)
          do (cond
               (escaped (setf escaped nil))
               ((char= character #\\) (setf escaped t))
               ((char= character #\|) (setf in-bars (not in-bars)))
               ((and (not in-bars) (char= character #\:))
                (push index separators))))
    (setf separators (nreverse separators))
    (cond
      (uninterned-p
       (when separators
         (source-syntax-error path line
                              "uninterned symbol must not contain a package marker ~A"
                              raw)))
      ((null separators) nil)
      ((and (= (length separators) 1)
            (= (first separators) 0))
       (when (= (length raw) 1)
         (source-syntax-error path line "malformed package marker pattern ~A" raw)))
      ((and (= (length separators) 1)
            (> (first separators) 0)
            (< (first separators) (1- (length raw))))
       (let ((separator (first separators)))
         (make-package-reference :package (reader-name (subseq raw 0 separator))
                                 :symbol (reader-name (subseq raw (1+ separator)))
                                 :internal-p nil :line line)))
      ((and (= (length separators) 2)
            (> (first separators) 0)
            (= (second separators) (1+ (first separators)))
            (< (second separators) (1- (length raw))))
       (let ((symbol-start (1+ (second separators))))
         (make-package-reference :package (reader-name (subseq raw 0 (first separators)))
                                 :symbol (reader-name (subseq raw symbol-start))
                                 :internal-p t :line line)))
      (t
       (source-syntax-error path line "malformed package marker pattern ~A" raw)))))
(defun package-references-in-node (node path)
  (let ((references nil))
    (labels ((walk (current)
               (case (syntax-node-kind current)
                 (:atom
                  (let ((reference (package-reference-from-atom
                                    (syntax-node-value current)
                                    path
                                    (syntax-node-line current))))
                    (when reference (push reference references))))
                 ((:list :dotted-list)
                  (dolist (child (syntax-node-children current)) (walk child)))
                 (:prefix (walk (first (syntax-node-children current))))
                 (:conditional
                  (when (second (syntax-node-children current))
                    (walk (second (syntax-node-children current)))))
                 (:discard nil)
                 (otherwise nil))))
      (walk node))
    (nreverse references)))
(defun path-under-p (file directory)
  (or (string= file directory)
      (and (starts-with file directory)
           (< (length directory) (length file))
           (char= (char file (length directory)) #\/))))
(defun path-parent (path)
  (let ((position (position #\/ path :from-end t)))
    (if position (subseq path 0 position) "")))
(defun path-base (path)
  (let ((position (position #\/ path :from-end t)))
    (subseq path (if position (1+ position) 0))))
(defun ascii-digit-p (character)
  (and character (char<= #\0 character #\9)))
(defun token-parts (string)
  (let ((start nil)
        (parts nil))
    (loop for index from 0 to (length string)
          for character = (and (< index (length string)) (char string index))
          do (if (and character (or (alphanumericp character) (char= character #\_)))
                 (unless start (setf start index))
                 (when start
                   (push (subseq string start index) parts)
                   (setf start nil))))
    (nreverse parts)))
(defun forbidden-name-p (name forbidden)
  (let ((parts (mapcar #'string-downcase (token-parts name))))
    (some (lambda (candidate)
            (member (string-downcase candidate) parts :test #'string=))
          forbidden)))
(defun numbered-name-p (name prefixes)
  (let ((down (string-downcase name)))
    (some
     (lambda (prefix)
       (let ((prefix (string-downcase prefix))
             (start 0))
         (loop for index = (search prefix down :start2 start)
               while index
               for previous = (when (> index 0) (char down (1- index)))
               for digit-start = (+ index (length prefix))
               for after-digits = (loop for cursor from digit-start below (length down)
                                        while (ascii-digit-p (char down cursor))
                                        finally (return cursor))
               for next = (when (< after-digits (length down))
                            (char down after-digits))
               do (when (and (or (null previous)
                                 (not (or (alphanumericp previous) (char= previous #\_))))
                             (> after-digits digit-start)
                             (or (null next)
                                 (not (or (alphanumericp next) (char= next #\_)))))
                    (return-from numbered-name-p t))
                  (setf start (1+ index)))))
     prefixes)))
(defun feature-for-path (path features)
  (let ((matches nil))
    (dolist (feature features)
      (dolist (directory (append (feature-source-dirs feature)
                                 (list (feature-test-dir feature))))
        (when (path-under-p path (normalize-path-string directory))
          (push (cons (length directory) feature) matches))))
    (when matches (cdr (car (sort matches #'> :key #'car))))))
(defun feature-test-package (feature) (concatenate 'string (feature-domain-package feature) "/test"))
(defun package-layer (package-info)
  (and package-info (package-info-layer package-info)))
(defun report-main (status)
  (dolist (message (nreverse *violations*))
    (format *error-output* "~A~%" message))
  (sb-ext:exit :code status))
(defun make-feature-record (plist)
  (unless (safe-plist-p plist)
    (fail-closed "feature entry must be a keyword plist, got ~S" plist))
  (let* ((slug (normalize-name (require-string (plist-value plist :feature) ":feature")))
         (source-dirs (mapcar #'normalize-path-string
                              (require-string-list (plist-value plist :source-dirs) ":source-dirs")))
         (test-dir (normalize-path-string
                    (require-string (plist-value plist :test-dir) ":test-dir")))
         (facades (mapcar #'normalize-name
                          (require-string-list (plist-value plist :facade-packages) ":facade-packages")))
         (domain (normalize-name
                  (require-string (plist-value plist :domain-package) ":domain-package")))
         (infra-value (plist-value plist :infra-package))
         (infra (and infra-value
                     (normalize-name (require-string infra-value ":infra-package"))))
         (depends (mapcar #'normalize-name
                          (require-string-list (plist-value plist :depends-on) ":depends-on"))))
    (unless (and (plusp (length slug)) source-dirs (plusp (length test-dir)))
      (fail-closed "feature entry has an empty slug or directory: ~S" plist))
    (dolist (path (append source-dirs (list test-dir))) (safe-relative-path path))
    (make-feature :slug slug :source-dirs source-dirs :test-dir test-dir
                  :facade-packages facades :domain-package domain
                  :infra-package infra :depends-on depends)))
(defun feature-entries (value)
  (unless (and (listp value)
               (every (lambda (entry)
                        (and (listp entry) (eq (first entry) :feature)))
                      value))
    (fail-closed "feature definitions must be a list of :feature plists"))
  (mapcar #'make-feature-record value))
(defun glossary-fields (text prefix)
  (let ((entries (make-hash-table :test #'equal))
        (current nil))
    (with-input-from-string (stream text)
      (loop for line = (read-line stream nil nil)
            while line
            do (if (starts-with line prefix)
                   (let ((slug (normalize-name (trim-space (subseq line (length prefix))))))
                     (when (zerop (length slug)) (fail-closed "empty glossary heading"))
                     (when (gethash slug entries)
                       (violation "01" "glossary heading ~A appears more than once" slug))
                     (setf current (make-hash-table :test #'equal)
                           (gethash slug entries) current))
                   (when current
                     (dolist (field '("Package" "Key types" "Key functions"))
                       (let ((marker (concatenate 'string "- " field ":")))
                         (when (starts-with line marker)
                           (setf (gethash field current)
                                 (trim-space (subseq line (length marker)))))))))))
    entries))
(defun markdown-value (value)
  (let ((trimmed (trim-space value)))
    (if (and (>= (length trimmed) 2)
             (char= (char trimmed 0) #\`)
             (char= (char trimmed (1- (length trimmed))) #\`))
        (subseq trimmed 1 (1- (length trimmed)))
        trimmed)))
(defun glossary-list-values (value)
  (let* ((value (trim-space value))
         (whole-span-p
           (and (> (length value) 1)
                (char= (char value 0) #\`)
                (char= (char value (1- (length value))) #\`)
                (not (position #\` value
                               :start 1
                               :end (1- (length value))))))
         (value (if whole-span-p
                    (subseq value 1 (1- (length value)))
                    value)))
    (if (string-equal value "None.")
        nil
        (remove ""
                (mapcar (function markdown-value)
                        (uiop:split-string value :separator ","))
                :test (function string=)))))
(defun plist-items (plist key)
  (let ((value (plist-value plist key)))
    (unless (listp value)
      (fail-closed "~S option must contain a list" key))
    value))
(defun string-designator-name (value context)
  (cond
    ((stringp value) (normalize-name value))
    ((symbolp value) (normalize-name (symbol-name value)))
    (t (fail-closed "~A must be a symbol or string, got ~S" context value))))
(defun normalize-symbol-name (value)
  (cond
    ((stringp value) (normalize-name value))
    ((symbolp value) (normalize-name (symbol-name value)))
    (t (fail-closed "expected symbol name, got ~S" value))))
(defun parse-legacy-allowlist (root path)
  (if (null path)
      (make-hash-table :test #'equal)
      (let* ((file (resolve-path root path))
             (entries (read-safe-one file))
             (table (make-hash-table :test #'equal)))
        (unless (listp entries) (fail-closed "legacy internal reference list must be a list"))
        (dolist (entry entries)
          (unless (and (listp entry) (= (length entry) 5)
                       (eq (first entry) :ref)
                       (stringp (second entry)) (stringp (third entry))
                       (stringp (fourth entry)) (integerp (fifth entry)))
            (fail-closed "invalid legacy internal reference entry ~S" entry))
          (let* ((relative (safe-relative-path (second entry)))
                 (package (normalize-name (third entry)))
                 (symbol (normalize-name (fourth entry)))
                 (count (fifth entry))
                 (key (list (normalize-path-string relative) package symbol)))
            (unless (> count 0)
              (fail-closed "legacy reference entry needs path, package, symbol, and positive count: ~S" entry))
            (when (gethash key table)
              (fail-closed "duplicate legacy reference entry ~S" entry))
            (setf (gethash key table) count)))
        table)))
(defun parse-export-surface (root path)
  (let ((form (read-safe-one (resolve-path root path)))
        (exports (make-hash-table :test (function equal))))
    (unless (listp form)
      (fail-closed "export surface must be a list"))
    (dolist (entry form)
      (unless (and (listp entry) (eq (first entry) :symbol))
        (fail-closed "unsupported export surface entry ~S" entry))
      (let* ((change (second entry))
             (expected-length (if (eq change :keep) 6 7)))
        (unless (member change (list :keep :add :remove))
          (fail-closed "unsupported export change ~S" change))
        (unless (= (length entry) expected-length)
          (fail-closed "export surface ~S entry must have ~D fields: ~S"
                       change expected-length entry))
        (require-string (third entry) "export facade package")
        (let ((feature-package
                (normalize-name (require-string (fourth entry) "export feature package")))
              (symbol (normalize-name (require-string (sixth entry) "export symbol"))))
          (require-string (fifth entry) "expected export home package")
          (unless (eq change :keep)
            (let ((reference (require-string (seventh entry) "export change reference")))
              (unless (and (starts-with reference "CHANGELOG.md#") (> (length reference) 13))
                (fail-closed "export change reference must name a CHANGELOG.md anchor: ~S"
                             reference))))
          (when (member change (list :keep :add))
            (push symbol (gethash feature-package exports)))))) exports))
(defun scan-feature-files (root features)
  (let ((file-paths nil)
        (records nil)
        (packages (make-hash-table :test #'equal))
        (source-files nil))
    (labels ((proper-list-length (value)
               (ignore-errors (list-length value)))
             (project-relative-path (path)
               (handler-case
                   (let ((relative (relative-pathname root (truename path))))
                     (if (string= relative "")
                         ""
                         (safe-relative-path relative)))
                 (error () nil)))
             (asdf-files ()
               (let ((files nil)
                     (visited nil))
                 (labels ((walk (directory)
                            (let ((relative (project-relative-path directory)))
                              (when (and relative
                                         (not (member relative visited :test #'string=)))
                                (push relative visited)
                                (dolist (file (uiop:directory-files directory))
                                  (when (and (pathname-type file)
                                             (string-equal (pathname-type file) "asd")
                                             (project-relative-path file))
                                    (push file files)))
                                (dolist (subdirectory (uiop:subdirectories directory))
                                  (let* ((parts (pathname-directory subdirectory))
                                         (name (and parts (car (last parts)))))
                                    (unless (member name '(".git" ".jj" ".hg" ".svn")
                                                    :test #'string-equal)
                                      (walk subdirectory))))))))
                   (walk (uiop:ensure-directory-pathname root))
                 (nreverse files))))
             (asdf-option (options key context)
                          (let ((length (proper-list-length options))
                                (found-p nil)
                                (found-value nil))
                            (unless (and length (evenp length))
                              (fail-closed "~A has malformed ASDF options" context))
                            (loop for tail on options by #'cddr
                                  for candidate = (car tail)
                                  do (unless (keywordp candidate)
                                       (fail-closed "~A has a non-keyword ASDF option ~S"
                                                    context candidate))
                                  (when (eq candidate key)
                                    (when found-p
                                      (fail-closed "~A repeats ASDF option ~S" context key))
                                    (setf found-p t
                                          found-value (cadr tail))))
                            (values found-value found-p)))
             (static-pathname (parent specifier kind file-type context)
                              (let* ((pathname
                                      (cond
                                       ((pathnamep specifier) specifier)
                                       ((or (stringp specifier) (symbolp specifier))
                                        (uiop:parse-unix-namestring
                                         (if (symbolp specifier)
                                             (string-downcase (symbol-name specifier))
                                           specifier)
                                         :type (if (eq kind :module) :directory file-type)))
                                       (t
                                        (fail-closed "~A has a nonliteral ASDF pathname ~S"
                                                     context specifier))))
                                     (merged (uiop:merge-pathnames* pathname parent)))
                                (if (eq kind :module)
                                    (uiop:ensure-directory-pathname merged)
                                  merged)))
             (component-pathname (parent component kind file-type context)
                                 (multiple-value-bind (pathname pathname-p)
                                     (asdf-option (cddr component) :pathname context)
                                   (static-pathname parent
                                                    (if pathname-p pathname (second component))
                                                    kind file-type context)))
             (component-type-info (type default-class context)
                                  (unless (symbolp type)
                                    (fail-closed "~A has a non-symbol ASDF component type ~S"
                                                 context type))
                                  (labels ((source-type (class role)
                                             (unless (symbolp class)
                                               (fail-closed "~A has a nonliteral ASDF ~A ~S"
                                                            context role class))
                                             (let ((name (string-downcase (symbol-name class))))
                                               (cond
                                                 ((string= name "static-file")
                                                  (values :static-file nil))
                                                 ((string= name "cl-source-file")
                                                  (values :source "lisp"))
                                                 ((starts-with name "cl-source-file.")
                                                  (let ((file-type
                                                          (subseq name
                                                                  (length "cl-source-file."))))
                                                    (unless (plusp (length file-type))
                                                      (fail-closed
                                                       "~A has an empty ASDF source pathname type"
                                                       context))
                                                    (values :source file-type)))
                                                 (t
                                                  (fail-closed
                                                   "[feature-lint:unverified] ~A cannot classify ASDF ~A ~S"
                                                   context role class))))))
                                    (let ((name (string-downcase (symbol-name type))))
                                      (cond
                                        ((string= name "module")
                                         (values :module nil))
                                        ((string= name "static-file")
                                         (values :static-file nil))
                                        ((string= name "file")
                                         (if default-class
                                             (source-type default-class
                                                          "default component class")
                                             (values :source "lisp")))
                                        ((or (string= name "cl-source-file")
                                             (starts-with name "cl-source-file."))
                                         (source-type type "component type"))
                                        (t
                                         (fail-closed
                                          "[feature-lint:unverified] ~A uses unrecognized ASDF component type ~S; source behavior cannot be determined statically"
                                          context type))))))
             (collect-component-paths (components parent default-class context)
                                      (let ((length (proper-list-length components))
                                            (paths nil))
                                        (unless length
                                          (fail-closed "~A has nonliteral ASDF :components" context))
                                        (dolist (component components)
                                          (let ((component-length (proper-list-length component)))
                                            (unless (and component-length (>= component-length 2)
                                                         (symbolp (first component)))
                                              (fail-closed "~A has malformed ASDF component ~S"
                                                           context component))
                                            (multiple-value-bind (kind file-type)
                                                (component-type-info (first component) default-class context)
                                              (let ((path (component-pathname parent component kind file-type context)))
                                                (setf paths
                                                      (nconc paths
                                                             (case kind
                                                               (:module
                                                                (multiple-value-bind (children children-p)
                                                                    (asdf-option (cddr component) :components context)
                                                                  (multiple-value-bind (module-class module-class-p)
                                                                      (asdf-option (cddr component)
                                                                                   :default-component-class context)
                                                                    (if children-p
                                                                        (collect-component-paths
                                                                         children path
                                                                         (if module-class-p module-class default-class)
                                                                         context)
                                                                      nil))))
                                                               (:source (list path))
                                                               (:static-file nil))))))))
                                        paths))
             (component-relative-path (path context)
                                 (unless (probe-file path)
                                   (fail-closed "~A declares missing ASDF source component ~A"
                                                context path))
                                 (let ((relative (project-relative-path path)))
                                   (unless relative
                                     (fail-closed
                                      "[feature-lint:unverified] ~A ASDF source component is outside the project root: ~A"
                                      context path))
                                   relative))
             (record-facades-from-file (relative facade-packages owned-paths)
               (unless (member relative owned-paths :test #'string=)
                 (let* ((path (resolve-path root relative))
                        (forms (handler-case
                                   (parse-source-tokens
                                    (scan-source (uiop:read-file-string path) relative)
                                    relative)
                                 (error (condition)
                                   (fail-closed "source syntax error: ~A" condition))))
                        (defs (find-forms forms '("defpackage"))))
                   (dolist (form defs)
                     (let* ((children (syntax-node-children form))
                            (package (and (second children)
                                          (node-designator (second children)))))
                       (unless package
                         (source-syntax-error relative (syntax-node-line form)
                                              "defpackage has no literal package name"))
                       (when (member package facade-packages :test #'string=)
                         (register-package-form form relative packages package)))))))
             (scan-asdf-facades (facade-packages owned-paths)
                                (dolist (asd-file (asdf-files))
                                  (let* ((context (or (project-relative-path asd-file)
                                                      (namestring asd-file)))
                                         (forms (handler-case
                                                    (read-safe-forms asd-file)
                                                  (error (condition)
                                                         (fail-closed "ASDF syntax error in ~A: ~A"
                                                                      context condition)))))
                                    (dolist (form forms)
                                      (when (and (consp form)
                                                 (symbolp (first form))
                                                 (string-equal (symbol-name (first form)) "DEFSYSTEM"))
                                        (let ((form-length (proper-list-length form)))
                                          (unless (and form-length (>= form-length 2))
                                            (fail-closed "~A has malformed ASDF defsystem form ~S"
                                                         context form))
                                          (unless (or (stringp (second form)) (symbolp (second form)))
                                            (fail-closed "~A has nonliteral ASDF system designator ~S"
                                                         context (second form)))
                                          (let* ((options (cddr form))
                                                 (system-base (uiop:pathname-directory-pathname asd-file)))
                                            (multiple-value-bind (pathname pathname-p)
                                                (asdf-option options :pathname context)
                                              (when pathname-p
                                                (setf system-base
                                                      (static-pathname system-base pathname :module nil context))))
                                            (multiple-value-bind (default-class default-class-p)
                                                (asdf-option options :default-component-class context)
                                              (when default-class-p
                                                (unless (symbolp default-class)
                                                  (fail-closed "~A has nonliteral :default-component-class ~S"
                                                               context default-class)))
                                              (multiple-value-bind (components components-p)
                                                  (asdf-option options :components context)
                                                (when components-p
                                                  (dolist (path
                                                           (collect-component-paths
                                                            components system-base
                                                            (if default-class-p default-class nil) context))
                                                    (let ((relative (component-relative-path path context)))
                                                      (when relative
                                                        (record-facades-from-file relative
                                                                                  facade-packages
                                                                                  owned-paths)))))))))))))))
      (dolist (feature features)
        (dolist (relative (feature-source-dirs feature))
          (let ((directory (resolve-path root relative)))
            (unless (uiop:directory-exists-p directory)
              (violation "01" "source directory ~A does not exist" relative))
            (when (uiop:directory-exists-p directory)
              (dolist (file (recursive-files directory))
                (when (lisp-file-p file)
                  (push (cons (relative-pathname root file) feature) source-files))))))
        (let ((test-path (feature-test-dir feature)))
          (let ((directory (resolve-path root test-path)))
            (unless (uiop:directory-exists-p directory)
              (violation "01" "feature test directory ~A does not exist" test-path))
            (when (uiop:directory-exists-p directory)
              (let ((tests (remove-if-not #'lisp-file-p (recursive-files directory))))
                (when (null tests)
                  (violation "01" "feature test directory ~A has no .lisp files"
                             test-path)))))))
      (setf source-files (nreverse source-files))
      (dolist (feature features)
        (dolist (directory (append (feature-source-dirs feature)
                                   (list (feature-test-dir feature))))
          (let ((resolved (resolve-path root directory)))
            (when (uiop:directory-exists-p resolved)
              (dolist (file (recursive-files resolved))
                (when (lisp-file-p file)
                  (let ((relative (relative-pathname root file)))
                    (unless (assoc relative file-paths :test #'string=)
                      (push (cons relative feature) file-paths)))))))))
      (setf file-paths (nreverse file-paths))
      (dolist (record file-paths)
        (let* ((relative (car record))
               (feature (cdr record))
               (path (resolve-path root relative))
               (forms (handler-case
                          (parse-source-tokens
                           (scan-source (uiop:read-file-string path) relative)
                           relative)
                        (error (condition)
                          (fail-closed "source syntax error: ~A" condition))))
               (defs (find-forms forms '("defpackage")))
               (ins (find-forms forms '("in-package")))
               (declared-names nil))
          (dolist (form defs)
            (let* ((children (syntax-node-children form))
                   (package (and (second children)
                                 (node-designator (second children)))))
              (unless package
                (source-syntax-error relative (syntax-node-line form)
                                     "defpackage has no literal package name"))
              (push (register-package-form form relative packages package)
                    declared-names)))
          (push (list :path relative :feature feature :forms forms
                      :packages (nreverse declared-names) :in-packages ins)
                records)))
      (let ((facade-packages
              (remove-duplicates
               (loop for feature in features append (feature-facade-packages feature))
               :test #'string=))
            (owned-paths (mapcar #'car file-paths)))
        (scan-asdf-facades facade-packages owned-paths))
      (values (nreverse records) packages source-files))))
(defun parse-defpackage-options (form package-record)
  (let ((children (cddr (syntax-node-children form))))
    (dolist (option children)
      (unless (eq (syntax-node-kind option) :list)
        (source-syntax-error "source" (syntax-node-line option)
                             "defpackage option must be a list"))
      (let* ((parts (syntax-node-children option))
             (key (keyword-name (first parts)))
             (values (rest parts)))
        (cond
          ((string= (or key "") ":use")
           (setf (package-info-uses package-record)
                 (append (package-info-uses package-record)
                         (mapcar (lambda (node) (or (node-designator node)
                                                    (fail-closed "nonliteral :use package"))) values))))
          ((member key '(":import-from" ":shadowing-import-from") :test #'string=)
           (unless values
             (source-syntax-error "source" (syntax-node-line option)
                                  "~A needs a package name" key))
           (let ((from (or (node-designator (first values))
                           (fail-closed "nonliteral ~A package" key))))
             (push (list from (mapcar (lambda (node) (or (node-designator node)
                                                         (fail-closed "nonliteral imported symbol")))
                                      (rest values)))
                   (package-info-imports package-record))))
          ((string= (or key "") ":export")
           (setf (package-info-exports package-record)
                 (append (package-info-exports package-record)
                         (mapcar (lambda (node) (or (node-designator node)
                                                    (fail-closed "nonliteral :export symbol"))) values))))
          ((string= (or key "") ":intern")
           (setf (package-info-interns package-record)
                 (append (package-info-interns package-record)
                         (mapcar (lambda (node) (or (node-designator node)
                                                    (fail-closed "nonliteral :intern symbol"))) values))))
          ((member key '(":shadow" ":nicknames" ":size" ":documentation") :test #'string=)
           nil)
          (t (source-syntax-error "source" (syntax-node-line option)
                                  "unsupported defpackage option ~S" key)))))))
(defun register-package-form (form relative packages package)
  (let ((existing (gethash package packages)))
    (when existing
      (violation "01" "package ~A is declared more than once (~A and ~A)"
                 package (package-info-file existing) relative))
    (let ((record (make-package-info :name package :file relative
                                     :exports nil :interns nil
                                     :imports nil :uses nil)))
      (setf (gethash package packages) record)
      (parse-defpackage-options form record)))
  package)
(defun package-prefix-p (name prefix)
  (starts-with name prefix))
(defun package-owner-from-prefix (name prefix features infra-suffix)
  (when (package-prefix-p name prefix)
    (let ((tail (subseq name (length prefix))))
      (dolist (feature features)
        (when (or (string= tail (feature-slug feature))
                  (and (feature-infra-package feature)
                       (string= name (feature-infra-package feature))))
          (return-from package-owner-from-prefix feature))
        (when (and (feature-infra-package feature)
                   (string= tail (concatenate 'string (feature-slug feature) infra-suffix)))
          (return-from package-owner-from-prefix feature)))))
  nil)
(defun package-info-for (name packages prefix)
  (or (gethash name packages)
      (when (package-prefix-p name prefix)
        nil)))
(defun package-targets (name packages prefix features facade-packages)
  (let ((record (gethash name packages)))
    (cond
      (record (list record))
      ((member name facade-packages :test #'string=)
       (list (make-package-info :name name :layer "facade" :exports nil :interns nil
                                :imports nil :uses nil)))
      ((package-prefix-p name prefix) nil)
      (t nil))))
(defun package-owners-through-facade (facade symbol packages prefix facade-packages &optional seen)
  (declare (ignore prefix))
  (unless (member facade seen :test #'string=)
    (let ((record (gethash facade packages))
          (owners nil))
      (when record
        (dolist (import (package-info-imports record))
          (when (or (null symbol)
                    (string= symbol "")
                    (member symbol (second import) :test #'string=))
            (push (first import) owners)))
        (dolist (used (package-info-uses record))
          (let ((used-record (gethash used packages)))
            (when (and used-record
                       (or (null symbol)
                           (string= symbol "")
                           (member symbol (package-info-exports used-record) :test #'string=)))
              (push used owners)))))
      (remove-duplicates
       (mapcan (lambda (owner)
                 (if (member owner facade-packages :test #'string=)
                     (package-owners-through-facade owner symbol packages prefix facade-packages
                                                    (cons facade seen))
                     (list owner)))
               (nreverse owners))
       :test #'string=))))
(defun check-feature-lint (options)
  (let* ((root (uiop:ensure-directory-pathname
                (truename (one-option options "--source-root"))))
         (definitions (resolve-path root (one-option options "--feature-definitions")))
         (glossary-path (resolve-path root (one-option options "--glossary")))
         (export-path (one-option options "--export-surface"))
         (legacy-path (one-option options "--legacy-internal-refs"))
         (heading-prefix (one-option options "--glossary-heading-prefix"))
         (prefix (normalize-name (one-option options "--package-prefix")))
         (infra-suffix (normalize-name (one-option options "--infra-suffix")))
         (mode (one-option options "--mode"))
         (forbidden (mapcar #'normalize-name (many-options options "--forbidden-name")))
         (numbered (mapcar #'normalize-name (many-options options "--numbered-prefix")))
         (features (feature-entries (read-safe-one definitions)))
         (glossary (glossary-fields (uiop:read-file-string glossary-path) heading-prefix))
         (legacy (progn
                   (parse-export-surface root export-path)
                   (parse-legacy-allowlist root legacy-path)))
         (feature-by-slug (make-hash-table :test #'equal))
         (facades nil)
         (expected-packages (make-hash-table :test #'equal))
         (all-files nil)
         (package-records nil)
         (source-files nil)
         (edges nil)
         (actual-legacy (make-hash-table :test #'equal)))
    (unless (member mode '("transition" "strict") :test #'string=)
      (fail-closed "--mode must be transition or strict, got ~S" mode))
    (unless (and (plusp (length heading-prefix)) (plusp (length prefix))
                 (plusp (length infra-suffix)))
      (fail-closed "glossary heading prefix, package prefix, and infra suffix must be nonempty"))
    (dolist (feature features)
      (when (gethash (feature-slug feature) feature-by-slug)
        (violation "01" "feature ~A is declared more than once" (feature-slug feature)))
      (setf (gethash (feature-slug feature) feature-by-slug) feature)
      (dolist (package (append
                       (list (feature-domain-package feature)
                             (feature-test-package feature))
                       (when (feature-infra-package feature)
                         (list (feature-infra-package feature)))))
        (when (gethash package expected-packages)
          (violation "01" "package ~A is assigned to multiple features" package))
        (setf (gethash package expected-packages) feature))
      (setf facades (union facades (feature-facade-packages feature) :test #'string=))
      (unless (string= (feature-domain-package feature)
                       (concatenate 'string prefix (feature-slug feature)))
        (violation "01" "feature ~A domain package must equal ~A~A"
                   (feature-slug feature) prefix (feature-slug feature)))
      (when (feature-infra-package feature)
        (unless (string= (feature-infra-package feature)
                         (concatenate 'string (feature-domain-package feature) infra-suffix))
          (violation "01" "feature ~A infra package must equal domain package plus ~A"
                     (feature-slug feature) infra-suffix)))
      (when (member (feature-slug feature) (feature-depends-on feature) :test #'string=)
        (violation "03" "feature ~A declares a self dependency" (feature-slug feature)))
      (dolist (dependency (feature-depends-on feature))
        (unless (gethash dependency feature-by-slug)
          ;; The table may not contain later entries yet; checked again below.
          nil)))
    (dolist (feature features)
      (dolist (dependency (feature-depends-on feature))
        (unless (member dependency (mapcar #'feature-slug features) :test #'string=)
          (violation "03" "feature ~A depends on unknown feature ~A"
                     (feature-slug feature) dependency))))
    (let ((heading-names (loop for slug being the hash-keys of glossary collect slug))
          (feature-names (mapcar #'feature-slug features)))
      (dolist (slug feature-names)
        (unless (gethash slug glossary)
          (violation "01" "feature ~A has no glossary heading" slug)))
      (dolist (slug heading-names)
        (unless (member slug feature-names :test #'string=)
          (violation "01" "glossary has undeclared feature heading ~A" slug))))
    (multiple-value-setq (all-files package-records source-files)
      (scan-feature-files root features))
    (let ((expected-facades facades))
      (dolist (facade expected-facades)
        (unless (gethash facade package-records)
          (violation "01" "declared facade package ~A has no defpackage" facade)))
      (maphash (lambda (name package-record)
                 (let* ((file (package-info-file package-record))
                        (file-feature (feature-for-path file features)))
                   (cond
                     ((gethash name expected-packages)
                      (let ((expected (gethash name expected-packages)))
                        (if (string= name (feature-test-package expected))
                            (unless (path-under-p file (feature-test-dir expected))
                              (violation "01"
                                         "test package ~A is declared outside its feature test directory"
                                         name))
                            (unless (some (lambda (directory)
                                           (path-under-p file directory))
                                         (feature-source-dirs expected))
                              (violation "01"
                                         "package ~A is declared outside its feature source directories"
                                         name)))))
                     ((member name expected-facades :test #'string=) nil)
                     ((and file-feature (package-prefix-p name prefix))
                      (violation "01" "undeclared feature package ~A in ~A" name file))
                     ((and (package-prefix-p name prefix) file-feature)
                      (violation "03" "unknown feature package ~A in ~A" name file)))))
               package-records))
    (dolist (feature features)
      (dolist (expected (append (list (feature-domain-package feature))
                                (when (feature-infra-package feature)
                                  (list (feature-infra-package feature)))))
        (unless (gethash expected package-records)
          (violation "01" "feature ~A is missing package declaration ~A"
                     (feature-slug feature) expected))))
    (dolist (record all-files)
      (let* ((path (getf record :path))
             (feature (getf record :feature))
             (name (pathname-name (pathname path))))
        (when (or (forbidden-name-p name forbidden)
                  (numbered-name-p name numbered))
          (violation "02" "forbidden file name ~A" path))))
    (maphash (lambda (name package-record)
               (declare (ignore package-record))
               (when (or (forbidden-name-p name forbidden)
                         (numbered-name-p name numbered))
                 (violation "02" "forbidden package name ~A" name)))
             package-records)
    (maphash (lambda (name package-record)
               (declare (ignore package-record))
               (unless (or (gethash name expected-packages)
                           (member name facades :test #'string=))
                 (when (package-prefix-p name prefix)
                   (violation "03" "unknown feature package ~A" name))))
             package-records)
    ;; Package records need their feature and layer before package references
    ;; and defpackage edges can be resolved.
    (maphash (lambda (name package-record)
               (let ((feature (gethash name expected-packages)))
                 (cond
                   (feature
                    (setf (package-info-feature package-record) (feature-slug feature)
                          (package-info-layer package-record)
                          (cond
                            ((string= name (feature-test-package feature))
                             "test")
                            ((and (feature-infra-package feature)
                                 (string= name (feature-infra-package feature)))
                             "infra")
                            (t "domain"))))
                   ((member name facades :test #'string=)
                    (setf (package-info-layer package-record) "facade"))
                   (t
                    (let ((feature (feature-for-path (package-info-file package-record) features)))
                      (when feature
                        (setf (package-info-feature package-record) (feature-slug feature)
                              (package-info-layer package-record) "test")))))))
             package-records)
    (dolist (record all-files)
      (let* ((path (getf record :path))
             (feature (getf record :feature))
             (forms (getf record :forms))
             (fallback-package (or (find-if (lambda (name) (gethash name expected-packages))
                                            (getf record :packages))
                                   (when feature (feature-domain-package feature))))
             (current-package fallback-package))
        (dolist (form forms)
          (when (and (eq (syntax-node-kind form) :list)
                     (string= (or (list-op-name form) "") "in-package"))
            (let ((designator (node-designator (second (syntax-node-children form)))))
              (unless designator
                (source-syntax-error path (syntax-node-line form)
                                     "in-package needs a literal package name"))
              (setf current-package designator)))
          (let* ((source-info (and current-package (gethash current-package package-records)))
       (source-feature (or (and source-info (package-info-feature source-info))
                           (and feature (feature-slug feature)))))
  (when (and (eq (syntax-node-kind form) :list)
             (string= (or (list-op-name form) "") "defpackage"))
    (let* ((package-name (node-designator (second (syntax-node-children form))))
           (defined (and package-name (gethash package-name package-records))))
      (when defined
        (when (and (package-info-feature defined)
                   (not (string= (package-info-feature defined) source-feature)))
          (violation "01" "package ~A is declared from the wrong feature file ~A"
                     package-name path))
        (setf source-info defined
              source-feature (package-info-feature defined))))
  ;; Every observed package edge must be declared; same-feature edges are
  ;; local package relationships and are checked separately for the infra rule.
  ;; The glossary's named package and APIs are compared to both static
  ;; DEFPACKAGE declarations and the checked-in export-surface snapshot.
  (when source-info
    (dolist (used (package-info-uses source-info))
      (let ((target (gethash used package-records)))
        (cond
          (target
           (push (make-graph-edge :from source-feature
                                  :to (package-info-feature target)
                                  :kind "use" :path path) edges)
           (when (and (string= (or (package-info-layer source-info) "") "domain")
                      (string= (or (package-info-layer target) "") "infra"))
             (violation "06" "domain package ~A uses infra package ~A in ~A"
                        (package-info-name source-info) used path)))
          ((member used facades :test #'string=)
           (dolist (owner-package
                    (package-owners-through-facade used "" package-records prefix facades))
             (let ((target (gethash owner-package package-records)))
               (when target
                 (push (make-graph-edge :from source-feature
                                        :to (package-info-feature target)
                                        :kind "facade-use" :path path) edges)
                 (when (and (string= (or (package-info-layer source-info) "") "domain")
                            (string= (or (package-info-layer target) "") "infra"))
                   (violation "06" "domain package ~A uses facade ~A with infra dependency ~A"
                              (package-info-name source-info) used owner-package))))))
          ((package-prefix-p used prefix)
           (violation "03" "unknown package ~A used by ~A in ~A"
                      used (package-info-name source-info) path)))))
    (dolist (import (package-info-imports source-info))
      (let* ((used (first import))
             (target (gethash used package-records)))
        (cond
          (target
           (push (make-graph-edge :from source-feature
                                  :to (package-info-feature target)
                                  :kind "import-from" :path path) edges)
           (when (and (string= (or (package-info-layer source-info) "") "domain")
                      (string= (or (package-info-layer target) "") "infra"))
             (violation "06" "domain package ~A imports from infra package ~A in ~A"
                        (package-info-name source-info) used path)))
          ((member used facades :test #'string=)
           (dolist (symbol (second import))
             (let ((owners (package-owners-through-facade used symbol package-records prefix facades)))
               (if (null owners)
                   (violation "04" "facade ~A does not resolve imported symbol ~A in ~A"
                              used symbol path)
                   (dolist (owner-package owners)
                     (let ((target (gethash owner-package package-records)))
                       (when target
                         (push (make-graph-edge :from source-feature
                                                :to (package-info-feature target)
                                                :kind "facade-import" :path path) edges)
                         (when (and (string= (or (package-info-layer source-info) "") "domain")
                                    (string= (or (package-info-layer target) "") "infra"))
                           (violation "06" "domain package ~A imports facade symbol ~A from infra package ~A"
                                      (package-info-name source-info) symbol owner-package)))))))))
          ((package-prefix-p used prefix)
           (violation "03" "unknown package ~A imported by ~A in ~A"
                      used (package-info-name source-info) path))))))) (dolist (reference (package-references-in-node form path))
    (let* ((target-package (package-reference-package reference))
           (target-info (gethash target-package package-records))
           (target-feature nil)
           (resolved-package target-package))
      (when (package-prefix-p target-package prefix)
        (cond
          (target-info
           (if (member target-package facades :test #'string=)
               (let ((owners (package-owners-through-facade
                              target-package (package-reference-symbol reference)
                              package-records prefix facades)))
                 (cond
                   ((null owners)
                    (violation "04" "facade reference ~A~A~A has no imported feature owner in ~A"
                               target-package
                               (if (package-reference-internal-p reference) "::" ":")
                               (package-reference-symbol reference) path))
                   ((/= (length owners) 1)
                    (violation "04" "facade reference ~A::~A resolves to multiple feature packages in ~A"
                               target-package (package-reference-symbol reference) path))
                   (t
                    (setf resolved-package (first owners)
                          target-feature (package-info-feature
                                          (gethash resolved-package package-records)))))
                 (when (and (not (package-reference-internal-p reference))
                            (not (member (package-reference-symbol reference)
                                         (package-info-exports target-info) :test #'string=)))
                   (violation "04" "facade package ~A does not export ~A in ~A"
                              target-package (package-reference-symbol reference) path)))
               (setf target-feature (package-info-feature target-info)))
           (unless (or target-feature (member target-package facades :test #'string=))
             (violation "03" "package ~A has no feature owner in ~A" target-package path)))
          (t
           (violation "03" "unknown feature package ~A referenced in ~A"
                      target-package path)))
        (when (and target-feature source-feature
                   (not (string= target-feature source-feature)))
          (push (make-graph-edge :from source-feature :to target-feature
                                 :kind "reference" :path path) edges))
        (let ((actual-target (gethash resolved-package package-records)))
          (when (and source-info actual-target
                     (string= (or (package-info-layer source-info) "") "domain")
                     (string= (or (package-info-layer actual-target) "") "infra"))
            (violation "06" "domain package ~A references infra package ~A in ~A"
                       (package-info-name source-info) resolved-package path)))
        (when (and target-feature source-feature
                   (not (string= target-feature source-feature))
                   (package-reference-internal-p reference))
          (let* ((symbol (package-reference-symbol reference))
                 (key (list (normalize-path-string path) target-package symbol))
                 (allowed-count (gethash key legacy)))
            (if (and (string= mode "transition")
                     (member target-package facades :test #'string=)
                     allowed-count
                     (< (gethash key actual-legacy 0) allowed-count))
                (incf (gethash key actual-legacy 0))
                (violation "05" "cross-feature internal reference ~A::~A from feature ~A in ~A"
                           target-package symbol source-feature path))))))))))) (when (and (string= mode "strict") (> (hash-table-count legacy) 0))
      (violation "05" "strict mode requires an empty legacy internal reference allowlist")) (dolist (edge edges)
      (when (and (graph-edge-from edge) (graph-edge-to edge)
                 (not (string= (graph-edge-from edge) (graph-edge-to edge))))
        (let ((feature (gethash (graph-edge-from edge) feature-by-slug)))
          (when (and feature
                     (not (member (graph-edge-to edge) (feature-depends-on feature) :test #'string=)))
            (violation "03" "undeclared dependency ~A -> ~A from ~A (~A)"
                       (graph-edge-from edge) (graph-edge-to edge)
                       (graph-edge-kind edge) (graph-edge-path edge)))))) (let ((state (make-hash-table :test #'equal))
          (stack nil))
      (labels ((visit (slug)
                 (case (gethash slug state)
                   (:done nil)
                   (:active
                    (violation "03" "dependency cycle includes ~{~A~^ -> ~}" (reverse (cons slug stack))))
                   (otherwise
                    (setf (gethash slug state) :active)
                    (push slug stack)
                    (let ((feature (gethash slug feature-by-slug)))
                      (when feature
                        (dolist (dependency (feature-depends-on feature))
                          (when (gethash dependency feature-by-slug) (visit dependency)))))
                    (pop stack)
                    (setf (gethash slug state) :done)))))
        (dolist (feature features) (visit (feature-slug feature))))) (dolist (feature features)
      (let* ((slug (feature-slug feature))
       (entry (gethash slug glossary))
       (package-value (and entry (gethash "Package" entry)))
       (package-names
        (and package-value
             (mapcar (function normalize-name)
                     (glossary-list-values package-value))))
       (api-names (append
                   (when entry
                     (glossary-list-values (or (gethash "Key types" entry) "")))
                   (when entry
                     (glossary-list-values (or (gethash "Key functions" entry) "")))))
       (package-record (gethash (feature-domain-package feature) package-records)))
  (when (and entry (not package-value))
    (violation "01" "glossary entry ~A has no Package field" slug))
  (let ((declared-packages
        (append
         (list (feature-domain-package feature))
         (when (feature-infra-package feature)
           (list (feature-infra-package feature))))))
    (when (and package-value
               (not
                (and (= (length package-names) (length declared-packages))
                     (every (lambda (package)
                              (member package declared-packages
                                      :test (function string=)))
                            package-names)
                     (every (lambda (package)
                              (member package package-names
                                      :test (function string=)))
                            declared-packages))))
      (violation "01"
                 "glossary feature ~A names packages ~{~A~^, ~}, expected ~{~A~^, ~}"
                 slug package-names declared-packages)))
  (when (and entry (not (gethash "Key types" entry)))
    (violation "07" "glossary entry ~A has no Key types field" slug))
  (when (and entry (not (gethash "Key functions" entry)))
    (violation "07" "glossary entry ~A has no Key functions field" slug))
  (dolist (api api-names)
    (let ((api (normalize-name api)))
      (unless (and package-record
                   (member api (package-info-exports package-record)
                           :test (function string=)))
        (violation "07"
                   "glossary API ~A is not exported by feature package ~A"
                   api (feature-domain-package feature))))))) (if *violations*
        (report-main 1)
        (progn
          (format t "FEATURE-LINT PASS: ~D feature(s), checks 1-7~%" (length features))
          (sb-ext:exit :code 0)))))
(defun main ()
  (handler-case
      (let* ((allowed '("--source-root" "--feature-definitions" "--glossary"
                        "--glossary-heading-prefix" "--export-surface" "--mode"
                        "--legacy-internal-refs" "--forbidden-name" "--numbered-prefix"
                        "--package-prefix" "--infra-suffix"))
             (repeatable '("--forbidden-name" "--numbered-prefix"))
             (required '("--source-root" "--feature-definitions" "--glossary"
                         "--glossary-heading-prefix" "--export-surface" "--mode"
                         "--package-prefix" "--infra-suffix"))
             (options (parse-options (command-arguments) allowed repeatable required)))
        (check-feature-lint options))
    (error (condition)
      (format *error-output* "[feature-lint:error] ~A~%" condition)
      (sb-ext:exit :code 2))))
(main)