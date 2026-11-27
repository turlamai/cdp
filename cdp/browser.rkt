#lang racket/base
;; Finding and launching the system Chromium-based browser (Chrome, Edge,
;; Chromium). Two levels are offered: the plain command-line switches
;; (`headless-screenshot`, `headless-print-pdf`) that need no protocol at
;; all, and browser discovery for the CDP client in client.rkt.
(require net/url racket/file racket/format racket/list racket/path racket/string racket/system)
(provide find-browser
         browser-error
         path->file-url
         with-temp-directory
         run-process
         headless-screenshot
         headless-print-pdf)

(define windows? (eq? (system-type 'os) 'windows))
(define macos? (eq? (system-type 'os) 'macosx))

(define (env-path name)
  (define v (getenv name))
  (and v (non-empty-string? v) v))

;; Executable names searched on PATH, in preference order.
(define path-names
  '("google-chrome" "google-chrome-stable" "chromium" "chromium-browser"
    "chrome" "microsoft-edge" "msedge"))

(define (find-on-path name)
  (or (find-executable-path name)
      (and windows? (find-executable-path (string-append name ".exe")))
      #f))

;; Known install locations, in preference order, per platform.
(define (known-paths)
  (cond
    [windows?
     (filter values
             (list (and (env-path "ProgramFiles")
                        (build-path (env-path "ProgramFiles") "Google/Chrome/Application/chrome.exe"))
                   (and (env-path "LOCALAPPDATA")
                        (build-path (env-path "LOCALAPPDATA") "Google/Chrome/Application/chrome.exe"))
                   (and (env-path "ProgramFiles(x86)")
                        (build-path (env-path "ProgramFiles(x86)") "Microsoft/Edge/Application/msedge.exe"))
                   (and (env-path "ProgramFiles")
                        (build-path (env-path "ProgramFiles") "Microsoft/Edge/Application/msedge.exe"))
                   (and (env-path "LOCALAPPDATA")
                        (build-path (env-path "LOCALAPPDATA") "Microsoft/Edge/Application/msedge.exe"))))]
    [macos?
     (list "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
           "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
           "/Applications/Chromium.app/Contents/MacOS/Chromium")]
    [else '()]))

;; Path string of a usable browser executable, or #f. The CDP_BROWSER
;; environment variable (path to an executable) overrides discovery.
(define (find-browser)
  (or (let ([override (env-path "CDP_BROWSER")])
        (and override (file-exists? override) override))
      (for/or ([p (in-list (known-paths))]) (and p (file-exists? p) (path->string p)))
      (for/or ([name (in-list path-names)]) (define p (find-on-path name)) (and p (path->string p)))))

(define (browser-error)
  (error 'browser
         "no Chrome/Edge/Chromium executable found; set CDP_BROWSER to the browser executable path"))

(define (path->file-url p)
  (url->string (path->url (path->complete-path p))))

;; Run `exe` with `args`; returns (values exit-code-or-#f stderr-string).
;; #f means the process was killed after `timeout` seconds. All three
;; standard streams go to temp files: the browser must not inherit
;; console/pipe handles of the caller (slow and unreliable when it does).
(define (run-process exe args #:timeout [timeout 30])
  (define in-file (make-temporary-file "cdp-in-~a"))
  (define out-file (make-temporary-file "cdp-out-~a"))
  (define err-file (make-temporary-file "cdp-err-~a"))
  (define in (open-input-file in-file))
  (define out (open-output-file out-file #:exists 'truncate))
  (define err (open-output-file err-file #:exists 'truncate))
  (define-values (p _in _out _pid)
    (with-handlers ([exn:fail? (lambda (e) (error 'run-process (exn-message e)))])
      ;; subprocess argument order: stdout, stdin, stderr.
      (apply subprocess out in err exe args)))
  (define done (make-semaphore 0))
  (define code-box (box #f))
  (thread (lambda ()
            (subprocess-wait p)
            (set-box! code-box (subprocess-status p))
            (semaphore-post done)))
  (define finished? (sync/timeout timeout done))
  (unless finished?
    (subprocess-kill p #t)
    (subprocess-wait p))
  (close-input-port in)
  (close-output-port out)
  (close-output-port err)
  (define stderr (with-handlers ([exn:fail? (lambda _ "")])
                   (bytes->string/utf-8 (file->bytes err-file))))
  (for ([f (in-list (list in-file out-file err-file))])
    (with-handlers ([exn:fail? void]) (delete-file f)))
  (values (and finished? (unbox code-box)) stderr))

;; Headless startup of the system browser occasionally hangs forever (an
;; upstream issue, not flag dependent), so a failed attempt is retried.
(define attempts 3)

;; Wait briefly for `path` to show up after the browser process exited.
(define (wait-for-file path [seconds 3])
  (let loop ([deadline (+ (current-inexact-milliseconds) (* seconds 1000))])
    (cond [(and (file-exists? path) (> (file-size path) 0)) #t]
          [(< (current-inexact-milliseconds) deadline) (sleep 0.1) (loop deadline)]
          [else #f])))

;; Common flags: a private profile keeps the run independent of the user's
;; running browser instance (otherwise the URL would open as a new tab there).
(define (base-flags profile-dir)
  (list "--headless"
        (string-append "--user-data-dir=" (path->string profile-dir))
        "--no-first-run"
        "--no-default-browser-check"
        "--disable-extensions"
        "--disable-background-networking"
        "--hide-scrollbars"))

;; `background`: #f keeps transparency; otherwise a "#RRGGBB" string.
(define (background-flag background)
  (string-append "--default-background-color="
                 (if background (string-append (string-trim background "#") "ff") "00000000")))

(define (call-browser what url args out-path #:timeout [timeout 30])
  (define browser (or (find-browser) (browser-error)))
  (with-handlers ([exn:fail? void]) (delete-file out-path))
  (let loop ([n 1] [last-err ""])
    (define profile-dir (make-temporary-file "cdp-profile-~a" 'directory))
    (define-values (code stderr)
      (run-process browser (append (base-flags profile-dir) args (list url)) #:timeout timeout))
    ;; The profile may still be locked by a lingering helper process on Windows.
    (with-handlers ([exn:fail? void]) (delete-directory/files profile-dir))
    (define ok? (and code (= code 0) (wait-for-file out-path)))
    (cond
      [ok? (void)]
      [(< n attempts) (loop (add1 n) stderr)]
      [else
       (error 'browser
              "~a failed after ~a attempts (last exit code: ~a)~a"
              what
              attempts
              (if code code "timeout")
              (if (non-empty-string? last-err) (string-append "\n" last-err) ""))])))

;; Screenshot of `url` rendered in a viewport of exactly width x height CSS px.
;; Output is width x height device px (device scale factor 1), so callers pass
;; the final pixel size they want (the page content scales to it).
(define (headless-screenshot url out-png width height #:background [background #f] #:timeout [timeout 20])
  (call-browser
   "screenshot" url
   (list (string-append "--screenshot=" (path->string out-png))
         (format "--window-size=~a,~a" width height)
         "--force-device-scale-factor=1"
         (background-flag background))
   out-png
   #:timeout timeout))

;; Print `url` to a PDF. Page size and margins come from the page's @page CSS.
(define (headless-print-pdf url out-pdf #:timeout [timeout 60])
  (call-browser
   "print-to-pdf" url
   (list (string-append "--print-to-pdf=" (path->string out-pdf))
         "--no-pdf-header-footer")
   out-pdf
   #:timeout timeout))

;; Evaluate `body` with a fresh temporary directory; removed afterwards.
(define (with-temp-directory body)
  (define dir (make-temporary-file "cdp-tmp-~a" 'directory))
  (dynamic-wind void
                (lambda () (body dir))
                (lambda () (with-handlers ([exn:fail? void]) (delete-directory/files dir)))))
