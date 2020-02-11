;;;; Flat file source definitions
;;;;
;;;; This software is part of CLPM. See README.org for more information. See
;;;; LICENSE for license information.

;; * define-package
(uiop:define-package #:clpm/sources/flat-file
    (:use #:cl
          #:alexandria
          #:clpm/cache
          #:clpm/data
          #:clpm/repos
          #:clpm/sources/defs
          #:clpm/sources/vcs-release
          #:clpm/utils
          #:do-urlencode
          #:puri
          #:split-sequence)
  (:export #:flat-file-project
           #:flat-file-release
           #:ff-source
           #:ff-source-project-class
           #:ff-source-release-class
           #:ff-source-repo-metadata-pathname
           #:ff-source-repo-pathname
           #:ff-source-repo-project-index-pathname
           #:ff-source-repo-project-pathname
           #:ff-source-repo-projects-pathname
           #:ff-source-repo-system-index-pathname
           #:ff-source-repo-system-pathname
           #:ff-source-repo-systems-pathname
           #:flat-file-system-release
           #:flat-file-system-release-dependencies
           #:ff-source-system-release-class))

(in-package #:clpm/sources/flat-file)

(defclass ff-source (clpm-source)
  ((projects-map
    :initform (make-hash-table :test 'equal)
    :reader ff-source-projects-map
    :documentation "Maps project names to project instances")
   (systems-map
    :initform (make-hash-table :test 'equal)
    :reader ff-source-systems-map
    :documentation "Maps project names to project instances"))
  (:documentation
   "A source that stores its metadata in a series of files."))

(defgeneric ff-source-project-class (source))

(defmethod ff-source-project-class ((source ff-source))
  'flat-file-project)

(defgeneric ff-source-system-class (source))

(defmethod ff-source-system-class ((source ff-source))
  'flat-file-system)

(defgeneric ff-source-system-file-class (source))

(defmethod ff-source-system-file-class ((source ff-source))
  'flat-file-system-file)

(defgeneric ff-source-system-release-class (source))

(defmethod ff-source-system-release-class ((source ff-source))
  'flat-file-system-release)

(defgeneric ff-source-release-class (source))

(defmethod ff-source-release-class ((source ff-source))
  'flat-file-release)

(defgeneric ff-source-repo-pathname (source))

(defun ff-source-repo-project-index-pathname (source)
  (merge-pathnames "project-index" (ff-source-repo-pathname source)))

(defun ff-source-repo-project-pathname (source project-name)
  (merge-pathnames (make-pathname :directory (list :relative (urlencode project-name)))
                   (ff-source-repo-projects-pathname source)))

(defun ff-source-repo-projects-pathname (source)
  (merge-pathnames "projects/" (ff-source-repo-pathname source)))

(defun ff-source-repo-system-index-pathname (source)
  (merge-pathnames "system-index" (ff-source-repo-pathname source)))

(defun ff-source-repo-system-pathname (source system-name)
  (merge-pathnames (make-pathname :directory (list :relative (urlencode system-name)))
                   (ff-source-repo-systems-pathname source)))

(defun ff-source-repo-systems-pathname (source)
  (merge-pathnames "systems/" (ff-source-repo-pathname source)))

(defun ff-source-repo-metadata-pathname (source)
  (merge-pathnames "metadata" (ff-source-repo-pathname source)))

(defmethod source-project ((source ff-source) project-name &optional (error t))
  (ensure-gethash
   project-name (ff-source-projects-map source)

   (let ((pathname (ff-source-repo-project-pathname source project-name)))
     (unless (uiop:probe-file* pathname)
       (if error
           (error 'source-missing-project
                  :source source
                  :project-name project-name)
           ;; Do not cache a negative hit.
           (return-from source-project nil)))
     (make-instance (ff-source-project-class source)
                    :source source
                    :name project-name))))

(defmethod source-ensure-system ((source ff-source) system-name)
  (ensure-gethash
   system-name (ff-source-systems-map source)
   (make-instance (ff-source-system-class source)
                  :source source
                  :name system-name)))

(defmethod source-system ((source ff-source) system-name &optional (error t))
  (ensure-gethash
   system-name (ff-source-systems-map source)

   (let ((pathname (merge-pathnames "releases"
                                    (ff-source-repo-system-pathname source system-name))))
     (unless (probe-file pathname)
       (if error
           (error 'source-missing-system
                  :source source
                  :system-name system-name)
           ;; Do not cache a negative hit.
           (return-from source-system nil)))
     (make-instance (ff-source-system-class source)
                    :source source
                    :name system-name))))

(defmethod source-projects ((source ff-source))
  (let ((dir (directory (merge-pathnames (make-pathname :directory '(:relative :wild))
                                         (ff-source-repo-projects-pathname source)))))
    (mapcar (lambda (pn)
              (source-project source (last-elt (pathname-directory pn))))
            dir)))

(defmethod source-systems ((source ff-source))
  (let ((dir (directory (uiop:wilden (ff-source-repo-systems-pathname source)))))
    (mapcar (lambda (pn)
              (source-system source (urldecode (last-elt (pathname-directory pn)))))
            dir)))


;; * Projects

(defclass flat-file-project (clpm-project)
  ((source
    :initarg :source
    :reader project-source
    :documentation "The source that provides this project.")
   (name
    :initarg :name
    :reader project-name
    :documentation "The name of the project.")
   (releases-map
    :accessor flat-file-project-releases-map)
   (vcs-releases-map
    :initform (make-hash-table :test 'equal)
    :reader flat-file-project-vcs-releases-map)
   (repo
    :accessor project-repo)))

(defun %populate-project-releases! (project)
  "Open the releases file, read it, and instantiate release objects for each
  release."
  (let ((releases-map (make-hash-table :test 'equal)))
    (uiop:with-safe-io-syntax ()
      (with-open-file (s (%project-releases-pathname project))
        (with-forms-from-stream (s form)
          (setf (gethash (first form) releases-map)
                (apply #'make-instance (ff-source-release-class (project-source project))
                       :source (project-source project)
                       :project project
                       :version form)))))
    (setf (flat-file-project-releases-map project) releases-map)))

(defun %populate-project-metadata! (project)
  "Open the metadata file, read it, and shove everything in the correct slots."
  (uiop:with-safe-io-syntax ()
    (with-open-file (s (%project-metadata-pathname project))
      (with-forms-from-stream (s f)
        (destructuring-bind (type data) f
          (case type
            (:repo
             (setf (project-repo project) (make-repo-from-description data)))))))))

(defmethod slot-unbound (class (project flat-file-project) (slot-name (eql 'releases-map)))
  (%populate-project-releases! project)
  (flat-file-project-releases-map project))

(defmethod slot-unbound (class (project flat-file-project) (slot-name (eql 'repo)))
  (%populate-project-metadata! project)
  (project-repo project))

(defun %project-root-pathname (project)
  (uiop:ensure-directory-pathname
   (ff-source-repo-project-pathname (project-source project) (project-name project))))

(defun %project-metadata-pathname (project)
  (merge-pathnames "metadata" (%project-root-pathname project)))

(defun %project-releases-pathname (project)
  (merge-pathnames "releases" (%project-root-pathname project)))

(defmethod project-release ((project flat-file-project) (version-string list) &optional error)
  (declare (ignore error))
  (apply #'project-vcs-release project version-string))

(defmethod project-release ((project flat-file-project) version &optional (error t))
  (or (gethash version (flat-file-project-releases-map project))
      (when error
        (error 'project-missing-version
               :source (project-source project)
               :project project
               :version version))))

(defmethod project-releases ((project flat-file-project))
  (hash-table-values (flat-file-project-releases-map project)))

(defmethod project-vcs-release ((project flat-file-project) &key commit branch tag)
  (let ((ref (cond
               (commit `(:commit ,commit))
               (branch `(:branch ,branch))
               (tag `(:tag ,tag)))))
    (ensure-gethash ref (flat-file-project-vcs-releases-map project)
                    (make-instance 'vcs-release
                                   :source (project-source project)
                                   :project project
                                   :ref ref))))


;; * Releases

(defclass flat-file-release (clpm-release)
  ((source
    :initarg :source
    :reader release-source
    :documentation "The source that provides this release.")
   (project
    :initarg :project
    :reader release-project
    :documentation "The project this release is a part of.")

   (version
    :initarg :version
    :reader release-version
    :documentation "The version of this release.")
   (system-files
    :initarg :system-files
    :initform nil
    :documentation "List of paths to system files in this release.")
   (system-names
    :initarg :systems
    :documentation "List of system names provided by this release.")
   (systems-map
    :reader flat-file-release-systems-map
    :documentation "Map of system names to system objects provided by this
    release.")))

(defmethod slot-unbound (class (release flat-file-release) (slot-name (eql 'systems-map)))
  (let ((out (make-hash-table :test 'equal)))
    (dolist (system-name (slot-value release 'system-names))
      (setf (gethash system-name out) (source-system (release-source release) system-name)))
    (setf (slot-value release slot-name) out)))

(defmethod release-system-release ((release flat-file-release) system-name &optional (error t))
  (let ((system (gethash system-name (flat-file-release-systems-map release))))
    (when (and error (not system))
      (error 'release-missing-system-release
             :source (release-source release)
             :release release
             :system-name system-name))
    (when system
      (let ((system-release (gethash (list (project-name (release-project release))
                                           (release-version release))
                                     (flat-file-system-releases-map system))))
        (unless system-release
          (error "Unknown error! Cannot find the correct system release!"))
        system-release))))

(defmethod release-systems ((release flat-file-release))
  (hash-table-values (flat-file-release-systems-map release)))

(defmethod release-system-files ((release flat-file-release))
  (remove-duplicates (mapcar #'system-release-system-file (release-system-releases release))))


;; * Systems

(defclass flat-file-system (clpm-system)
  ((source
    :initarg :source
    :reader system-source
    :documentation "The source that provides this system.")
   (name
    :initarg :name
    :reader system-name
    :documentation "The name of the system.")

   (system-releases-map
    :reader flat-file-system-releases-map
    :documentation "Maps release specs to system-release objects.")))

(defmethod slot-unbound (class (system flat-file-system) (slot-name (eql 'system-releases-map)))
  "Read the system file, instantiating system-release objects for each release
  of the system."

  (let ((map (make-hash-table :test 'equal)))
    (uiop:with-safe-io-syntax ()
      (with-open-file (s (merge-pathnames "releases"
                                          (ff-source-repo-system-pathname
                                           (system-source system)
                                           (system-name system)))
                         :if-does-not-exist nil)
        (when s
          (with-forms-from-stream (s form)
            (destructuring-bind (release-spec &rest initargs &key &allow-other-keys) form
              (setf (gethash release-spec map)
                    (apply #'make-instance
                           (ff-source-system-release-class (system-source system))
                           :source (system-source system)
                           :system-name (system-name system)
                           :release-spec release-spec
                           :system system
                           initargs)))))))
    (setf (slot-value system slot-name) map)))

(defmethod system-register-release! ((system flat-file-system) release)
  (setf (gethash (release-version release) (flat-file-system-releases-map system)) release))

(defmethod system-releases ((system flat-file-system))
  (mapcar #'system-release-release (system-system-releases system)))

(defmethod system-system-releases ((system flat-file-system))
  (hash-table-values (flat-file-system-releases-map system)))


;; * System releases

(defclass flat-file-system-release (clpm-system-release)
  ((source
    :initarg :source
    :reader system-release-source
    :documentation "The source that provides this system release.")
   (system-name
    :initarg :system-name
    :reader flat-file-system-release-system-name
    :documentation "The name of the system this system release is for.")
   (release-spec
    :initarg :release-spec
    :reader flat-file-system-release-release-spec
    :documentation "A specification of which release this system release belongs to.")

   (system-version
    :initarg :version
    :reader system-release-system-version
    :documentation "The version of the system.")
   (system
    :initarg :system
    :reader system-release-system
    :documentation "The system this system release belongs to.")
   (release
    :initarg :release
    :reader system-release-release
    :documentation "The release this system release belongs to.")

   (asd-enough-namestring
    :initarg :system-file
    :reader system-release-asd-pathname)
   (dependencies
    :initarg :dependencies
    :initform nil
    :reader flat-file-system-release-dependencies)
   (system-file
    :reader system-release-system-file)))

(defmethod slot-unbound (class (system-release flat-file-system-release) (slot-name (eql 'system)))
  (setf (slot-value system-release slot-name)
        (source-system (system-release-source system-release)
                       (flat-file-system-release-system-name system-release))))

(defmethod slot-unbound (class (system-release flat-file-system-release) (slot-name (eql 'release)))
  (destructuring-bind (project-name version)
      (flat-file-system-release-release-spec system-release)
    (setf (slot-value system-release slot-name)
          (source-project-release (system-release-source system-release) project-name version))))

(defmethod slot-unbound (class (system-release flat-file-system-release) (slot-name (eql 'system-file)))
  (setf (slot-value system-release slot-name)
        (make-instance (ff-source-system-file-class (system-release-source system-release))
                       :source (system-release-source system-release)
                       :release (system-release-release system-release)
                       :asd-enough-namestring (system-release-asd-pathname system-release))))


;; * System files

(defclass flat-file-system-file (clpm-system-file)
  ((source
    :initarg :source
    :reader system-file-source
    :documentation "The source that provides this system file.")

   (release
    :initarg :release
    :reader system-file-release)
   (asd-enough-namestring
    :initarg :asd-enough-namestring
    :reader system-file-asd-enough-namestring
    :documentation "The namestring pointing to the asd file within the release.")))

(defmethod system-file-system-releases ((system-file flat-file-system-file))
  (release-system-releases (system-file-release system-file)))

(defmethod system-file-absolute-asd-pathname ((system-file flat-file-system-file))
  (merge-pathnames (system-file-asd-enough-namestring system-file)
                   (release-lib-pathname (system-file-release system-file))))
