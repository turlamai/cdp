#lang racket/base
;; Chrome DevTools Protocol client: launch the system browser headless
;; with a throw-away profile, attach to a page target over a flattened
;; session, and talk to it with `cdp-call` plus a few helpers
;; (evaluate, navigate, wait, screenshot, print to PDF).
(require racket/file racket/format racket/list racket/port racket/string
         json net/base64
         (file "websocket.rkt") (file "browser.rkt"))
(provide cdp
         (struct-out cdp)
         cdp-launch
         cdp-close
         with-cdp
         cdp-call
         cdp-evaluate
         cdp-wait
         cdp-navigate
         cdp-screenshot
         cdp-print-to-pdf
         a4-paper)

;; One attached page. `next-id` is the next message id, so two clients
;; never share a counter.
(struct cdp (ws proc profile session [next-id #:mutable]) #:transparent)

;; Launch the browser headless with a scratch profile and attach to a new
;; page target. `browser` defaults to `find-browser`; `args` adds
;; command-line switches; `headless?` #f opens a visible window (for
;; debugging). The DevTools port is written to <profile>/DevToolsActivePort.
(define (cdp-launch #:browser [browser (or (find-browser) (browser-error))]
                    #:args [args '()]
                    #:headless? [headless? #t]
                    #:timeout-ms [timeout-ms 30000])
  (define profile (make-temporary-file "cdp-profile-~a" 'directory))
  (define log (open-output-file (build-path profile "browser.log") #:exists 'truncate))
  (define-values (proc _in _out _err)
    (with-handlers ([exn:fail? (lambda (e) (delete-directory/files profile) (raise e))])
      (apply subprocess #f #f log browser
             (append (if headless? '("--headless=new" "--disable-gpu") '())
                     '("--no-first-run" "--no-default-browser-check" "--disable-extensions"
                       "--remote-debugging-port=0")
                     (list (string-append "--user-data-dir=" (path->string profile)))
                     args
                     '("about:blank")))))
  (define port-file (build-path profile "DevToolsActivePort"))
  (define deadline (+ (current-inexact-milliseconds) timeout-ms))
  ;; Chromium writes the file line by line; a complete second line is the
  ;; browser endpoint path, so wait for it instead of trusting file existence.
  (define (complete-port-lines)
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (define ls (file->lines port-file))
      (and (>= (length ls) 2)
           (regexp-match? #px"^/devtools/browser/[0-9a-f-]{36}$" (second ls))
           ls)))
  (let wait ()
    (cond [(complete-port-lines) => values]
          [(> (current-inexact-milliseconds) deadline)
           (subprocess-kill proc #t)
           (error 'cdp-launch "browser did not open its DevTools port in time")]
          [else (sleep 0.1) (wait)]))
  (define lines (complete-port-lines))
  (define ws (ws-connect "127.0.0.1" (string->number (first lines)) (second lines)))
  (define c (cdp ws proc profile #f 0))
  (define target (cdp-call c "Target.createTarget" (hasheq 'url "about:blank")))
  (define session (hash-ref (cdp-call c "Target.attachToTarget"
                                      (hasheq 'targetId (hash-ref target 'targetId) 'flatten #t))
                           'sessionId))
  (for ([m (in-list '("Page.enable" "Runtime.enable"))])
    (cdp-call c m (hasheq) session))
  (struct-copy cdp c [session session]))

(define (cdp-close c)
  (with-handlers ([exn:fail? void]) (cdp-call c "Browser.close" (hasheq)))
  (with-handlers ([exn:fail? void]) (ws-close! (cdp-ws c)))
  (with-handlers ([exn:fail? void]) (subprocess-kill (cdp-proc c) #t))
  (subprocess-wait (cdp-proc c))
  (with-handlers ([exn:fail? void]) (delete-directory/files (cdp-profile c))))

;; Evaluate `(body c)` with a fresh client; the browser is closed afterwards.
(define (with-cdp body #:browser [browser #f] #:args [args '()])
  (define c (cdp-launch #:browser (or browser (find-browser) (browser-error)) #:args args))
  (dynamic-wind void (lambda () (body c)) (lambda () (cdp-close c))))

;; ---------------------------------------------------------------------------
;; Protocol calls
;; ---------------------------------------------------------------------------

;; Send one command and wait for the reply with the same id. Events that
;; arrive meanwhile are dropped; `session` selects the target session
;; (the client's own session by default).
(define (cdp-call c method params [session (cdp-session c)])
  (define id (cdp-next-id c))
  (set-cdp-next-id! c (add1 id))
  (define msg (make-hasheq))
  (hash-set! msg 'id id)
  (hash-set! msg 'method method)
  (hash-set! msg 'params params)
  (when session (hash-set! msg 'sessionId session))
  (define payload (string->bytes/utf-8 (jsexpr->string msg)))
  (when (getenv "CDP_DEBUG") (eprintf "CDP>> ~a\n" payload))
  (ws-send! (cdp-ws c) payload)
  (define reply
    (let loop ()
      (define m (string->jsexpr (bytes->string/utf-8 (ws-recv! (cdp-ws c)))))
      (if (and (hash? m) (eq? (hash-ref m 'id #f) id)) m (loop))))
  (when (getenv "CDP_DEBUG") (eprintf "CDP<< ~a\n" (jsexpr->string reply)))
  (define err (hash-ref reply 'error #f))
  (when err (error 'cdp-call "~a failed: ~a" method (hash-ref err 'message "?")))
  (hash-ref reply 'result (hasheq)))

;; Evaluate JS in the attached page; returns the JSON value (or #f / 'null').
(define (cdp-evaluate c expr)
  (define r (cdp-call c "Runtime.evaluate"
                      (hasheq 'expression expr 'returnByValue #t 'awaitPromise #t)))
  (define res (hash-ref r 'result (hasheq)))
  (define ex (hash-ref r 'exceptionDetails #f))
  (when ex (error 'cdp-evaluate "page script error: ~a"
                  (hash-ref (hash-ref ex 'exception (hasheq)) 'description "?")))
  (hash-ref res 'value #f))

;; Poll an expression until it evaluates truthy or the timeout (ms) passes.
(define (cdp-wait c expr [timeout-ms 30000])
  (define deadline (+ (current-inexact-milliseconds) timeout-ms))
  (let loop ()
    (define ok (with-handlers ([exn:fail? (lambda (_) #f)]) (cdp-evaluate c expr)))
    (cond [ok #t]
          [(> (current-inexact-milliseconds) deadline) #f]
          [else (sleep 0.25) (loop)])))

;; Load `url` in the attached page; returns the frame id.
(define (cdp-navigate c url)
  (hash-ref (cdp-call c "Page.navigate" (hasheq 'url url)) 'frameId #f))

;; PNG bytes of the viewport.
(define (cdp-screenshot c #:full-page? [full-page? #f])
  (define r (cdp-call c "Page.captureScreenshot"
                      (hasheq 'format "png" 'captureBeyondViewport full-page?)))
  (base64-decode (string->bytes/latin-1 (hash-ref r 'data))))

;; A4 portrait in inches.
(define a4-paper (hasheq 'paperWidth 8.27 'paperHeight 11.69))

;; Print the attached page to `out-path`. `paper` is a hash of
;; Page.printToPDF paper keys (see `a4-paper`); `margins` a hash of the
;; four margin keys in inches; header/footer templates are HTML strings
;; and only drawn when `header-footer?` is true.
(define (cdp-print-to-pdf c out-path
                          #:paper [paper a4-paper]
                          #:landscape? [landscape? #f]
                          #:margins [margins (hasheq 'marginTop 1 'marginBottom 1 'marginLeft 1 'marginRight 1)]
                          #:header-footer? [header-footer? #f]
                          #:header-template [header-template "<div></div>"]
                          #:footer-template [footer-template "<div></div>"])
  (define params (make-hasheq))
  (for ([h (in-list (list paper margins
                          (hasheq 'landscape landscape?
                                  'printBackground #t
                                  'displayHeaderFooter header-footer?
                                  'headerTemplate header-template
                                  'footerTemplate footer-template
                                  'preferCSSPageSize #f)))])
    (hash-for-each h (lambda (k v) (hash-set! params k v))))
  (define r (cdp-call c "Page.printToPDF" params))
  (with-output-to-file out-path #:exists 'replace
    (lambda () (write-bytes (base64-decode (string->bytes/latin-1 (hash-ref r 'data)))))))
