;;; tramp-crypt.el --- Tramp crypt utilities  -*- lexical-binding:t -*-

;; Copyright (C) 2020 Free Software Foundation, Inc.

;; Author: Michael Albinus <michael.albinus@gmx.de>
;; Keywords: comm, processes
;; Package: tramp

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Access functions for crypted remote files.  It uses encfs to
;; encrypt/ decrypt the files on a remote directory.  A remote
;; directory, which shall include crypted files, must be declared in
;; `tramp-crypt-directories' via command `tramp-crypt-add-directory'.
;; All files in that directory, including all subdirectories, are
;; stored there encrypted.  This includes file names and directory
;; names.

;; This package is just responsible for the encryption part.  Copying
;; of the crypted files is still the responsibility of the remote file
;; name handlers.

;; A password protected encfs configuration file is created the very
;; first time you access a crypted remote directory.  It is kept in
;; your user directory "~/.emacs.d/" with the url-encoded directory
;; name as part of the basename, and ".encfs6.xml" as suffix.  Do not
;; loose this file and the corresponding password; otherwise there is
;; no way to decrypt your crypted files.

;; If the user option `tramp-crypt-save-encfs-config-remote' is
;; non-nil (the default), the encfs configuration file ".encfs6.xml"
;; is also be kept in the crypted remote directory.  It depends,
;; whether you regard the password protection of this file as
;; sufficient.

;; If you apply an operation with a quoted localname part, this
;; localname and the corresponding file will not be encrypted/
;; decrypted.  For example, if you have a crypted remote directory
;; "/nextcloud:user@host:/crypted_dir", the command
;;
;;   C-x d /nextcloud:user@host:/crypted_dir
;;
;; will show the directory listing with the plain file names, and the
;; command
;;
;;   C-x d /nextcloud:user@host:/:/crypted_dir
;;
;; will show the directory with the encrypted file names, and visiting
;; a file will show its crypted contents.  However, it is highly
;; discouraged to mix crypted and not crypted files in the same
;; directory.

;; If a remote directory shall not include crypted files anymore, it
;; must be indicated by the command `tramp-crypt-remove-directory'.
;; Existing crypted files will be transformed into their unencrypted
;; file names and contents.

;;; Code:

(eval-when-compile (require 'cl-lib))
(require 'tramp)

(autoload 'prop-match-beginning "text-property-search")
(autoload 'prop-match-end "text-property-search")
(autoload 'text-property-search-forward "text-property-search")

(defconst tramp-crypt-method "crypt"
  "Method name for crypted remote directories.")

(defcustom tramp-crypt-encfs-program "encfs"
  "Name of the encfs program."
  :group 'tramp
  :version "28.1"
  :type 'string)

(defcustom tramp-crypt-encfsctl-program "encfsctl"
  "Name of the encfsctl program."
  :group 'tramp
  :version "28.1"
  :type 'string)

(defcustom tramp-crypt-encfs-option "--standard"
  "Configuration option for encfs.
This could be either \"--standard\" or \"--paranoia\".  The file
name IV chaining mode mode will always be disabled when
initializing a new crypted remote directory."
  :group 'tramp
  :version "28.1"
  :type '(choice (const "--standard")
		 (const "--paranoia")))

;; We check only for encfs, assuming that encfsctl will be available
;; as well.  The autoloaded value is nil, the check will run when
;; tramp-crypt.el is loaded by `tramp-crypt-add-directory'.  It is a
;; common technique to let-bind this variable to nil in order to
;; suppress the file name operation of this package.
;;;###tramp-autoload
(defvar tramp-crypt-enabled nil
  "Non-nil when encryption support is available.")
(setq tramp-crypt-enabled (executable-find tramp-crypt-encfs-program))

(defconst tramp-crypt-encfs-config ".encfs6.xml"
  "Encfs configuration file name.")

(defcustom tramp-crypt-save-encfs-config-remote t
  "Whether to keep the encfs configuration file in the crypted remote directory."
  :group 'tramp
  :version "28.1"
  :type 'booleanp)


;; New handlers should be added here.
;;;###tramp-autoload
(defconst tramp-crypt-file-name-handler-alist
  '(;; (access-file . tramp-crypt-handle-access-file)
    ;; (add-name-to-file . tramp-crypt-handle-not-implemented)
    ;; `byte-compiler-base-file-name' performed by default handler.
    (copy-directory . tramp-handle-copy-directory)
    (copy-file . tramp-crypt-handle-copy-file)
    (delete-directory . tramp-crypt-handle-delete-directory)
    (delete-file . tramp-crypt-handle-delete-file)
    ;; `diff-latest-backup-file' performed by default handler.
    ;; `directory-file-name' performed by default handler.
    (directory-files . tramp-crypt-handle-directory-files)
    (directory-files-and-attributes
     . tramp-handle-directory-files-and-attributes)
    (dired-compress-file . ignore)
    ;; (dired-uncache . tramp-crypt-handle-dired-uncache)
    (exec-path . ignore)
    ;; `expand-file-name' performed by default handler.
    (file-accessible-directory-p . tramp-handle-file-accessible-directory-p)
    (file-acl . ignore)
    (file-attributes . tramp-crypt-handle-file-attributes)
    (file-directory-p . tramp-handle-file-directory-p)
    (file-equal-p . tramp-handle-file-equal-p)
    (file-executable-p . tramp-crypt-handle-file-executable-p)
    (file-exists-p . tramp-handle-file-exists-p)
    (file-in-directory-p . tramp-handle-file-in-directory-p)
    (file-local-copy . tramp-handle-file-local-copy)
    (file-modes . tramp-handle-file-modes)
    ;; (file-name-all-completions . tramp-crypt-handle-file-name-all-completions)
    ;; `file-name-as-directory' performed by default handler.
    ;; (file-name-case-insensitive-p . ignore)
    ;; (file-name-completion . tramp-handle-file-name-completion)
    ;; `file-name-directory' performed by default handler.
    ;; `file-name-nondirectory' performed by default handler.
    ;; `file-name-sans-versions' performed by default handler.
    (file-newer-than-file-p . tramp-handle-file-newer-than-file-p)
    (file-notify-add-watch . ignore)
    (file-notify-rm-watch . ignore)
    (file-notify-valid-p . ignore)
    ;; (file-ownership-preserved-p . ignore)
    (file-readable-p . tramp-crypt-handle-file-readable-p)
    (file-regular-p . tramp-handle-file-regular-p)
    ;; `file-remote-p' performed by default handler.
    (file-selinux-context . ignore)
    (file-symlink-p . tramp-handle-file-symlink-p)
    (file-system-info . tramp-crypt-handle-file-system-info)
    ;; (file-truename . tramp-crypt-handle-file-truename)
    ;; (file-writable-p . ignore)
    (find-backup-file-name . ignore)
    ;; `get-file-buffer' performed by default handler.
    (insert-directory . tramp-crypt-handle-insert-directory)
    ;; `insert-file-contents' performed by default handler.
    ;; (load . tramp-crypt-handle-load)
    (make-auto-save-file-name . tramp-handle-make-auto-save-file-name)
    (make-directory . tramp-crypt-handle-make-directory)
    ;; (make-directory-internal . tramp-crypt-handle-not-implemented)
    ;; (make-nearby-temp-file . tramp-handle-make-nearby-temp-file)
    (make-process . ignore)
    (make-symbolic-link . tramp-handle-make-symbolic-link)
    (process-file . ignore)
    (rename-file . tramp-crypt-handle-rename-file)
    (set-file-acl . ignore)
    (set-file-modes . tramp-crypt-handle-set-file-modes)
    (set-file-selinux-context . ignore)
    ;; (set-file-times . tramp-crypt-handle-not-implemented)
    ;; (set-visited-file-modtime . tramp-handle-set-visited-file-modtime)
    (shell-command . ignore)
    (start-file-process . ignore)
    ;; `substitute-in-file-name' performed by default handler.
    ;; (temporary-file-directory . tramp-crypt-handle-temporary-file-directory)
    ;; `tramp-set-file-uid-gid' performed by default handler.
    ;; (unhandled-file-name-directory . ignore)
    (vc-registered . ignore)
    ;; (verify-visited-file-modtime . tramp-handle-verify-visited-file-modtime)
    (write-region . tramp-handle-write-region))
  "Alist of handler functions for crypt method.
Operations not mentioned here will be handled by the default Emacs primitives.")

(defsubst tramp-crypt-file-name-for-operation (operation &rest args)
  "Like `tramp-file-name-for-operation', but for crypted remote files."
  (cl-letf (((symbol-function #'tramp-tramp-file-p)
	     #'tramp-crypt-file-name-p))
    (apply #'tramp-file-name-for-operation operation args)))

(defun tramp-crypt-run-real-handler (operation args)
  "Invoke normal file name handler for OPERATION.
First arg specifies the OPERATION, second arg ARGS is a list of
arguments to pass to the OPERATION."
  (let* ((inhibit-file-name-handlers
	  `(tramp-crypt-file-name-handler
	    .
	    ,(and (eq inhibit-file-name-operation operation)
		  inhibit-file-name-handlers)))
	 (inhibit-file-name-operation operation))
    (apply operation args)))

;;;###tramp-autoload
(defun tramp-crypt-file-name-handler (operation &rest args)
  "Invoke the crypted remote file related OPERATION.
First arg specifies the OPERATION, second arg ARGS is a list of
arguments to pass to the OPERATION."
  (if-let ((filename (apply #'tramp-file-name-for-operation operation args))
	   (fn (and (tramp-crypt-file-name-p filename)
		    (assoc operation tramp-crypt-file-name-handler-alist))))
      (save-match-data (apply (cdr fn) args))
    (tramp-crypt-run-real-handler operation args)))

;;;###tramp-autoload
(progn (defun tramp-register-crypt-file-name-handler ()
  "Add crypt file name handler to `file-name-handler-alist'."
  (when (and tramp-crypt-enabled tramp-crypt-directories)
    (add-to-list 'file-name-handler-alist
	         (cons tramp-file-name-regexp #'tramp-crypt-file-name-handler))
    (put #'tramp-crypt-file-name-handler 'safe-magic t))))

(tramp-register-file-name-handlers)

;; Mark `operations' the handler is responsible for.
(put #'tramp-crypt-file-name-handler 'operations
     (mapcar #'car tramp-crypt-file-name-handler-alist))


;; File name conversions.

;;;###tramp-autoload
(defvar tramp-crypt-directories nil
  "List of crypted remote directories.")

(defun tramp-crypt-file-name-p (name)
  "Return the crypted remote directory NAME belongs to.
If NAME doesn't belong to a crypted remote directory, retun nil."
  (catch 'crypt-file-name-p
    (and tramp-crypt-enabled (stringp name)
	 (not (tramp-compat-file-name-quoted-p name))
	 (not (string-suffix-p tramp-crypt-encfs-config name))
	 (dolist (dir tramp-crypt-directories)
	   (and (string-prefix-p
		 dir (file-name-as-directory (expand-file-name name)))
		(throw  'crypt-file-name-p dir))))))

(defun tramp-crypt-config-file-name (vec)
  "Return the encfs config file name for VEC."
  (expand-file-name
   (concat "tramp-" (tramp-file-name-host vec) tramp-crypt-encfs-config)
   user-emacs-directory))

(defun tramp-crypt-maybe-open-connection (vec)
  "Maybe open a connection VEC.
Does not do anything if a connection is already open, but re-opens the
connection if a previous connection has died for some reason."
  ;; For password handling, we need a process bound to the connection
  ;; buffer.  Therefore, we create a dummy process.  Maybe there is a
  ;; better solution?
  (unless (get-buffer-process (tramp-get-connection-buffer vec))
    (let ((p (make-network-process
	      :name (tramp-get-connection-name vec)
	      :buffer (tramp-get-connection-buffer vec)
	      :server t :host 'local :service t :noquery t)))
      (process-put p 'vector vec)
      (set-process-query-on-exit-flag p nil)))

  ;; The following operations must be performed w/o
  ;; `tramp-crypt-file-name-handler'.
  (let* (tramp-crypt-enabled
	 ;; Don't check for a proper method.
	 (non-essential t)
	 (remote-config
	  (expand-file-name
	   tramp-crypt-encfs-config (tramp-crypt-get-remote-dir vec)))
	 (local-config (tramp-crypt-config-file-name vec)))
    ;; There is no local encfs6 config file.
    (when (not (file-exists-p local-config))
      (if (and tramp-crypt-save-encfs-config-remote
	       (file-exists-p remote-config))
	  ;; Copy remote encfs6 config file if possible.
	  (copy-file remote-config local-config 'ok 'keep)

	;; Create local encfs6 config file otherwise.
	(let* ((default-directory (tramp-compat-temporary-file-directory))
	       (tmpdir1 (file-name-as-directory
			 (tramp-compat-make-temp-file " .crypt" 'dir-flag)))
	       (tmpdir2 (file-name-as-directory
			 (tramp-compat-make-temp-file " .nocrypt" 'dir-flag))))
	  ;; Enable `auth-source', unless "emacs -Q" has been called.
	  (tramp-set-connection-property
	   vec "first-password-request" tramp-cache-read-persistent-data)
	  (with-temp-buffer
	    (insert
	     (tramp-read-passwd
	      (tramp-get-connection-process vec)
	      (format
	       "New EncFS Password for %s " (tramp-crypt-get-remote-dir vec))))
	    (when
		(zerop
		 (tramp-call-process-region
		  vec (point-min) (point-max)
		  tramp-crypt-encfs-program nil (tramp-get-connection-buffer vec)
		  nil tramp-crypt-encfs-option "--extpass=cat" tmpdir1 tmpdir2))
	      ;; Save the password.
	      (ignore-errors
		(and (functionp tramp-password-save-function)
		     (funcall tramp-password-save-function)))))

	  ;; Write local config file.  Suppress file name IV chaining mode.
	  (with-temp-file local-config
	    (insert-file-contents
	     (expand-file-name tramp-crypt-encfs-config tmpdir1))
	    (goto-char (point-min))
	    (when (search-forward
		   "<chainedNameIV>1</chainedNameIV>" nil 'noerror)
	      (replace-match "<chainedNameIV>0</chainedNameIV>")))

	  ;; Unmount encfs.  Delete temporary directories.
	  (tramp-call-process
	   vec tramp-crypt-encfs-program nil nil nil
	   "--unmount" tmpdir1 tmpdir2)
	  (delete-directory tmpdir1 'recursive)
	  (delete-directory tmpdir2)

	  ;; Copy local encfs6 config file to remote.
	  (when tramp-crypt-save-encfs-config-remote
	    (copy-file local-config remote-config 'ok 'keep)))))))

(defun tramp-crypt-send-command (vec &rest args)
  "Send encfsctl command to connection VEC.
ARGS are the arguments."
  (tramp-crypt-maybe-open-connection vec)
  (with-current-buffer (tramp-get-connection-buffer vec)
    (erase-buffer))
  (with-temp-buffer
    (let* (;; Don't check for a proper method.
	   (non-essential t)
	   (default-directory (tramp-compat-temporary-file-directory))
	   ;; We cannot add it to `process-environment', because
	   ;; `tramp-call-process-region' doesn't use it.
	   (encfs-config
	    (format "ENCFS6_CONFIG=%s" (tramp-crypt-config-file-name vec)))
	   (args (delq nil args)))
      ;; Enable `auth-source', unless "emacs -Q" has been called.
      (tramp-set-connection-property
       vec "first-password-request" tramp-cache-read-persistent-data)
      (insert
       (tramp-read-passwd
	(tramp-get-connection-process vec)
	(format "EncFS Password for %s " (tramp-crypt-get-remote-dir vec))))
      (when (zerop
	     (apply
	      #'tramp-call-process-region vec (point-min) (point-max)
	      "env" nil (tramp-get-connection-buffer vec)
	      nil encfs-config tramp-crypt-encfsctl-program
	      (car args) "--extpass=cat" (cdr args)))
	;; Save the password.
	(ignore-errors
	  (and (functionp tramp-password-save-function)
	       (funcall tramp-password-save-function)))))))

(defun tramp-crypt-do-encrypt-or-decrypt-file-name (op name)
  "Return encrypted/ decrypted NAME if NAME belongs to a crypted directory.
OP must be `encrypt' or `decrypt'.
Otherwise, return NAME."
  (if-let ((tramp-crypt-enabled t)
	   (dir (tramp-crypt-file-name-p name))
	   ;; It must be absolute for the cache.
	   (localname (substring name (1- (length dir))))
	   (crypt-vec (tramp-crypt-dissect-file-name dir)))
      ;; Preserve trailing "/".
      (funcall
       (if (directory-name-p name) #'file-name-as-directory #'identity)
       (concat
	dir
	(unless (string-equal localname "/")
	  (with-tramp-file-property
	      crypt-vec localname (concat (symbol-name op) "-file-name")
	    (tramp-crypt-send-command
	     crypt-vec (if (eq op 'encrypt) "encode" "decode")
	     (tramp-compat-temporary-file-directory) localname)
	    (with-current-buffer (tramp-get-connection-buffer crypt-vec)
	      (goto-char (point-min))
	      (buffer-substring (point-min) (point-at-eol)))))))
    ;; Nothing to do.
    name))

(defsubst tramp-crypt-encrypt-file-name (name)
  "Return encrypted NAME if NAME belongs to a crypted directory.
Otherwise, return NAME."
  (tramp-crypt-do-encrypt-or-decrypt-file-name 'encrypt name))

(defsubst tramp-crypt-decrypt-file-name (name)
  "Return decrypted NAME if NAME belongs to a crypted directory.
Otherwise, return NAME."
  (tramp-crypt-do-encrypt-or-decrypt-file-name 'decrypt name))

(defun tramp-crypt-do-encrypt-or-decrypt-file (op root infile outfile)
  "Encrypt/ decrypt file INFILE to OUTFILE according to crypted directory ROOT.
Both files must be local files.  OP must be `encrypt' or `decrypt'.
If OP ist `decrypt', the basename of INFILE must be an encrypted file name."
  (when-let ((tramp-crypt-enabled t)
	     (dir (tramp-crypt-file-name-p root))
	     (crypt-vec (tramp-crypt-dissect-file-name dir)))
    (let ((coding-system-for-read
	   (if (eq op 'decrypt) 'raw-text coding-system-for-read))
	  (coding-system-for-write
	   (if (eq op 'encrypt) 'raw-text coding-system-for-write)))
      (tramp-crypt-send-command
       crypt-vec "cat" (and (eq op 'encrypt) "--reverse")
       (file-name-directory infile) (file-name-nondirectory infile))
      (with-current-buffer (tramp-get-connection-buffer crypt-vec)
	(write-region nil nil outfile)))))

(defsubst tramp-crypt-encrypt-file (root infile outfile)
  "Encrypt file INFILE to OUTFILE according to crypted directory ROOT.
See `tramp-crypt-do-encrypt-or-decrypt-file'."
  (tramp-crypt-do-encrypt-or-decrypt-file 'encrypt root infile outfile))

(defsubst tramp-crypt-decrypt-file (root infile outfile)
  "Decrypt file INFILE to OUTFILE according to crypted directory ROOT.
See `tramp-crypt-do-encrypt-or-decrypt-file'."
  (tramp-crypt-do-encrypt-or-decrypt-file 'decrypt root infile outfile))

;;;###tramp-autoload
(defun tramp-crypt-add-directory (name)
  "Mark remote directory NAME for encryption.
Files in that directory and all subdirectories will be encrypted
bofore copying to, and decrypted after copying from that
directory.  File names will be also encrypted."
  (interactive "DRemote directory name: ")
  (unless tramp-crypt-enabled
    (tramp-user-error nil "Feature is not enabled."))
  (unless (and (tramp-tramp-file-p name) (file-directory-p name))
    (tramp-user-error nil "%s must be an existing remote directory." name))
  (setq name (file-name-as-directory name))
  (unless (member name tramp-crypt-directories)
    (setq tramp-crypt-directories `(,name . ,tramp-crypt-directories)))
  (tramp-register-file-name-handlers))

;; `auth-source' requires a user.
(defun tramp-crypt-dissect-file-name (name)
  "Return a `tramp-file-name' structure for NAME.
The structure consists of the `tramp-crypt-method' method, the
local user name, the hexlified directory NAME as host, and the
localname."
  (save-match-data
    (if-let ((dir (tramp-crypt-file-name-p name)))
	(make-tramp-file-name
	 :method tramp-crypt-method :user (user-login-name)
	 :host (url-hexify-string dir))
      (tramp-user-error nil "Not a crypted remote directory: \"%s\"" name))))

(defun tramp-crypt-get-remote-dir (vec)
  "Return the name of the crypted remote directory to be used for encfs."
  (url-unhex-string (tramp-file-name-host vec)))


;; File name primitives.

(defun tramp-crypt-do-copy-or-rename-file
  (op filename newname &optional ok-if-already-exists keep-date
   preserve-uid-gid preserve-extended-attributes)
  "Copy or rename a remote file.
OP must be `copy' or `rename' and indicates the operation to perform.
FILENAME specifies the file to copy or rename, NEWNAME is the name of
the new file (for copy) or the new name of the file (for rename).
OK-IF-ALREADY-EXISTS means don't barf if NEWNAME exists already.
KEEP-DATE means to make sure that NEWNAME has the same timestamp
as FILENAME.  PRESERVE-UID-GID, when non-nil, instructs to keep
the uid and gid if both files are on the same host.
PRESERVE-EXTENDED-ATTRIBUTES is ignored.

This function is invoked by `tramp-crypt-handle-copy-file' and
`tramp-crypt-handle-rename-file'.  It is an error if OP is
neither of `copy' and `rename'.  FILENAME and NEWNAME must be
absolute file names."
  (unless (memq op '(copy rename))
    (error "Unknown operation `%s', must be `copy' or `rename'" op))

  (setq filename (file-truename filename))
  (if (file-directory-p filename)
      (progn
	(copy-directory filename newname keep-date t)
	(when (eq op 'rename) (delete-directory filename 'recursive)))

    (let ((t1 (tramp-crypt-file-name-p filename))
	  (t2 (tramp-crypt-file-name-p newname))
	  (encrypt-filename (tramp-crypt-encrypt-file-name filename))
	  (encrypt-newname (tramp-crypt-encrypt-file-name newname))
	  (msg-operation (if (eq op 'copy) "Copying" "Renaming")))

      (with-parsed-tramp-file-name (if t1 filename newname) nil
	(unless (file-exists-p filename)
	  (tramp-error
	   v tramp-file-missing
	   "%s file" msg-operation "No such file or directory" filename))
	(when (and (not ok-if-already-exists) (file-exists-p newname))
	  (tramp-error v 'file-already-exists newname))
	(when (and (file-directory-p newname)
		   (not (directory-name-p newname)))
	  (tramp-error v 'file-error "File is a directory %s" newname))

	(with-tramp-progress-reporter
	    v 0 (format "%s %s to %s" msg-operation filename newname)
	  (if (and t1 t2 (string-equal t1 t2))
	      ;; Both files are on the same crypted remote directory.
	      (let (tramp-crypt-enabled)
		(if (eq op 'copy)
		    (copy-file
		     encrypt-filename encrypt-newname ok-if-already-exists
		     keep-date preserve-uid-gid preserve-extended-attributes)
		  (rename-file
		   encrypt-filename encrypt-newname ok-if-already-exists)))

	    (let* ((tmpdir (tramp-compat-make-temp-file filename 'dir))
		   (tmpfile1
		    (expand-file-name
		     (file-name-nondirectory encrypt-filename) tmpdir))
		   (tmpfile2
		    (expand-file-name
		     (file-name-nondirectory encrypt-newname) tmpdir))
		   tramp-crypt-enabled)
	      (cond
	       ;; Source file is on a crypted remote directory.
	       (t1
		(if (eq op 'copy)
		    (copy-file
		     encrypt-filename tmpfile1 t keep-date preserve-uid-gid
		     preserve-extended-attributes)
		  (rename-file encrypt-filename tmpfile1 t))
		(tramp-crypt-decrypt-file t1 tmpfile1 tmpfile2)
		(rename-file tmpfile2 newname ok-if-already-exists))
	       ;; Target file is on a crypted remote directory.
	       (t2
		(if (eq op 'copy)
		    (copy-file
		     filename tmpfile1 t keep-date preserve-uid-gid
		     preserve-extended-attributes)
		  (rename-file filename tmpfile1 t))
		(tramp-crypt-encrypt-file t2 tmpfile1 tmpfile2)
		(rename-file tmpfile2 encrypt-newname ok-if-already-exists)))
	      (delete-directory tmpdir 'recursive)))

	  (when (and t1 (eq op 'rename))
	    (with-parsed-tramp-file-name filename v1
	      (tramp-flush-file-properties v1 v1-localname)))

	  (when t2
	    (with-parsed-tramp-file-name newname v2
	      (tramp-flush-file-properties v2 v2-localname))))))))

(defun tramp-crypt-handle-copy-file
  (filename newname &optional ok-if-already-exists keep-date
   preserve-uid-gid preserve-extended-attributes)
  "Like `copy-file' for Tramp files."
  (setq filename (expand-file-name filename)
	newname (expand-file-name newname))
  ;; At least one file a Tramp file?
  (if (or (tramp-tramp-file-p filename)
	  (tramp-tramp-file-p newname))
      (tramp-crypt-do-copy-or-rename-file
       'copy filename newname ok-if-already-exists keep-date
       preserve-uid-gid preserve-extended-attributes)
    (tramp-run-real-handler
     #'copy-file
     (list filename newname ok-if-already-exists keep-date
	   preserve-uid-gid preserve-extended-attributes))))

(defun tramp-crypt-handle-delete-directory
    (directory &optional recursive trash)
  "Like `delete-directory' for Tramp files."
  (with-parsed-tramp-file-name (expand-file-name directory) nil
    (tramp-flush-directory-properties v localname)
    (let (tramp-crypt-enabled)
      (delete-directory
       (tramp-crypt-encrypt-file-name directory) recursive trash))))

(defun tramp-crypt-handle-delete-file (filename &optional trash)
  "Like `delete-file' for Tramp files."
  (with-parsed-tramp-file-name (expand-file-name filename) nil
    (tramp-flush-file-properties v localname)
    (tramp-crypt-run-real-handler
     #'delete-file (list (tramp-crypt-encrypt-file-name filename) trash))))

(defun tramp-crypt-handle-directory-files (directory &optional full match nosort)
  "Like `directory-files' for Tramp files."
  (unless (file-exists-p directory)
    (tramp-error
     (tramp-dissect-file-name directory) tramp-file-missing
     "No such file or directory" directory))
  (when (file-directory-p directory)
    (setq directory (file-name-as-directory (expand-file-name directory)))
    (let* (tramp-crypt-enabled
	   (result
	    (directory-files (tramp-crypt-encrypt-file-name directory) 'full)))
      (setq result
	    (mapcar (lambda (x) (tramp-crypt-decrypt-file-name x)) result))
      (when match
	(setq result
	      (delq
	       nil
	       (mapcar
		(lambda (x)
		  (when (string-match-p match (substring x (length directory)))
		    x))
		result))))
      (unless full
	(setq result
	      (mapcar
	       (lambda (x)
		 (replace-regexp-in-string
		  (concat "^" (regexp-quote directory)) "" x))
	       result)))
      (if nosort result (sort result #'string<)))))

(defun tramp-crypt-handle-file-attributes (filename &optional id-format)
  "Like `file-attributes' for Tramp files."
  (tramp-crypt-run-real-handler
   #'file-attributes (list (tramp-crypt-encrypt-file-name filename) id-format)))

(defun tramp-crypt-handle-file-executable-p (filename)
  "Like `file-executable-p' for Tramp files."
  (tramp-crypt-run-real-handler
   #'file-executable-p (list (tramp-crypt-encrypt-file-name filename))))

(defun tramp-crypt-handle-file-readable-p (filename)
  "Like `file-readable-p' for Tramp files."
  (tramp-crypt-run-real-handler
   #'file-readable-p (list (tramp-crypt-encrypt-file-name filename))))

(defun tramp-crypt-handle-file-system-info (filename)
  "Like `file-system-info' for Tramp files."
  (tramp-crypt-run-real-handler
   #'file-system-info (list (tramp-crypt-encrypt-file-name filename))))

(defun tramp-crypt-handle-insert-directory
  (filename switches &optional wildcard full-directory-p)
  "Like `insert-directory' for Tramp files."
  (let (tramp-crypt-enabled)
    (tramp-handle-insert-directory
     (tramp-crypt-encrypt-file-name filename)
     switches wildcard full-directory-p)
    (let* ((filename (file-name-as-directory filename))
	   (enc (tramp-crypt-encrypt-file-name filename))
	   match string)
      (goto-char (point-min))
      (while (setq match (text-property-search-forward 'dired-filename t t))
	(setq string
	      (buffer-substring
	       (prop-match-beginning match) (prop-match-end match))
	      string (if (file-name-absolute-p string)
			 (tramp-crypt-decrypt-file-name string)
		       (substring
			(tramp-crypt-decrypt-file-name (concat enc string))
			(length filename))))
	(delete-region (prop-match-beginning match) (prop-match-end match))
	(insert (propertize string 'dired-filename t))))))

(defun tramp-crypt-handle-make-directory (dir &optional parents)
  "Like `make-directory' for Tramp files."
  (with-parsed-tramp-file-name (expand-file-name dir) nil
    (when (and (null parents) (file-exists-p dir))
      (tramp-error v 'file-already-exists "Directory already exists %s" dir))
    (tramp-crypt-run-real-handler
     #'make-directory (list (tramp-crypt-encrypt-file-name dir) parents))
    ;; When PARENTS is non-nil, DIR could be a chain of non-existent
    ;; directories a/b/c/...  Instead of checking, we simply flush the
    ;; whole cache.
    (tramp-flush-directory-properties
     v (if parents "/" (file-name-directory localname)))))

(defun tramp-crypt-handle-rename-file
  (filename newname &optional ok-if-already-exists)
  "Like `rename-file' for Tramp files."
  (setq filename (expand-file-name filename)
	newname (expand-file-name newname))
  ;; At least one file a Tramp file?
  (if (or (tramp-tramp-file-p filename)
          (tramp-tramp-file-p newname))
      (tramp-crypt-do-copy-or-rename-file
       'rename filename newname ok-if-already-exists
       'keep-date 'preserve-uid-gid)
    (tramp-run-real-handler
     #'rename-file (list filename newname ok-if-already-exists))))

(defun tramp-crypt-handle-set-file-modes (filename mode &optional flag)
  "Like `set-file-modes' for Tramp files."
  (with-parsed-tramp-file-name filename nil
    (tramp-flush-file-properties v localname)
    (tramp-crypt-run-real-handler
     #'set-file-modes
     (list (tramp-crypt-encrypt-file-name filename) mode flag))))

(add-hook 'tramp-unload-hook
	  (lambda ()
	    (unload-feature 'tramp-crypt 'force)))

(provide 'tramp-crypt)

;;; TODO:

;; * I suggest having a feature where the user can specify to always
;;   use encryption for certain host names.  So if you specify a host
;;   name which is on that list (of names, or perhaps regexps?), tramp
;;   would modify the request so as to do the encryption.  (Richard Stallman)

;;; tramp-crypt.el ends here