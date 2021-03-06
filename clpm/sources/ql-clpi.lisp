;;;; QL-CLPI sources
;;;;
;;;; This software is part of CLPM. See README.org for more information. See
;;;; LICENSE for license information.

;; * define-package
(uiop:define-package #:clpm/sources/ql-clpi
    (:use #:cl
          #:alexandria
          #:clpm/session
          #:clpm/sources/clpi
          #:clpm/sources/defs
          #:clpm/utils
          #:clpm/version-strings)
  (:import-from #:clpi)
  (:import-from #:ql-clpi)
  (:export #:ql-clpi-dual-source
           #:ql-clpi-source))

(in-package #:clpm/sources/ql-clpi)


;; * Source

(defclass ql-clpi-source (clpi-source)
  ())

(defclass ql-clpi-dual-source (ql-clpi-source clpi-dual-source)
  ())

(defmethod clpi-source-index-type ((source ql-clpi-source))
  'ql-clpi:ql-index)

(defmethod make-source ((type (eql 'ql-clpi-dual-source)) &rest initargs
                        &key url name
                        &allow-other-keys)
  (let ((url-string (if (stringp url) url (uri-to-string url))))
    (with-clpm-session (:key `(make-source ,type ,name ,url-string))
      (apply #'make-instance
             type
             initargs))))

(defmethod source-type-keyword ((source ql-clpi-source))
  :ql-clpi)

(defmethod clpi-source-release-class ((source ql-clpi-source))
  'ql-clpi-release)


;; * Release

(defclass ql-clpi-release (clpi-release)
  ())

(defmethod release-satisfies-version-spec-p ((release ql-clpi-release) version-spec)
  (let* ((version (release-version release))
         (version-aliases (ql-clpi:project-version-aliases (clpi:project (clpi-backing-object release))
                                                           version)))
    (some (curry #'version-spec-satisfied-p/simple-string version-spec)
          (list* version version-aliases))))
