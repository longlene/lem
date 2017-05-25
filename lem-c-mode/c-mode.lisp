(defpackage :lem-c-mode
  (:use :cl :lem)
  (:import-from
   :lem.language-mode
   :language-mode
   :indent)
  (:export :*c-mode-hook*))
(in-package :lem-c-mode)

(defvar *c-mode-hook* '())

(defvar *c-syntax-table*
  (let ((table (make-syntax-table
                :space-chars '(#\space #\tab #\newline)
                :symbol-chars '(#\_)
                :paren-alist '((#\( . #\))
                               (#\{ . #\})
                               (#\[ . #\]))
                :string-quote-chars '(#\" #\' #\`)
                :expr-prefix-chars '(#\, #\;)
                :expr-suffix-chars '(#\, #\;)
                :line-comment-string "//"
                :block-comment-pairs '(("/*" . "*/"))))
        (tmlanguage (lem-c-mode.grammer:make-tmlanguage-c)))
    (set-syntax-parser table tmlanguage)
    table))

(define-major-mode c-mode language-mode
    (:name "c"
     :keymap *c-mode-keymap*
     :syntax-table *c-syntax-table*)
  (setf (variable-value 'enable-syntax-highlight) t)
  (setf (variable-value 'calc-indent-function) 'calc-indent)
  (setf (variable-value 'indent-tabs-mode) t)
  (run-hooks *c-mode-hook*))

(defun c-beginning-of-defun (point)
  (loop
    (line-start point)
    (when (looking-at point "^\\w[^=(]*\\(.*\\)")
      (return point))
    (unless (line-offset point -1)
      (return point))))

(defvar *indent-line-function* nil)

(defun %indent (p indent)
  (when *indent-line-function*
    (funcall *indent-line-function* p indent)))

(defun delimiter-line-p (p)
  (multiple-value-bind (start)
      (ppcre:scan "[^\\\\]?;\\s*(?:/\\*.*?\\*/|//.*?)?\\s*$" (line-string p))
    (when start
      (with-point ((p p))
        (line-offset p 0 (1+ start))
        (not (in-string-or-comment-p p))))))

(defun end-block-line-p (p)
  (with-point ((p p))
    (loop :for start := 0 :then (1+ i)
          :for i := (position #\} (line-string p) :start start)
          :while i
          :do (unless (let ((p (character-offset (line-start p) i)))
                        (check-type p point)
                        (in-string-or-comment-p p))
                (return i)))))

(defun unbalanced-p (state)
  (if (member #\( (pps-state-paren-stack state)) t nil))

(defun unbalanced-indent (p indent start)
  (flet ((jmp-start-paren (p)
           (loop
             (scan-lists p -1 1)
             (when (eql #\( (character-at p))
               (return)))))
    (let ((state))
      (%indent p indent)
      (jmp-start-paren p)
      (let ((indent1 (1+ (point-column p))))
        (loop
          (unless (line-offset p 1) (return-from unbalanced-indent nil))
          (%indent p indent1)
          (unless (unbalanced-p (setf state
                                      (parse-partial-sexp (copy-point start :temporary)
                                                          (line-end p))))
            (return))
          (with-point ((p p))
            (jmp-start-paren p)
            (setf indent1 (1+ (point-column p)))))
        state))))

(defun cond-op-line-p (p limit)
  (and (not (delimiter-line-p p))
       (search-forward (line-start p) "?" limit)
       (not (in-string-or-comment-p p))
       (not (syntax-escape-char-p (character-at p -2)))))

(defun indent-cond-op (p indent)
  (with-point ((tmp (line-end p)))
    (when (cond-op-line-p p tmp)
      (line-start tmp)
      (when (and (not (unbalanced-p (parse-partial-sexp tmp p)))
                 (not (delimiter-line-p p)))
        (loop
          (unless (line-offset p 1) (return-from indent-cond-op nil))
          (c-indent-line p (+ indent tab-width))
          (when (delimiter-line-p p)
            (return))))))
  t)

(defun c-indent-line (p indent)
  (let ((tab-width (variable-value 'tab-width :default p)))
    (back-to-indentation p)
    (loop :while (end-line-p p)
          :do (%indent p indent)
          :do (if (line-offset p 1)
                  (back-to-indentation p)
                  (return-from c-indent-line nil)))
    (when (eql #\# (character-at p))
      (%indent p 0))
    (when (eql #\} (character-at p))
      (character-offset p 1)
      (skip-whitespace-forward p t))
    (alexandria:when-let ((i (end-block-line-p p)))
      (with-point ((p p)
                   (start p))
        (line-start start)
        (character-offset (line-start p) (1+ i))
        (when (> 0 (pps-state-paren-depth (parse-partial-sexp start p)))
          (decf indent tab-width))))
    (let ((word (looking-at p "\\w+"))
          (state)
          (unbalanced-flag nil))
      (when word
        (character-offset p (length word))
        (skip-whitespace-forward p t))
      (with-point ((start p))
        (line-start start)
        (setf state (parse-partial-sexp (copy-point start :temporary)
                                        (line-end p)))
        (cond
          ((unbalanced-p state)
           (setf unbalanced-flag t)
           (unless (setf state (unbalanced-indent p indent start))
             (return-from c-indent-line nil)))
          (t
           (cond
             ((and word (ppcre:scan "^(?:case|default)$" word))
              (%indent p (- indent tab-width)))
             (t
              (%indent p indent)
              (unless (indent-cond-op p indent)
                (return-from c-indent-line nil)))))))
      (when (eql #\{ (car (pps-state-paren-stack state)))
        (let ((indent (+ indent tab-width))
              (status))
          (loop
            (unless (line-offset p 1) (return-from c-indent-line nil))
            (setf (values indent status) (c-indent-line p indent))
            (when (and (not (eq status :block-end))
                       (end-block-line-p p))
              (return-from c-indent-line (values indent :block-end))))))
      (when (and word (ppcre:scan "^(?:do|else|for|if|switch|while)$" word)
                 (not (and (not unbalanced-flag) (delimiter-line-p p))))
        (unless (line-offset p 1) (return-from c-indent-line nil))
        (c-indent-line p (+ indent tab-width))
        (return-from c-indent-line indent))
      (return-from c-indent-line indent))))

(defun calc-indent-region (start end)
  (with-point ((p start))
    (let ((indent (point-column (back-to-indentation p))))
      (loop
        (let ((next-indent (c-indent-line p indent)))
          (unless next-indent (return))
          (unless (line-offset p 1) (return))
          (unless (point< start end) (return))
          (setf indent next-indent))))))

(defun calc-indent (point)
  (cond
    ((in-string-p point)
     (+ (back-to-indentation point)
        (variable-value 'tab-width :default point)))
    ((with-point ((p point))
       (when (maybe-beginning-of-comment p)
         (if (eql #\* (character-at (back-to-indentation point)))
             (+ 1 (point-column p))
             (+ 2 (point-column p))))))
    (t
     (with-point ((start point))
       (line-offset start -1)
       (c-beginning-of-defun start)
       (let ((*indent-line-function*
              (lambda (p indent)
                (when (same-line-p point p)
                  (return-from calc-indent indent)))))
         (calc-indent-region start point))))))

(pushnew (cons "\\.c$" 'c-mode) *auto-mode-alist* :test #'equal)
(pushnew (cons "\\.h$" 'c-mode) *auto-mode-alist* :test #'equal)
