;;;; Context Queries
;;;;
;;;; This software is part of CLPM. See README.org for more information. See
;;;; LICENSE for license information.

(uiop:define-package #:clpm/context-queries
    (:use #:cl
          #:clpm/context
          #:clpm/session)
  (:export #:asd-pathnames
           #:find-system-asd-pathname
           #:output-translations))

(in-package #:clpm/context-queries)

(defun asd-pathnames (&key context)
  (with-clpm-session ()
    (context-asd-pathnames (get-context context))))

(defun find-system-asd-pathname (system-name &key context)
  (with-clpm-session ()
    (context-find-system-asd-pathname (get-context context) system-name)))

(defun output-translations (&key context)
  (with-clpm-session ()
    (context-output-translations (get-context context))))
