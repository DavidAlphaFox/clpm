;;;; Miscellaneous utilities
;;;;
;;;; This software is part of CLPM. See README.org for more information. See
;;;; LICENSE for license information.

(uiop:define-package #:clpm/utils
    (:use #:cl
          #:puri
          #:split-sequence)
  (:export #:*live-script-location*
           #:retriable-error
           #:run-program-augment-env-args
           #:uri-to-string
           #:with-retries))

(in-package #:clpm/utils)

(defvar *live-script-location* nil
  "If loaded from scripts/clpm-live, this is set to the pathname where the
clpm-live script is located.")

(defun clear-live-script-location ()
  "On image dump, remove the pathname to the clpm-live script."
  (setf *live-script-location* nil))
(uiop:register-image-dump-hook 'clear-live-script-location)

#+sbcl
(defun run-program-augment-env-args (new-env-alist)
  "Given an alist of environment variables, return a list of arguments suitable
for ~uiop:{launch/run}-program~ to set the augmented environment for the child
process."
  (let* ((inherited-env
           (remove-if (lambda (x)
                        (let ((name (first (split-sequence #\= x))))
                          (member name new-env-alist :test #'equal :key #'car)))
                      (sb-ext:posix-environ)))
         (env (append (mapcar (lambda (c)
                                (concatenate 'string (car c) "=" (cdr c)))
                              new-env-alist)
                      inherited-env)))
    (list :environment env)))

#-sbcl
(defun run-program-augment-env-args (new-env-alist)
  (error "not implemented"))

(defun uri-to-string (uri)
  "Convert a puri URI to a string."
  (with-output-to-string (s)
    (render-uri uri s)))

(define-condition retriable-error (error)
  ())

(defun call-with-retries (thunk &key (max 3) (sleep 1))
  (let ((num-tries 1))
    (block nil
      (tagbody
       top
         (handler-case
             (return (funcall thunk))
           (retriable-error (e)
             (format *error-output* "~&Get error ~S~%" e)
             (when (< num-tries max)
               (incf num-tries)
               (format *error-output* "Sleeping and retrying~%")
               (sleep sleep)
               (go top))
             (error e)))))))

(defmacro with-retries ((&key (max 3) (sleep 1)) &body body)
  `(call-with-retries (lambda () ,@body) :max ,max :sleep ,sleep))
