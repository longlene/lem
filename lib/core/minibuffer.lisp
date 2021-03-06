(in-package :lem)

(export '(*enable-recursive-minibuffers*
          *minibuffer-completion-function*
          *minibuffer-file-complete-function*
          *minibuffer-buffer-complete-function*
          *minibuffer-activate-hook*
          *minibuffer-deactivate-hook*
          *minibuf-keymap*
          minibuffer-prompt-attribute
          minibuffer-window-p
          minibuffer-window-active-p
          minibuffer-window-height
          minibufferp
          message
          message-without-log
          message-buffer
          active-echoarea-p
          prompt-for-character
          active-minibuffer-window
          check-switch-minibuffer-window
          minibuffer-read-line-execute
          minibuffer-read-line-completion
          minibuffer-read-line-prev-history
          minibuffer-read-line-next-history
          prompt-for-y-or-n-p
          prompt-for-line
          prompt-for-string
          prompt-for-integer
          prompt-for-buffer
          prompt-for-file
          prompt-for-directory))

(defparameter *minibuffer-window-height* 1)
(defvar *enable-recursive-minibuffers* nil)

(defvar +recursive-minibuffer-break-tag+ (gensym))

(defvar *minibuffer-completion-function* nil)
(defvar *minibuffer-file-complete-function* nil)
(defvar *minibuffer-buffer-complete-function* nil)

(defvar *minibuffer-activate-hook* '())
(defvar *minibuffer-deactivate-hook* '())

(defclass minibuffer-window (floating-window) ())
(defclass sticky-minibuffer-window (minibuffer-window) ())

(defun make-minibuffer-window (frame)
  (make-instance 'sticky-minibuffer-window
                 :buffer (frame-echoarea-buffer frame)
                 :x 0
                 :y (- (display-height)
                       (minibuffer-window-height))
                 :width (display-width)
                 :height (minibuffer-window-height)
                 :use-modeline-p nil
                 :frame frame))

(define-attribute minibuffer-prompt-attribute
  (t :foreground "blue" :bold-p t))

(defun minibuffer-window ()
  (frame-minibuffer-window (current-frame)))
(defun minibuffer-window-p (window)
  (typep window 'minibuffer-window))
(defun minibuffer-window-active-p () (eq (current-window) (minibuffer-window)))
(defun minibuffer-window-height () *minibuffer-window-height*)
(defun minibuffer () (window-buffer (minibuffer-window)))
(defun minibufferp (buffer) (eq buffer (minibuffer)))

(defun sticky-bottom-minibuffer-p ()
  (typep (minibuffer-window) 'sticky-minibuffer-window))

(define-major-mode minibuffer-mode nil
    (:name "minibuffer"
     :keymap *minibuf-keymap*
     :syntax-table (make-syntax-table
                    :symbol-chars '(#\_ #\-)))
  (setf (variable-value 'truncate-lines :buffer (current-buffer)) nil))

(defun setup-minibuffer (frame)
  (setf (frame-echoarea-buffer frame)
        (make-buffer "*echoarea*" :temporary t :enable-undo-p nil))
  (setf (frame-minibuffer-buffer frame)
        (make-buffer "*minibuffer*" :temporary t :enable-undo-p t))
  (when (or (null (frame-minibuffer-window frame))
            (deleted-window-p (frame-minibuffer-window frame)))
    (setf (frame-minibuffer-window frame)
          (make-minibuffer-window frame))))

(defun teardown-minibuffer (frame)
  (%free-window (frame-minibuffer-window frame)))

(defun minibuf-update-size ()
  (window-set-pos (minibuffer-window) 0 (1- (display-height)))
  (window-set-size (minibuffer-window) (display-width) 1))

(defun log-message (string args)
  (when string
    (let ((msg (apply #'format nil string args)))
      (let ((buffer (make-buffer "*Messages*")))
        (with-open-stream (stream (make-buffer-output-stream
                                   (buffer-end-point buffer)))
          (fresh-line stream)
          (princ msg stream))))))

(defgeneric show-message (string)
  (:method (string)
    (cond (string
           (erase-buffer (frame-echoarea-buffer (current-frame)))
           (let ((point (buffer-point (frame-echoarea-buffer (current-frame)))))
             (insert-string point string))
           (when (active-minibuffer-window)
             (handler-case
                 (with-current-window (minibuffer-window)
                   (unwind-protect (progn
                                     (%switch-to-buffer (frame-echoarea-buffer (current-frame)) nil nil)
                                     (sit-for 1 t))
                     (%switch-to-buffer (frame-minibuffer-buffer (current-frame)) nil nil)))
               (editor-abort ()
                 (minibuf-read-line-break)))))
          (t
           (erase-buffer (frame-echoarea-buffer (current-frame)))))))

(defun message-without-log (string &rest args)
  (show-message (if string
                    (apply #'format nil string args)
                    nil)))

(defun message (string &rest args)
  (log-message string args)
  (apply #'message-without-log string args)
  t)

(defgeneric show-message-buffer (buffer)
  (:method (buffer)
    (erase-buffer (frame-echoarea-buffer (current-frame)))
    (insert-buffer (buffer-point (frame-echoarea-buffer (current-frame))) buffer)))

(defun message-buffer (buffer)
  (show-message-buffer buffer))

(defun active-echoarea-p ()
  (point< (buffer-start-point (frame-echoarea-buffer (current-frame)))
          (buffer-end-point (frame-echoarea-buffer (current-frame)))))

(defgeneric prompt-for-character (prompt)
  (:method (prompt)
    (when (interactive-p)
      (message "~A" prompt)
      (redraw-display))
    (let ((key (read-key)))
      (when (interactive-p)
        (message nil))
      (if (abort-key-p key)
          (error 'editor-abort)
          (key-to-char key)))))

(defun prompt-for-y-or-n-p (prompt)
  (do () (nil)
    (let ((c (prompt-for-character (format nil "~a [y/n]? " prompt))))
      (case c
        (#\y (return t))
        (#\n (return nil))))))

(define-key *minibuf-keymap* "C-j" 'minibuffer-read-line-execute)
(define-key *minibuf-keymap* "Return" 'minibuffer-read-line-execute)
(define-key *minibuf-keymap* "Tab" 'minibuffer-read-line-completion)
(define-key *minibuf-keymap* "M-p" 'minibuffer-read-line-prev-history)
(define-key *minibuf-keymap* "M-n" 'minibuffer-read-line-next-history)
(define-key *minibuf-keymap* "C-g" 'minibuf-read-line-break)

(defvar *minibuf-read-line-comp-f*)
(defvar *minibuf-read-line-existing-p*)

(defvar *minibuf-read-line-history-table* (make-hash-table))
(defvar *minibuf-read-line-history*)

(defvar *minibuf-read-line-depth* 0)
(defvar *minibuf-prev-prompt* nil)

(defun check-switch-minibuffer-window ()
  (when (minibuffer-window-active-p)
    (editor-error "Cannot switch buffer in minibuffer window")))

(defgeneric active-minibuffer-window ())
(defmethod active-minibuffer-window ()
  (if (/= 0 *minibuf-read-line-depth*)
      (minibuffer-window)
      nil))

(defun minibuffer-start-point ()
  (character-offset
   (copy-point (buffer-start-point (minibuffer))
               :temporary)
   (frame-minibuffer-start-charpos (current-frame))))

(defun get-minibuffer-string ()
  (points-to-string (minibuffer-start-point)
                    (buffer-end-point (minibuffer))))

(defun minibuffer-clear-input ()
  (delete-between-points (minibuffer-start-point)
                         (buffer-end-point (minibuffer))))

(define-command minibuffer-read-line-execute () ()
  (let ((str (get-minibuffer-string)))
    (when (or (string= str "")
              (null *minibuf-read-line-existing-p*)
              (funcall *minibuf-read-line-existing-p* str))
      (throw 'minibuf-read-line-end t)))
  t)

(define-command minibuffer-read-line-completion () ()
  (when (and *minibuf-read-line-comp-f*
             *minibuffer-completion-function*)
    (with-point ((start (minibuffer-start-point)))
      (funcall *minibuffer-completion-function*
               *minibuf-read-line-comp-f*
               start))))

(defun %backup-edit-string (history)
  (lem.history:backup-edit-string
   history
   (points-to-string (minibuffer-start-point)
                     (buffer-end-point (minibuffer)))))

(defun %restore-edit-string (history)
  (multiple-value-bind (str win)
      (lem.history:restore-edit-string history)
    (when win
      (minibuffer-clear-input)
      (insert-string (current-point) str))))

(define-command minibuffer-read-line-prev-history () ()
  (%backup-edit-string *minibuf-read-line-history*)
  (multiple-value-bind (str win)
      (lem.history:prev-history *minibuf-read-line-history*)
    (when win
      (minibuffer-clear-input)
      (insert-string (current-point) str))))

(define-command minibuffer-read-line-next-history () ()
  (%backup-edit-string *minibuf-read-line-history*)
  (%restore-edit-string *minibuf-read-line-history*)
  (multiple-value-bind (str win)
      (lem.history:next-history *minibuf-read-line-history*)
    (when win
      (minibuffer-clear-input)
      (insert-string (current-point) str))))

(define-command minibuf-read-line-break () ()
  (throw +recursive-minibuffer-break-tag+
    +recursive-minibuffer-break-tag+))

(defun minibuf-read-line-loop (comp-f existing-p syntax-table)
  (let ((*minibuf-read-line-existing-p* existing-p)
        (*minibuf-read-line-comp-f* comp-f))
    (with-current-syntax syntax-table
      (catch 'minibuf-read-line-end
        (command-loop))
      (let ((str (get-minibuffer-string)))
        (lem.history:add-history *minibuf-read-line-history* str)
        str))))

(defgeneric prompt-for-line (prompt initial comp-f existing-p history-name &optional syntax-table))

(defmethod prompt-for-line (prompt initial comp-f existing-p history-name
                            &optional (syntax-table (current-syntax)))
  (when (= 0 *minibuf-read-line-depth*)
    (run-hooks *minibuffer-activate-hook*))
  (when (and (not *enable-recursive-minibuffers*) (< 0 *minibuf-read-line-depth*))
    (editor-error "ERROR: recursive use of minibuffer"))
  (let* ((frame (current-frame))
         (minibuffer-calls-window (frame-minibuffer-calls-window frame)))
    (unwind-protect
         (progn
           (setf (frame-minibuffer-calls-window frame) (current-window))
           (let ((*minibuf-read-line-history*
                   (let ((table (gethash history-name *minibuf-read-line-history-table*)))
                     (or table
                         (setf (gethash history-name *minibuf-read-line-history-table*)
                               (lem.history:make-history))))))
             (let ((result
                     (catch +recursive-minibuffer-break-tag+
                       (handler-case
                           (with-current-window (minibuffer-window)
                             (%switch-to-buffer (frame-minibuffer-buffer (current-frame)) nil nil)
                             (let ((minibuf-buffer-prev-string
                                     (points-to-string (buffer-start-point (minibuffer))
                                                       (buffer-end-point (minibuffer))))
                                   (prev-prompt-length
                                     (when *minibuf-prev-prompt*
                                       (length *minibuf-prev-prompt*)))
                                   (minibuf-buffer-prev-point
                                     (window-point (minibuffer-window)))
                                   (*minibuf-prev-prompt* prompt)
                                   (*minibuf-read-line-depth*
                                     (1+ *minibuf-read-line-depth*)))
                               (let ((*inhibit-read-only* t))
                                 (erase-buffer))
                               (minibuffer-mode)
                               (reset-horizontal-scroll (minibuffer-window))
                               (unless (string= "" prompt)
                                 (insert-string (current-point) prompt
                                                :attribute 'minibuffer-prompt-attribute
                                                :read-only t
                                                :field t)
                                 (character-offset (current-point) (length prompt)))
                               (let ((start-charpos (frame-minibuffer-start-charpos frame)))
                                 (unwind-protect
                                      (progn
                                        (setf (frame-minibuffer-start-charpos frame) (point-charpos (current-point)))
                                        (when initial
                                          (insert-string (current-point) initial))
                                        (unwind-protect (minibuf-read-line-loop comp-f existing-p syntax-table)
                                          (if (deleted-window-p (frame-minibuffer-calls-window (current-frame)))
                                              (setf (current-window) (car (window-list)))
                                              (setf (current-window) (frame-minibuffer-calls-window (current-frame))))
                                          (with-current-window (minibuffer-window)
                                            (let ((*inhibit-read-only* t))
                                              (erase-buffer))
                                            (insert-string (current-point) minibuf-buffer-prev-string)
                                            (when prev-prompt-length
                                              (with-point ((start (current-point))
                                                           (end (current-point)))
                                                (line-start start)
                                                (line-offset end 0 prev-prompt-length)
                                                (put-text-property start end
                                                                   :attribute 'minibuffer-prompt-attribute)
                                                (put-text-property start end :read-only t)
                                                (put-text-property start end :field t)))
                                            (move-point (current-point) minibuf-buffer-prev-point)
                                            (when (= 1 *minibuf-read-line-depth*)
                                              (run-hooks *minibuffer-deactivate-hook*)
                                              (%switch-to-buffer (frame-echoarea-buffer frame) nil nil)))))
                                   (setf (frame-minibuffer-start-charpos frame) start-charpos)))))
                         (editor-abort (c)
                           (error c))))))
               (if (eq result +recursive-minibuffer-break-tag+)
                   (error 'editor-abort)
                   result))))
      (setf (frame-minibuffer-calls-window frame) minibuffer-calls-window))))

(defun prompt-for-string (prompt &optional initial)
  (prompt-for-line prompt (or initial "") nil nil 'mh-read-string))

(defun prompt-for-integer (prompt &optional min max)
  (parse-integer
   (prompt-for-line prompt "" nil
                    #'(lambda (str)
                        (multiple-value-bind (n len)
                            (parse-integer str :junk-allowed t)
                          (and
                           n
                           (/= 0 (length str))
                           (= (length str) len)
                           (if min (<= min n) t)
                           (if max (<= n max) t))))
                    'mh-read-number)))

(defun prompt-for-buffer (prompt &optional default existing)
  (when default
    (setq prompt (format nil "~a(~a) " prompt default)))
  (let ((result (prompt-for-line
                 prompt
                 ""
                 *minibuffer-buffer-complete-function*
                 (and existing
                      (lambda (name)
                        (member name (buffer-list) :test #'string= :key #'buffer-name)))
                 'mh-read-buffer)))
    (if (string= result "")
        default
        result)))

(defun prompt-for-file (prompt &optional directory (default (buffer-directory)) existing)
  (when default
    (setq prompt (format nil "~a(~a) " prompt default)))
  (let ((result
          (prompt-for-line prompt
                           directory
                           (when *minibuffer-file-complete-function*
                             (lambda (str)
                               (funcall *minibuffer-file-complete-function*
                                        str directory)))
                           (and existing #'virtual-probe-file)
                           'mh-read-file)))
    (if (string= result "")
        default
        result)))

(defun prompt-for-directory (prompt &optional directory (default (buffer-directory)) existing)
  (let ((result
          (prompt-for-line prompt
                           directory
                           (when *minibuffer-file-complete-function*
                             (lambda (str)
                               (funcall *minibuffer-file-complete-function*
                                        str directory :directory-only t)))
                           (and existing #'virtual-probe-file)
                           'mh-read-file)))
    (if (string= result "")
        default
        result)))

(defun prompt-for-library (prompt history-name)
  (macrolet ((ql-symbol-value (symbol)
               `(symbol-value (uiop:find-symbol* ,symbol :quicklisp))))
    (let ((systems
            (append
             (mapcar (lambda (x) (pathname-name x))
                     (directory
                      (merge-pathnames "**/lem-*.asd"
                                       (asdf:system-source-directory :lem-contrib))))
             (set-difference
              (mapcar #'pathname-name
                      (loop for i in (ql-symbol-value :*local-project-directories*)
                            append (directory (merge-pathnames "**/lem-*.asd" i))))
              (mapcar #'pathname-name
                      (directory (merge-pathnames "**/lem-*.asd"
                                                  (asdf:system-source-directory :lem))))
              :test #'equal))))
      (setq systems (mapcar (lambda (x) (subseq x 4)) systems))
      (prompt-for-line prompt ""
                       (lambda (str) (completion str systems))
                       (lambda (system) (find system systems :test #'string=))
                       history-name))))

(defun prompt-for-encodings (prompt history-name)
  (let (encodings)
    (maphash (lambda (x y)
               (declare (ignore y))
               (push (string-downcase x) encodings))
             lem-base::*encoding-collections*)
    (let ((name (prompt-for-line
                 (format nil "~A(~(~A~))" prompt lem-base::*default-external-format*) ""
                 (lambda (str) (completion str encodings))
                 (lambda (encoding) (or (equal encoding "")
                                        (find encoding encodings :test #'string=)))
                 history-name)))
      (cond ((equal name "") lem-base::*default-external-format*)
            (t (read-from-string (format nil ":~A" name)))))))
