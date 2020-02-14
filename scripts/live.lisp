;;;; When loaded, this starts CLPM's main method
;;;;
;;;; This software is part of CLPM. See README.org for more information. See
;;;; LICENSE for license information.

(in-package #:cl-user)

(load (merge-pathnames "common.lisp"
                       *load-truename*))

(in-package #:clpm-scripts)

(load (merge-pathnames "../logical-pathname.lisp" *load-truename*))

(setup-asdf "live")

;; Load CLPM
(flet ((load-clpm ()
         (let* ((compilation-visible-p (equal (uiop:getenv "CLPM_LIVE_COMPILATION_VISIBLE") "true"))
                (output-stream (if compilation-visible-p
                                   *error-output*
                                   (make-string-output-stream)))
                (stderr *error-output*)
                (*error-output* output-stream)
                (*standard-output* output-stream))
           (handler-bind
               ((error (lambda (e)
                         (unless compilation-visible-p
                           (write-string (get-output-stream-string output-stream) stderr)
                           (terpri stderr))
                         (format stderr "~&Error while compiling CLPM: ~S~%" e)
                         (uiop:print-condition-backtrace e :stream stderr))))
             (asdf:load-system :clpm)))))
  (load-clpm))

;; Record the pathname to this script.
(setf clpm/utils:*live-script-location* (uiop:native-namestring *load-truename*))

(when (equal (uiop:getenv "CLPM_LIVE_PRIVATE_REPL") "true")
  (sb-impl::toplevel-repl nil))

(let ((clpm-sys (asdf:find-system :clpm)))
  (handler-bind ((error (lambda (c)
                          (uiop:print-condition-backtrace c))))
    (let ((result (uiop:call-function (asdf::component-entry-point clpm-sys))))
      (uiop:quit (if result 0 1)))))
