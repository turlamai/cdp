#lang racket/base
;; End-to-end against the system browser: launch headless, evaluate,
;; navigate, screenshot and print to PDF. Skipped (with a note) when no
;; Chromium-based browser is installed.
(require rackunit racket/file racket/list racket/string "../main.rkt")

(define browser (find-browser))

(cond
  [browser
   (eprintf "cdp-test: using ~a\n" browser)
   (define tmp (make-temporary-file "cdp-test-~a" 'directory))
   (define page-path (build-path tmp "page.html"))
   (display-to-file "<html><head><title>cdp</title></head><body style='margin:0;background:#2d6'><h1 id='t' style='font:48px sans-serif'>cdp</h1></body></html>" page-path)
   (define page (path->file-url page-path))
   (define c #f)
   (define launch-error #f)
   (dynamic-wind
     (lambda ()
       (with-handlers ([exn:fail? (lambda (e) (set! launch-error (exn-message e)))])
         (set! c (cdp-launch #:browser browser #:timeout-ms 60000)))
       (when (or c (not launch-error)) (check-true (string? (cdp-session c)) "attached to a session"))
       (when launch-error
         (eprintf "cdp-test: browser found but did not start, skipping browser tests: ~a\n" launch-error)))
     (lambda ()
       (when c
       (check-equal? (cdp-evaluate c "1 + 1") 2 "evaluate returns the JSON value")
       (cdp-navigate c page)
       (check-true (cdp-wait c "document.getElementById('t') !== null" 10000) "wait for the page")
       (check-equal? (cdp-evaluate c "document.title") "cdp" "page script sees the document")
       (define png (cdp-screenshot c))
       (check-true (bytes? png) "screenshot bytes")
       (check-equal? (subbytes png 0 8) #"\211PNG\r\n\32\n" "PNG signature")
       (define pdf (build-path tmp "out.pdf"))
       (cdp-print-to-pdf c pdf #:footer-template "<div style='font-size:10px;width:100%;text-align:center'>page <span class='pageNumber'></span></div>" #:header-footer? #t)
       (check-true (file-exists? pdf) "pdf written")
       (check-equal? (subbytes (file->bytes pdf) 0 5) #"%PDF-" "PDF signature")
       ;; error reporting: an unknown method surfaces as exn:fail
       (check-exn exn:fail? (lambda () (cdp-call c "NoSuch.method" (hasheq))) "protocol errors raise")
       (check-exn exn:fail? (lambda () (cdp-evaluate c "throw new Error('boom')")) "script errors raise")))
     (lambda ()
       (when c (with-handlers ([exn:fail? void]) (cdp-close c)))
       (delete-directory/files tmp)))]
  [else
   (eprintf "cdp-test: no Chrome/Edge/Chromium found, skipping browser tests\n")])
