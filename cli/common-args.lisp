;;;; CLI common arguments
;;;;
;;;; This software is part of CLPM. See README.org for more information. See
;;;; LICENSE for license information.

(uiop:define-package #:clpm-cli/common-args
    (:use #:cl
          #:clpm/version)
  (:import-from #:adopt)
  (:export #:*group-common*
           #:*option-context*
           #:*option-help*
           #:*option-local*
           #:*option-yes*
           #:*option-verbose*))

(in-package #:clpm-cli/common-args)

(defparameter *option-help*
  (adopt:make-option :help
                     :long "help"
                     :help "Display help and exit"
                     :reduce (constantly t)))

(defparameter *option-local*
  (adopt:make-option
   :cli-config-local
   :initial-value :missing
   :long "local"
   :help "Do not sync remote sources, use only the data located in the local cache"
   :reduce (constantly t)))

(defparameter *option-yes*
  (adopt:make-option
   :yes
   :short #\y
   :long "yes"
   :help "Answer yes to all questions"
   :reduce (constantly t)))

(defparameter *option-verbose*
  (adopt:make-option :cli-config-log-level
                     :long "verbose"
                     :short #\V
                     :help "Increase verbosity of output. Can be specified multiple times."
                     :initial-value 0
                     :reduce #'1+))

(defparameter *group-common*
  (adopt:make-group :common
                    :title "Common"
                    :help "Options common to all CLPM operations"
                    :options (list *option-help*
                                   *option-verbose*)))

(defparameter *option-context*
  (adopt:make-option :cli-config-context
                     :initial-value :missing
                     :long "context"
                     :help "Set the context in which to operate"
                     :parameter "CONTEXT"
                     :reduce #'adopt:last))
