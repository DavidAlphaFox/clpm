;;;; Quicklisp derived sources
;;;;
;;;; This software is part of CLPM. See README.org for more information. See
;;;; LICENSE for license information.

(uiop:define-package #:clpm/sources/quicklisp
    (:use #:cl
          #:alexandria
          #:anaphora
          #:clpm/cache
          #:clpm/data
          #:clpm/http-client
          #:clpm/log
          #:clpm/requirement
          #:clpm/sources/db-backed
          #:clpm/sources/defs
          #:clpm/sources/simple-versioned-project
          #:clpm/sources/tarball-release
          #:clpm/utils
          #:puri
          #:split-sequence)
  (:import-from #:dbi
                #:with-transaction)
  (:export #:quicklisp-source))

(in-package #:clpm/sources/quicklisp)

(setup-logger)

;;; This package allows CLPM to natively interact with Quicklisp
;;; distributions. It is tested primarily on the main Quicklisp distribution
;;; (quicklisp), but should nearly work on other distributions as well, such as
;;; ultralisp or cl21.
;;;
;;; Interacting with Quicklisp distributions is a little painful because of the
;;; different design focuses of each project. CLPM needs to be able to determine
;;; information on all the previous releases of a system (preferably quickly!)
;;; whereas Quicklisp distributions are designed to make data easily accessible
;;; for only a single version of a distribution. As such, CLPM needs to crawl
;;; all distribution versions and index their data locally.
;;;
;;; In the future, I would like the CLPM project to grow and host metadata for
;;; the most popular Quicklisp derived distributions in a format that is easy
;;; for CLPM to fetch and incorporate. But there will always be a place for this
;;; package, as I would like to continue supporting private Quicklisp
;;; distributions that can't be indexed by the CLPM project or just random
;;; public ones that may pop up.
;;;
;;; The data for Quicklisp distributions is stored in a sqlite database.


;;; * Quicklisp backed source

(defclass quicklisp-source (clpm-source db-backed-source)
  ((force-https
    :initarg :force-https
    :initform nil
    :accessor ql-force-https
    :documentation
    "~T~ iff this source should download everything over HTTPS.")
   (versions-url
    :accessor ql-versions-url
    :documentation
    "Holds the URL to the .txt file that stores all versions of this source."))
  (:documentation
   "A CLPM source backed by a quicklisp-style repository."))

(defclass ql-source-meta (db-backed-source-meta)
  ()
  (:metaclass dao-table-class))

(defmethod db-source-indices ((source quicklisp-source))
  '((:key_ql-release-meta_project-name_url
     :ql_release_meta :project_name :url)
    (:key_ql-release_meta-id_dist-version-id
     :ql_release :meta_id :dist_version_id)
    (:key_ql-release_project-name_dist-version-id
     :ql_release :project_name :dist_version_id)
    (:key_ql-system-release_release-id_system-name
     :ql_system_release :release_id :system_name)))

(defmethod db-source-table-names ((source quicklisp-source))
  '(ql-dist-version ql-project ql-release
    ql-release-meta ql-system ql-system-release ql-source-meta))

(defmethod db-source-meta-class-name ((source quicklisp-source))
  'ql-source-meta)

(defmethod initialize-instance :after ((source quicklisp-source) &rest initargs
                                       &key &allow-other-keys)
  "If the source is being forced to HTTPS, update the base URL accordingly. If
  the base URL is HTTPS, ensure the force-https flag is set (presumably that is
  what the user intends). Last, computes the versions URL."
  (declare (ignore initargs))
  (when (ql-force-https source)
    (ensure-uri-scheme-https! (source/url source)))
  ;; If the uri is given as https, assume the user wants to fetch everything
  ;; from this source over https.
  (when (and (not (ql-force-https source))
             (eql (uri-scheme (source/url source)) :https))
    (setf (ql-force-https source) t))
  ;; Compute the versions url. Example:
  ;; http://beta.quicklisp.org/dist/quicklisp.txt ->
  ;; http://beta.quicklisp.org/dist/quicklisp-versions.txt
  (let* ((path (puri:uri-path (source/url source)))
         (file-name (pathname-name path)))
    (setf (ql-versions-url source)
          (merge-uris (namestring
                       (merge-pathnames (concatenate 'string file-name "-versions")
                                        path))
                      (source/url source)))))

(defmethod source/cache-directory ((source quicklisp-source))
  "Compute the cache location for this source, based on its canonical url."
  (clpm-cache-pathname
   `("sources"
     "quicklisp"
     ,(string-downcase (string (uri-scheme (source/url source))))
     ,(uri-host (source/url source))
     ,@(split-sequence #\/ (uri-path (source/url source)) :remove-empty-subseqs t))
   :ensure-directory t))

(defmethod source/lib-directory ((source quicklisp-source))
  "Compute the data location for this source, based on its canonical url."
  (clpm-data-pathname
   `("sources"
     "quicklisp"
     ,(string-downcase (string (uri-scheme (source/url source))))
     ,(uri-host (source/url source))
     ,@(split-sequence #\/ (uri-path (source/url source)) :remove-empty-subseqs t))
   :ensure-directory t))

(defmethod source/project-release ((source quicklisp-source) project-name version-string)
  (with-source-connection (source)
    (find-dao 'ql-release
              :project-name project-name
              :dist-version-id version-string)))

(defmethod source/project ((source quicklisp-source) project-name)
  (with-source-connection (source)
    (find-dao 'ql-project :name project-name)))

(defmethod source/system ((source quicklisp-source) system-name)
  (with-source-connection (source)
    (find-dao 'ql-system :name system-name)))

(defmethod source-type-keyword ((source quicklisp-source))
  :quicklisp)

(defmethod source-to-form ((source quicklisp-source))
  (list (source/name source)
        :url (uri-to-string (source/url source))
        :type :quicklisp
        :force-https (ql-force-https source)))

(defun ql-source-local-versions (source)
  "Return all ~ql-dist-version~ objects. These represent all versions of the
  source we know about (but not all of them may be synced!)."
  (with-source-connection (source)
    (retrieve-dao 'ql-dist-version)))


;;; * Version of a quicklisp distribution

(defclass ql-dist-version (db-backed-mixin)
  ((id
    :initarg :id
    :accessor ql-dist-version-id
    :col-type :text
    :primary-key t
    :reader object-id
    :documentation
    "A string naming this version. Typically time based.")
   (synced-int
    :initarg :synced-int
    :initform 0
    :accessor ql-dist-version-synced-int
    :col-type (:tinyint () :unsigned)
    :documentation
    "1 if this version has been synced (all releases and systems incorporated
    into the db), 0 otherwise.")
   (canonical-distinfo-url
    :initarg :canonical-distinfo-url
    :initform nil
    :accessor ql-dist-version-canonical-distinfo-url
    :col-type :text
    :documentation
    "The canonical URL for this version's =distinfo.txt= file.")
   (system-index-url
    :initarg :system-index-url
    :initform nil
    :accessor ql-dist-version-system-index-url
    :col-type (or :text :null)
    :documentation
    "The URL for this version's =systems.txt= file.")
   (release-index-url
    :initarg :release-index-url
    :initform nil
    :accessor ql-dist-version-release-index-url
    :col-type (or :text :null)
    :documentation
    "The URL for this version's =releases.txt= file."))
  (:metaclass dao-table-class)
  (:record-timestamps nil)
  (:documentation
   "Table representing a version of a quicklisp source."))

(defun ql-source-unsynced-dist-versions (source)
  "Returns a list of the unsynced versions of the ~source~ distribution."
  (with-source-connection (source)
    (retrieve-dao 'ql-dist-version :synced-int 0)))

(defun ql-dist-version-synced-p (dist-version)
  "Returns ~T~ iff ~dist-version~ is synced."
  (not (zerop (ql-dist-version-synced-int dist-version))))

(define-condition ql-dist-version-missing ()
  ((source
    :initarg :source)
   (version-id
    :initarg :version-id)))

(defun parse-distinfo-line (line)
  "Parse a single line of a distinfo.txt file."
  (let* ((colon-pos (position #\: line))
         (property (make-keyword (uiop:standard-case-symbol-name
                                  (subseq line 0 colon-pos))))
         (value (subseq line (+ 2 colon-pos))))
    (list property value)))

(defun parse-distinfo (distinfo)
  "Givean a distinfo.txt file as a string, return a plist of its contents."
  (let* ((lines (split-sequence #\Newline distinfo :remove-empty-subseqs t)))
    (mapcan #'parse-distinfo-line lines)))

(defun ql-source-dist-version (source version-id)
  "Return a ~ql-dist-version~ object or raise an error."
  (with-source-connection (source)
    (let ((dist-version (find-dao 'ql-dist-version :id version-id)))
      (unless dist-version
        (error 'ql-dist-version-missing
               :source source
               :version-id version-id))
      dist-version)))


;;; * Projects

(defclass ql-project (db-backed-mixin)
  ((name
    :initarg :name
    :accessor ql-project-name
    :reader project/name
    :col-type :text
    :primary-key t
    :reader object-id
    :documentation
    "The name of the project."))
  (:metaclass dao-table-class)
  (:record-timestamps nil)
  (:documentation
   "Represents a project in a quicklisp distribution."))

(defmethod project/releases ((p ql-project))
  (with-source-connection ((db-backed-object-source p))
    (retrieve-dao 'ql-release :project-name (ql-project-name p))))


;;; * Releases

(defclass ql-release (db-backed-mixin
                      tarball-release-with-md5
                      tarball-release-with-size
                      simple-versioned-release)
  ((meta-id
    :initarg :meta-id
    :accessor ql-release-meta-id
    :col-type :integer
    :documentation
    "The ID of the corresponding ~ql-release-meta~ object.")
   (project-name
    :initarg :project-name
    :accessor ql-release-project-name
    :col-type :text
    :documentation
    "The name of the project this to which this release corresponds.")
   (dist-version-id
    :reader release/version
    :initarg :dist-version-id
    :col-type :text
    :documentation
    "The distribution version to which this release belongs. Also the version of
    this release."))
  (:metaclass dao-table-class)
  (:record-timestamps nil)
  (:documentation
   "Represents a release in a quicklisp distribution. Many releases may share the
   same properties, so those are abstracted out into the ~ql-release-meta~
   class."))

(defmethod release/source ((r ql-release))
  (db-backed-object-source r))

(defmethod release/system-file ((release ql-release) system-file-namestring)
  (make-instance 'ql-system-file
                 :namestring system-file-namestring
                 :release release))

(defmethod release/system-release ((release ql-release) system-name)
  (with-source-connection ((release/source release))
    (find-dao 'ql-system-release :system-name system-name :release-id (object-id release))))

(defmethod release/system-releases ((release ql-release))
  (with-source-connection ((release/source release))
    (retrieve-dao 'ql-system-release :release-id (object-id release))))

(defmethod release/project ((release ql-release))
  (source/project (release/source release) (ql-release-project-name release)))

(defmethod release/lib-pathname ((r ql-release))
  (with-source-connection ((release/source r))
    (let ((meta (find-dao 'ql-release-meta
                          :id (ql-release-meta-id r))))
      (uiop:resolve-absolute-location
       (list (source/lib-directory (release/source r))
             "projects"
             (project/name (release/project r))
             (ql-release-meta-prefix meta))
       :ensure-directory t))))

(defmethod tarball-release/url ((release ql-release))
  (with-source-connection ((release/source release))
    (let ((meta (find-dao 'ql-release-meta
                          :id (ql-release-meta-id release))))
      (assert meta)
      (aprog1
          (parse-uri (ql-release-meta-url meta))
        (when (ql-force-https (release/source release))
          (ensure-uri-scheme-https! it))))))

(defmethod tarball-release/desired-md5 ((release ql-release))
  (with-source-connection ((release/source release))
    (let ((meta (find-dao 'ql-release-meta
                          :id (ql-release-meta-id release))))
      (assert meta)
      (ql-release-meta-file-md5 meta))))

(defmethod tarball-release/desired-size ((release ql-release))
  (with-source-connection ((release/source release))
    (let ((meta (find-dao 'ql-release-meta
                          :id (ql-release-meta-id release))))
      (assert meta)
      (ql-release-meta-size meta))))


;;; * Release metadata

(defclass ql-release-meta ()
  ((project-name
    :initarg :project-name
    :accessor ql-release-meta-project-name
    :col-type :text
    :documentation
    "The name of the project this belongs to.")
   (url
    :initarg :url
    :accessor ql-release-meta-url
    :col-type :text
    :documentation
    "The URL where the tarball for this release is located.")
   (size
    :initarg :size
    :accessor ql-release-meta-size
    :col-type :integer
    :documentation
    "The size of the tarball.")
   (file-md5
    :initarg :file-md5
    :accessor ql-release-meta-file-md5
    :col-type :text
    :documentation
    "The md5sum of the tarball.")
   (content-sha1
    :initarg :content-sha1
    :accessor ql-release-meta-content-sha1
    :col-type :text
    :documentation
    "The sha1sum of the tarball contents.")
   (prefix
    :initarg :prefix
    :accessor ql-release-meta-prefix
    :col-type :text
    :documentation
    "The prefix on every file in the tarball.")
   (system-files
    :initarg :system-files
    :accessor ql-release-meta-system-files
    :col-type :text
    :deflate (lambda (x)
               (with-standard-io-syntax
                 (prin1-to-string x)))
    :inflate (lambda (x)
               (with-standard-io-syntax
                 (read-from-string x)))
    :documentation
    "A list of system files contained in the release."))
  (:metaclass dao-table-class)
  (:record-timestamps nil)
  (:documentation
   "Quicklisp distributions version based on distribution release date. A single
   release of a project may appear as a release in many distributions. This
   object represents the metadata for a single release of a project and is
   referenced by one or more ~ql-release~ objects."))


;;; * Systems

(defclass ql-system (db-backed-mixin)
  ((name
    :initarg :name
    :accessor ql-system-name
    :accessor system/name
    :col-type :text
    :primary-key t
    :reader object-id
    :documentation
    "The name of the system."))
  (:metaclass dao-table-class)
  (:record-timestamps nil)
  (:documentation
   "An ASD system contained in a quicklisp distribution."))

(defmethod system/source ((system ql-system))
  (db-backed-object-source system))

(defmethod system/system-releases ((system ql-system))
  (with-source-connection ((system/source system))
    (retrieve-dao 'ql-system-release :system-name (ql-system-name system))))


;;; * System releases

(defclass ql-system-release (db-backed-mixin)
  ((release-id
    :initarg :release-id
    :accessor ql-system-release-release-id
    :col-type :integer
    :documentation
    "The ID of the release to which this system release belongs.")
   (system-name
    :initarg :system-name
    :accessor ql-system-release-system-name
    :col-type :text
    :documentation
    "The name of the system.")
   (system-file
    :initarg :system-file
    :accessor ql-system-release-system-file
    :col-type :text
    :documentation
    "The asd file in which this system is located.")
   (dependencies
    :initarg :dependencies
    :accessor ql-system-release-dependencies
    :col-type :text
    :deflate (lambda (x)
               (with-standard-io-syntax
                 (prin1-to-string x)))
    :inflate (lambda (x)
               (with-standard-io-syntax
                 (read-from-string x)))
    :documentation
    "A list of dependencies this system has in this release."))
  (:metaclass dao-table-class)
  (:record-timestamps nil)
  (:documentation
   "A release of a system. Ties together an ASD system, a point in time (the
   release), and the state of the asd system at that time (what file it was
   located in and its dependencies)."))

(defmethod system-release/system ((system-release ql-system-release))
  (with-source-connection ((system-release/source system-release))
    (find-dao 'ql-system :name (ql-system-release-system-name system-release))))

(defmethod system-release/system-file ((system-release ql-system-release))
  (release/system-file (system-release/release system-release)
                       (ql-system-release-system-file system-release)))

(defmethod system-release/absolute-asd-pathname ((system-release ql-system-release))
  (system-file/absolute-asd-pathname (release/system-file (system-release/release system-release)
                                                          (ql-system-release-system-file system-release))))

(defmethod system-release/source ((system-release ql-system-release))
  (db-backed-object-source system-release))

(defmethod system-release-satisfies-version-spec-p ((system-release ql-system-release) version-spec)
  "There is currently no good way to reasonably get the system version from the
  metadata alone, so say everything is satisfied."
  t)

(defmethod system-release-> ((sr-1 ql-system-release) (sr-2 ql-system-release))
  (release-> (system-release/release sr-1) (system-release/release sr-2)))

(defmethod system-release/release ((system-release ql-system-release))
  (with-source-connection ((system-release/source system-release))
    (find-dao 'ql-release :id (ql-system-release-release-id system-release))))

(defmethod system-release/requirements ((system-release ql-system-release))
  (let ((deps (remove-if (rcurry #'member (list "asdf" "uiop") :test #'string-equal)
                         (ql-system-release-dependencies system-release))))
    (mapcar (lambda (dep-name)
              (make-instance 'system-requirement
                             :name dep-name))
            deps)))


;;; * System files

(defclass ql-system-file ()
  ((namestring
    :initarg :namestring
    :reader system-file/asd-enough-namestring
    :documentation
    "The namestring for the file.")
   (release
    :initarg :release
    :reader system-file/release
    :documentation
    "The release to which this system-file belongs."))
  (:documentation
   "A system file. Belongs to a specific release."))

(defmethod system-file/source ((system-file ql-system-file))
  (release/source (system-file/release system-file)))

(defmethod system-file/absolute-asd-pathname ((system-file ql-system-file))
  (let* ((release (system-file/release system-file)))
    (merge-pathnames (system-file/asd-enough-namestring system-file)
                     (release/lib-pathname release))))


;;; * Syncing!

(defun latest-version-map (source)
  "Fetch the latest versions for a source. Returns an alist mapping version
strings to distinfo.txt urls."
  (let ((versions-pathname (merge-pathnames "metadata/distinfo-versions.txt"
                                            (source/cache-directory source))))
    (when (ensure-file-fetched versions-pathname (ql-versions-url source))
      (let ((versions-lines (uiop:read-file-lines versions-pathname)))
        (mapcar (lambda (l)
                  (destructuring-bind (version url)
                      (split-sequence #\Space l)
                    (cons version url)))
                versions-lines)))))

(defun sync-version-list! (source)
  "Given a ~source~, sync the known versions of this distribution."
  (let ((all-versions (latest-version-map source)))
    (with-source-connection (source)
      (with-transaction *connection*
        (dolist (pair all-versions)
          (unless (find-dao 'ql-dist-version :id (car pair))
            (create-dao 'ql-dist-version
                        :source source
                        :id (car pair)
                        :canonical-distinfo-url (cdr pair))))))))

(defun sync-version-projects! (source dist-version)
  "Given a ~ql-dist-version~, download its release data and merge it into the
local database."
  (let ((release-index-pathname (merge-pathnames (uiop:strcat "metadata/"
                                                              (ql-dist-version-id dist-version)
                                                              "/releases.txt")
                                                 (source/cache-directory source)))
        (release-index-url (ql-dist-version-release-index-url dist-version)))
    (ensure-file-fetched release-index-pathname release-index-url)

    (let ((release-index-contents (uiop:read-file-string release-index-pathname))
          (dist-version-id (ql-dist-version-id dist-version)))
      (dolist (line (split-sequence #\Newline release-index-contents :remove-empty-subseqs t))
        (destructuring-bind (project url size file-md5 content-sha1 prefix &rest system-files)
            (split-sequence #\Space line)
          (unless (find-dao 'ql-project :name project)
            (create-dao 'ql-project :name project))
          (let* ((release-meta (or (find-dao 'ql-release-meta
                                             :project-name project
                                             :url url)
                                   (create-dao 'ql-release-meta
                                               :project-name project
                                               :url url
                                               :size size
                                               :file-md5 file-md5
                                               :content-sha1 content-sha1
                                               :prefix prefix
                                               :system-files system-files)))
                 (meta-id (object-id release-meta)))
            (unless (find-dao 'ql-release
                              :meta-id meta-id
                              :dist-version-id dist-version-id)
              (create-dao 'ql-release
                          :meta-id meta-id
                          :project-name project
                          :dist-version-id dist-version-id))))))))

(defun sync-version-systems! (source dist-version)
  "Given a ~ql-dist-version~, download its system data and merge it into the
local database."
  (let ((system-index-pathname (merge-pathnames (uiop:strcat "metadata/"
                                                             (ql-dist-version-id dist-version)
                                                             "/systems.txt")
                                                (source/cache-directory source)))
        (system-index-url (ql-dist-version-system-index-url dist-version)))
    (ensure-file-fetched system-index-pathname system-index-url)

    (let ((system-index-contents (uiop:read-file-string system-index-pathname))
          (dist-version-id (ql-dist-version-id dist-version)))
      (dolist (line (split-sequence #\Newline system-index-contents :remove-empty-subseqs t))
        (destructuring-bind (project system-file system-name &rest dependencies)
            (split-sequence #\Space line)
          (unless (find-dao 'ql-system :name system-name)
            (create-dao 'ql-system :name system-name))
          (let ((release (find-dao 'ql-release
                                   :project-name project
                                   :dist-version-id dist-version-id)))
            (assert release)
            (unless (find-dao 'ql-system-release
                              :release-id (object-id release)
                              :system-name system-name)
              (create-dao 'ql-system-release
                          :release-id (object-id release)
                          :system-file (concatenate 'string system-file ".asd")
                          :system-name system-name
                          :dependencies dependencies))))))))

(defun sync-version! (dist-version)
  "Given a ~ql-dist-version~ object, sync its data to the local database."
  (when (ql-dist-version-synced-p dist-version)
    (error "Already synced!"))

  (let* ((source (db-backed-object-source dist-version))
         (distinfo-url (ql-dist-version-canonical-distinfo-url dist-version))
         (distinfo-pathname (merge-pathnames (uiop:strcat "metadata/"
                                                          (ql-dist-version-id dist-version)
                                                          "/distinfo.txt")
                                             (source/cache-directory source))))
    (ensure-file-fetched distinfo-pathname distinfo-url)
    (let* ((distinfo-contents (uiop:read-file-string distinfo-pathname))
           (distinfo-plist (parse-distinfo distinfo-contents)))
      (destructuring-bind (&key
                             release-index-url system-index-url
                             canonical-distinfo-url
                           &allow-other-keys)
          distinfo-plist
        (setf (ql-dist-version-canonical-distinfo-url dist-version) canonical-distinfo-url
              (ql-dist-version-system-index-url dist-version) system-index-url
              (ql-dist-version-release-index-url dist-version) release-index-url
              (ql-dist-version-synced-int dist-version) 1)
        (with-source-connection (source)
          (with-transaction *connection*
            (sync-version-projects! source dist-version)
            (sync-version-systems! source dist-version)
            (save-dao dist-version)))))))

(defmethod sync-source ((source quicklisp-source))
  "Sync the version list and then sync all unsynced dist versions."
  (sync-version-list! source)
  (mapc 'sync-version! (ql-source-unsynced-dist-versions source))
  (values))
