#lang racket/base
;; Quick start: launch the system browser headless, render a page,
;; read its title, take a screenshot and print it to PDF with a page
;; number footer. Skipped (with a note) when no browser is installed.
;;
;;   racket cdp/examples/quickstart.rkt

(require cdp racket/file)

(define browser (find-browser))

(cond
  [(not browser)
   (displayln "no Chrome/Edge/Chromium found; set CDP_BROWSER to try the quickstart")]
  [else
   (define dir (make-temporary-file "cdp-quickstart-~a" 'directory))
   (define page (build-path dir "page.html"))
   (display-to-file "<html><head><title>cdp quickstart</title></head>
<body style='margin:0;background:#2d6;color:#fff;font:48px sans-serif'>
<div style='padding:40px'>Hello from <b>cdp</b></div></body></html>" page)
   (with-cdp
    (lambda (c)
      (cdp-navigate c (path->file-url page))
      (cdp-wait c "document.readyState === 'complete'")
      (printf "title: ~a\n" (cdp-evaluate c "document.title"))
      (printf "answer: ~a\n" (cdp-evaluate c "6 * 7"))
      (with-output-to-file (build-path dir "shot.png") (lambda () (write-bytes (cdp-screenshot c))))
      (cdp-print-to-pdf c (build-path dir "page.pdf") #:header-footer? #t
                        #:footer-template "<div style='font-size:10px;width:100%;text-align:center'><span class='pageNumber'></span> / <span class='totalPages'></span></div>")
      (printf "screenshot ~a bytes, pdf ~a bytes\n"
              (file-size (build-path dir "shot.png"))
              (file-size (build-path dir "page.pdf")))))
   (delete-directory/files dir)])
