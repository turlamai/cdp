#lang info

(define version "0.1")
;; Multi-collection package shape: the collection is the `cdp/` subdirectory.
(define collection 'multi)
(define deps '("base" "rackunit-lib"))
(define build-deps '("base" "scribble-lib" "racket-doc" "rackunit-lib"))
(define pkg-desc "Chrome DevTools Protocol client in pure Racket: hand-written WebSocket, browser discovery, headless launch, evaluate/navigate/screenshot/print-to-PDF")
(define pkg-authors '("turlamai"))
(define license 'MIT)
(define test-omit-paths '("cdp/scribblings"))
