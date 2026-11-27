#lang racket/base
;; Headless flag sets tried in order by cdp-launch: the new headless mode
;; first, then the old one (the new mode hangs on some macOS CI runners).
(provide headless-flag-sets)

(define headless-flag-sets
  '(("--headless=new" "--disable-gpu")
    ("--headless" "--disable-gpu")))
