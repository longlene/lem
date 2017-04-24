(defpackage lem-lisp-mode.swank-protocol
  (:use :cl)
  (:import-from :trivial-types
                :association-list
                :proper-list)
  (:export :disconnected)
  (:export :connection
           :connection-hostname
           :connection-port
           :connection-request-count
           :connection-package
           :connection-prompt-string
           :connection-process
           :connection-log-p
           :connection-logging-stream
           :connection-features)
  (:export :new-connection
           :read-message-string
           :send-message-string
           :send-message
           :message-waiting-p
           :emacs-rex-string
           :emacs-rex
           :finish-evaluated
           :request-connection-info
           :request-swank-require
           :request-init-presentations
           :request-create-repl
           :request-listener-eval
           :read-message
           :read-all-messages)
  (:export :connection-package
           :connection-pid
           :connection-implementation-name
           :connection-implementation-version
           :connection-machine-type
           :connection-machine-version
           :connection-swank-version)
  (:documentation "Low-level implementation of a client for the Swank protocol."))
(in-package :lem-lisp-mode.swank-protocol)

(define-condition disconnected (simple-condition)
  ())

(defmacro with-swank-syntax (() &body body)
  `(with-standard-io-syntax
     (let ((*package* (find-package :swank-io-package))
           (*print-case* :downcase))
       ,@body)))

;;; Prevent reader errors

(eval-when (:compile-toplevel :load-toplevel)
  (swank:swank-require '(swank-presentations swank-repl)))

;;; Encoding and decoding messages

(defun encode-integer (integer)
  "Encode an integer to a 0-padded 16-bit hexadecimal string."
  (babel:string-to-octets (format nil "~6,'0,X" integer)))

(defun decode-integer (string)
  "Decode a string representing a 0-padded 16-bit hex string to an integer."
  (parse-integer string :radix 16))

;; Writing and reading messages to/from streams

(defun write-message-to-stream (stream message)
  "Write a string to a stream, prefixing it with length information for Swank."
  (let* ((octets (babel:string-to-octets message))
         (length-octets (encode-integer (length octets)))
         (msg (make-array (+ (length length-octets)
                             (length octets))
                          :element-type '(unsigned-byte 8))))
    (replace msg length-octets)
    (replace msg octets :start1 (length length-octets))
    (write-sequence msg stream)))

(defun read-message-from-stream (stream)
  "Read a string from a string.

Parses length information to determine how many characters to read."
  (let ((length-buffer (make-array 6 :element-type '(unsigned-byte 8))))
    (when (/= 6 (read-sequence length-buffer stream))
      (error 'disconnected))
    (let* ((length (decode-integer (babel:octets-to-string length-buffer)))
           (buffer (make-array length :element-type '(unsigned-byte 8))))
      (read-sequence buffer stream)
      (babel:octets-to-string buffer))))

;;; Data

(defclass connection ()
  ((hostname
    :reader connection-hostname
    :initarg :hostname
    :type string
    :documentation "The host to connect to.")
   (port
    :reader connection-port
    :initarg :port
    :type integer
    :documentation "The port to connect to.")
   (socket
    :reader connection-socket
    :initarg :socket
    :type usocket:stream-usocket
    :documentation "The usocket socket.")
   (request-count
    :accessor connection-request-count
    :initform 0
    :type integer
    :documentation "A number that is increased and sent along with every request.")
   (package
    :accessor connection-package
    :initform "COMMON-LISP-USER"
    :type string
    :documentation "The name of the connection's package.")
   (prompt-string
    :accessor connection-prompt-string
    :type string)
   (process
    :initform nil
    :accessor connection-process)
   (continuations
    :accessor connection-continuations
    :initform nil)
   (logp :accessor connection-log-p
         :initarg :logp
         :initform nil
         :type boolean
         :documentation "Whether or not to log connection requests.")
   (logging-stream :accessor connection-logging-stream
                   :initarg :logging-stream
                   :initform *error-output*
                   :type stream
                   :documentation "The stream to log to.")
   (debug-level :accessor connection-debug-level
                :initform 0
                :type integer
                :documentation "The depth at which the debugger is called.")
   (pid :accessor connection-pid
        :type integer
        :documentation "The PID of the Swank server process.")
   (implementation-name :accessor connection-implementation-name
                        :type string
                        :documentation "The name of the implementation running
 the Swank server.")
   (implementation-version :accessor connection-implementation-version
                           :type string
                           :documentation "The version string of the
 implementation running the Swank server.")
   (machine-type :accessor connection-machine-type
                 :type string
                 :documentation "The server machine's architecture.")
   (machine-version :accessor connection-machine-version
                    :type string
                    :documentation "The server machine's processor type.")
   (swank-version :accessor connection-swank-version
                  :type string
                  :documentation "The server's Swank version.")
   (features :accessor connection-features)
   (info :accessor connection-info))
  (:documentation "A connection to a remote Lisp."))

(defun new-connection (hostname port)
  (let* ((socket (usocket:socket-connect hostname port :element-type '(unsigned-byte 8)))
         (connection (make-instance 'connection
                                    :hostname hostname
                                    :port port
                                    :socket socket)))
    (setup connection)
    connection))

(defun setup (connection)
  (emacs-rex connection `(swank:connection-info))
  ;; Read the connection information message
  (let* ((info (read-message connection))
         (data (getf (getf info :return) :ok))
         (impl (getf data :lisp-implementation))
         (machine (getf data :machine)))
    (setf (connection-info connection) info)
    (setf (connection-pid connection)
          (getf data :pid)
          (connection-implementation-name connection)
          (getf impl :name)
          (connection-implementation-version connection)
          (getf impl :version)
          (connection-machine-type connection)
          (getf machine :type)
          (connection-machine-version connection)
          (getf machine :version)
          (connection-swank-version connection)
          (getf data :version)
          (connection-features connection)
          (getf data :features)
          (connection-package connection)
          (getf (getf data :package) :name)
          (connection-prompt-string connection)
          (getf (getf data :package) :prompt)
          ))
  ;; Require some Swank modules
  (request-swank-require
   connection
   '(swank-trace-dialog
     swank-package-fu
     swank-presentations
     swank-fuzzy
     swank-fancy-inspector
     swank-c-p-c
     swank-arglists
     swank-repl))
  (read-message connection)
  ;; Start it up
  (emacs-rex connection '(swank:init-presentations))
  (emacs-rex connection '(swank-repl:create-repl nil :coding-system "utf-8-unix"))
  ;; Wait for startup
  (read-message connection)
  ;; Read all the other messages, dumping them
  (read-all-messages connection))

(defun log-message (connection format-string &rest arguments)
  "Log a message."
  (when (connection-log-p connection)
    (apply #'format
           (connection-logging-stream connection)
           format-string
           arguments)))

(defun read-message-string (connection)
  "Read a message string from a Swank connection.

This function will block until it reads everything. Consider message-waiting-p
to check if input is available."
  (let* ((socket (connection-socket connection))
         (stream (usocket:socket-stream socket)))
    (when (usocket:wait-for-input socket :timeout 5)
      (let ((msg (read-message-from-stream stream)))
        (log-message connection "~%Read: ~A~%" msg)
        msg))))

(defun send-message-string (connection message)
  "Send a message string to a Swank connection."
  (let* ((socket (connection-socket connection))
         (stream (usocket:socket-stream socket)))
    (write-message-to-stream stream message)
    (force-output stream)
    (log-message connection "~%Sent: ~A~%" message)
    message))

(defun send-message (connection form)
  (send-message-string connection
                       (with-swank-syntax ()
                         (prin1-to-string form))))

(defun message-waiting-p (connection &key (timeout 0))
  "t if there's a message in the connection waiting to be read, nil otherwise."
  (if (usocket:wait-for-input (connection-socket connection)
                              :ready-only t
                              :timeout timeout)
      t
      nil))

;;; Sending messages

(defun emacs-rex-string (connection string &key continuation thread package)
  (let ((msg (format nil "(:emacs-rex ~A ~S ~A ~A)"
                     string
                     (or package
                         (connection-package connection))
                     (or thread t)
                     (incf (connection-request-count connection)))))
    (when continuation
      (push (cons (connection-request-count connection)
                  continuation)
            (connection-continuations connection)))
    (send-message-string connection msg)))

(defun emacs-rex (connection form &key continuation thread package)
  (emacs-rex-string connection
                    (with-swank-syntax ()
                      (prin1-to-string form))
                    :continuation continuation
                    :thread thread
                    :package package))

(defun finish-evaluated (connection value id)
  (let ((elt (assoc id (connection-continuations connection))))
    (when elt
      (setf (connection-continuations connection)
            (remove id (connection-continuations connection) :key #'car))
      (funcall (cdr elt) value))))

(defun request-swank-require (connection requirements)
  "Request that the Swank server load contrib modules.
`requirements` must be a list of symbols, e.g. '(swank-repl swank-media)."
  (emacs-rex connection
             `(swank:swank-require ',(loop for item in requirements collecting
                                       (intern (symbol-name item)
                                               (find-package :swank-io-package))))))

(defun request-listener-eval (connection string &optional continuation)
  "Request that Swank evaluate a string of code in the REPL."
  (emacs-rex connection `(swank-repl:listener-eval ,string)
             :continuation continuation
             :thread ":repl-thread"))

;;; Reading/parsing messages

(defun read-atom (in)
  (let ((token
         (coerce (loop :for c := (peek-char nil in nil)
                       :until (or (null c) (member c '(#\( #\) #\space #\newline #\tab)))
                       :collect c
                       :do (read-char in))
                 'string)))
    (handler-case (read-from-string token)
      (error ()
        (let ((name (ppcre:scan-to-strings "::?.*" token)))
          (intern (string-upcase (string-left-trim ":" name))
                  :keyword))))))

(defun read-list (in)
  (read-char in)
  (loop :until (eql (peek-char t in) #\))
        :collect (read-ahead in)
        :finally (read-char in)))

(defun read-ahead (in)
  (let ((c (peek-char t in)))
    (case c
      ((#\()
       (read-list in))
      ((#\")
       (read in))
      (otherwise
       (read-atom in)))))

(defun read-from-string* (string)
  (with-input-from-string (in string)
    (read-ahead in)))

(defun read-message (connection)
  "Read an arbitrary message from a connection."
  (with-swank-syntax ()
    (read-from-string* (read-message-string connection))))

(defun read-all-messages (connection)
  (loop while (message-waiting-p connection) collecting
    (read-message connection)))
