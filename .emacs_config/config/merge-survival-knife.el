
;; ---------------------------------------------------------------------------
;; Merge Survival Knife (WIP)
;; ---------------------------------------------------------------------------

;; To make sure smerge doesn't add refinements to conflicts
(setc diff-refine nil)

;; TODO Make this a minor mode
;; TODO Add a README which explains with a graph

(defconst msk-local-start-re "^<<<<<<<")
(defconst msk-local-end-re "^|||||||")
(defconst msk-remote-start-re "^=======")
(defconst msk-remote-end-re "^>>>>>>>")

;;;; ---------------------------------------------------------------------------
;;;; State
;;;; ---------------------------------------------------------------------------

(defvar msk-state nil)

(defun msk-put (key value)
  (put 'msk-state (intern key) value))

(defun msk-get (key)
  (get 'msk-state (intern key)))

(defun msk-list ()
  (symbol-plist 'msk-state))

(defun msk-clear-state ()
  (setplist 'msk-state nil))

;;;; ---------------------------------------------------------------------------
;;;; Start and stop
;;;; ---------------------------------------------------------------------------

(defun msk-start ()
  (interactive)
  (if (msk-list)
      (msk-stop)
    (msk-cleanup))
  (msk-save-windows)
  (msk-save-original-pos)
  (if (msk-find-next-conflict)
      (progn (msk-populate-strings)
             (msk-create-buffers)
             (msk-create-diffs)
             (msk-base-local))
    (message "No conflict found")))

(defun msk-stop ()
  (interactive)
  (msk-save-solved-conflict)
  (msk-restore-windows)
  (msk-cleanup))

(defun msk-cleanup ()
  (dolist (maybe-buffer (msk-list))
    (dolist (name '("BASE" "LOCAL" "REMOTE" "MERGED"))
      (when (bufferp maybe-buffer)
        (let ((bfn (buffer-name maybe-buffer)))
          (when (and bfn (string-match-p name bfn))
            (kill-buffer maybe-buffer))))))
  (msk-clear-state))

(defun msk-save-original-pos ()
  (msk-put "original-buffer" (current-buffer))
  (msk-put "original-point" (point)))

(defun msk-save-windows ()
  (msk-put "window-configuration" (current-window-configuration)))

(defun msk-restore-windows ()
  (if-let (windows (msk-get "window-configuration"))
      (set-window-configuration windows)
    (message "Warning: no window config found")))

;;;; ---------------------------------------------------------------------------
;;;; Finding a conflict
;;;; ---------------------------------------------------------------------------

(defun msk-find-next-conflict ()
  (when (smerge-find-conflict)
    (re-search-backward msk-local-start-re)))

;;;; ---------------------------------------------------------------------------
;;;; Populate the conflict strings
;;;; ---------------------------------------------------------------------------

(defun msk-populate-strings ()
  (unless (looking-at-p msk-local-start-re)
    (error "Not looking at start, bug"))
  (let* ((local  (msk-string-between-regexp msk-local-start-re  msk-local-end-re    nil))
         (base   (msk-string-between-regexp msk-local-end-re    msk-remote-start-re nil))
         (remote (msk-string-between-regexp msk-remote-start-re msk-remote-end-re   nil))
         (merged (msk-string-between-regexp msk-local-start-re  msk-remote-end-re   t)))
    (msk-put "local-string" local)
    (msk-put "base-string" base)
    (msk-put "remote-string" remote)
    (msk-put "merged-string" merged)
    (list local base remote merged)))

(defun msk-string-between-regexp (start end inclusive)
  (save-excursion
    (let* ((start-point nil)
           (end-point nil))
      (re-search-forward start)
      (unless inclusive
        (next-line))
      (beginning-of-line)
      (setq start-point (point))
      (re-search-forward end)
      (unless inclusive
        (previous-line))
      (end-of-line)
      (setq end-point (point))
      (buffer-substring-no-properties start-point end-point))))

;;;; ---------------------------------------------------------------------------
;;;; Create buffers
;;;; ---------------------------------------------------------------------------

(defun msk-create-buffers ()
  (msk-create-buffer "LOCAL"  "local-string"  t)
  (msk-create-buffer "BASE"   "base-string"   t)
  (msk-create-buffer "REMOTE" "remote-string" t)
  (msk-create-buffer "MERGED" "merged-string" nil))

;; TODO: Common helper for some stuff line line numbers
(defun msk-create-buffer (name string-key read-only)
  (let ((buffer (generate-new-buffer name)))
    (with-current-buffer buffer
      (display-line-numbers-mode t) ;; workaround due to unknwon bug
      (insert "\n") ;; workaround due to vdiff bug
      (insert (msk-get string-key))
      (insert "\n") ;; vdiff wants all to end in newline
      ;; (when read-only
      ;;   (read-only-mode)))
      (msk-put name buffer))))

;;;; ---------------------------------------------------------------------------
;;;; Create diffs
;;;; ---------------------------------------------------------------------------

;; TODO: Create a "4 way diff" with BL and RM are on top, and BR and LM are on top
(defun msk-create-diffs ()
  ;; By inhibiting diff vdiff seems to work nicer. No more warnings about
  ;; sentinel and first diff not showing. It could be that when concurrent async
  ;; processes things are messed up.
  (setq vdiff--inhibit-diff-update t)
  (msk-create-diff "BASE" "LOCAL")
  (msk-create-diff "BASE" "REMOTE")
  (msk-create-diff "LOCAL" "REMOTE")
  (msk-create-diff "LOCAL" "MERGED")
  (msk-create-diff "REMOTE" "MERGED")
  (setq vdiff--inhibit-diff-update nil))

(defun msk-create-diff (left right)
  (let* ((left-name (msk-diff-name left right left))
         (right-name (msk-diff-name left right right))
         (left-buffer (make-indirect-buffer (msk-get left) left-name))
         (right-buffer (make-indirect-buffer (msk-get right) right-name)))
    (with-current-buffer left-buffer
      (display-line-numbers-mode t))
    ;; (read-only-mode))
    (with-current-buffer right-buffer
      (display-line-numbers-mode t))
    ;; (read-only-mode))
    (msk-put left-name left-buffer)
    (msk-put right-name right-buffer)
    (vdiff-buffers left-buffer right-buffer)))

(defun msk-diff-name (left right this)
  (concat this " (" (substring left 0 1) (substring right 0 1) ")"))

;;;; ---------------------------------------------------------------------------
;;;; Change views
;;;; ---------------------------------------------------------------------------

(defun msk-change-view (left right)
  (let* ((left-buffer-name (msk-diff-name left right left))
         (right-buffer-name (msk-diff-name left right right)))
    (delete-other-windows)
    (switch-to-buffer (msk-get left-buffer-name))
    (split-window-right)
    (other-window 1)
    (switch-to-buffer (msk-get right-buffer-name))))

(defun msk-base-local ()
  (interactive)
  (msk-change-view "BASE" "LOCAL"))

(defun msk-base-remote ()
  (interactive)
  (msk-change-view "BASE" "REMOTE"))

(defun msk-local-remote ()
  (interactive)
  (msk-change-view "LOCAL" "REMOTE"))

(defun msk-local-merged ()
  (interactive)
  (msk-change-view "LOCAL" "MERGED"))

(defun msk-remote-merged ()
  (interactive)
  (msk-change-view "REMOTE" "MERGED"))

;;;; ---------------------------------------------------------------------------
;;;; Saving the solved conflict
;;;; ---------------------------------------------------------------------------

(defun msk-save-solved-conflict ()
  (switch-to-buffer (msk-get "original-buffer"))
  (goto-char (msk-get "original-point"))
  (cl-assert (msk-find-next-conflict))
  (let* ((old-string (msk-get "merged-string"))
         (new-string (msk-get-solved-conflict-string)))
    (cl-assert (= 1 (replace-string-in-region old-string new-string)))))

(defun msk-get-solved-conflict-string ()
  (let ((string (with-current-buffer (msk-get "MERGED")
                  (buffer-substring-no-properties (point-min) (point-max)))))
    (unless (string-prefix-p "\n" string)
      (error "The merged string must begin with a newline"))
    (unless (string-suffix-p "\n" string)
      (error "The merged string must end with a newline"))
    (substring string 1 -1)))
  
