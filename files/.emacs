;; ===== Disable Startup Message =====
(setq inhibit-startup-message t)

;; ===== Hide Menu Bar =====
(menu-bar-mode 0)

;; ===== Don't Split Window When Loading Multiple Files =====
(add-hook 'window-setup-hook 'delete-other-windows)

;; ===== Set Standard Indent To 2 Rather Than 4 =====
(setq standard-indent 2)

;; ===== Line By Line Scrolling =====
;; This makes the buffer scroll by only a single line when the up
;; or down cursor keys push the cursor (tool-bar-mode) outside the
;; buffer. The standard emacs behaviour is to reposition the cursor
;; in the center of screen, but this can make scrolling confusing
(setq scroll-step 1)

;; ===== Turn Off Tab Character =====
;; Emacs normally uses both tabs and spaces to indent lines. If you
;; prefer, all indentation can be made from spaces only. To request
;; this, set `indent-tabs-mode' to `nil'. This is a per-buffer variable;
;; altering the variable affects only the current buffer, but it can be
;; disabled for all buffers.
;; Use (setq ...) to set value locally to a buffer
;; Use (setq-default ...) to set value globally
(setq-default indent-tabs-mode nil)

;; ===== Set Default Tab Width =====
(defun set-dev-indent (n)
  ;; java/c/c++
  (setq-local c-basic-offset n)
  ;; web development
  (setq-local javascript-indent-level n) ; javascript-mode
  (setq-local web-mode-markup-indent-offset n) ; web-mode, html tag in html file
  (setq-local web-mode-css-indent-offset n) ; web-mode, css in html file
  (setq-local web-mode-code-indent-offset n) ; web-mode, js code in html file
  (setq-local css-indent-offset n) ; css-mode
  )
(defun setup-dev-env ()
  (set-dev-indent 2))

(setq default-tab-width 2)
(add-hook 'prog-mode-hook 'setup-dev-env) ; requires Emacs24+

;; ===== Prevent Emacs From Making Backup Files =====
(setq make-backup-files nil)

;; ===== Show Line+Column Numbers on Mode Line =====
  (line-number-mode t)
(column-number-mode t)

;; ===== Load Editor Mode Extensions =====
(autoload 'jq-mode "jq-mode.el"
  "Major mode for editing jq files" t)

;; ===== Define Auto-Loading of Scripting Major Modes =====
(add-to-list 'interpreter-mode-alist '("bash"   . shell-script-mode))
(add-to-list 'interpreter-mode-alist '("perl"   . perl-mode))
(add-to-list 'interpreter-mode-alist '("python" . python-mode))
(add-to-list 'interpreter-mode-alist '("expect" . tcl-mode))
(add-to-list 'auto-mode-alist        '("\\.jq$" . jq-mode))

;; ===== Show Line Numbers Only In Programming Modes =====
(add-hook 'prog-mode-hook 'display-line-numbers-mode)

;; ===== Make Text Mode The Default Mode For New Buffers =====
(setq default-major-mode 'text-mode)

;; ===== Prevent Emacs From Inserting a Newline at EOF =====
(setq next-line-add-newline nil)
(setq require-final-newline nil)

(custom-set-variables
 ;; custom-set-variables was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(package-selected-packages '(vscode-dark-plus-theme dracula-theme ##)))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 )

;; ===== Package Archives =====
(require 'package)
(package-initialize)

(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)

;; ===== Load Theme =====
(if (boundp 'custom-theme-load-path)
  (progn
    ;; https://unkertmedia.com/37-emacs-themes-to-try
    (add-to-list 'custom-theme-load-path
                 "~/.emacs.d/elpa/vscode-dark-plus-theme-20230725.1703"
    )
  ))
(load-theme 'vscode-dark-plus t)
