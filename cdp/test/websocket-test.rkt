#lang racket/base
;; WebSocket client against a loopback echo server speaking RFC 6455:
;; the server verifies that client frames are masked, answers the
;; handshake with the right accept key, and can ping or fragment.
(require rackunit racket/list racket/match racket/tcp racket/string racket/port "../websocket.rkt")

(define (read-n in n)
  (define b (make-bytes n))
  (define got (read-bytes! b in))
  (unless (eqv? got n) (error "server: short read"))
  b)

(define (xor-mask data mask)
  (define out (make-bytes (bytes-length data)))
  (for ([i (in-range (bytes-length data))])
    (bytes-set! out i (bitwise-xor (bytes-ref data i) (bytes-ref mask (bitwise-and i 3)))))
  out)

;; Read one client frame: returns (list op payload); asserts the mask bit.
(define (read-frame in)
  (define b0 (bytes-ref (read-n in 1) 0))
  (define b1 (bytes-ref (read-n in 1) 0))
  (define op (bitwise-and b0 15))
  (define masked? (bitwise-bit-set? b1 7))
  (define len
    (let ([l (bitwise-and b1 127)])
      (case l
        [(126) (integer-bytes->integer (read-n in 2) #f #t)]
        [(127) (integer-bytes->integer (read-n in 8) #f #t)]
        [else l])))
  (define mask (and masked? (read-n in 4)))
  (define raw (read-n in len))
  (list op (if mask (xor-mask raw mask) raw) masked?))

(define (write-frame out op payload [fin? #t])
  (define n (bytes-length payload))
  (define header
    (cond [(< n 126) (bytes (+ (if fin? 128 0) op) n)]
          [(< n 65536) (bytes (+ (if fin? 128 0) op) 126)]
          [else (bytes (+ (if fin? 128 0) op) 127)]))
  (write-bytes header out)
  (cond [(< n 126) (void)]
        [(< n 65536) (write-bytes (integer->integer-bytes n 2 #f #t) out)]
        [else (write-bytes (integer->integer-bytes n 8 #f #t) out)])
  (write-bytes payload out)
  (flush-output out))

(define log '())
(define (note! x) (set! log (cons x log)))

;; Accept one connection, handshake, then serve until the client closes.
(define (serve in out)
  ;; drain the whole request, remembering the key line
  (define key-line
    (let loop ([key-line #f])
      (define l (bytes->string/utf-8 (read-crlf-line in)))
      (cond [(string=? l "") key-line]
            [else (loop (if (string-prefix? l "Sec-WebSocket-Key:") l key-line))])))
  (when key-line
    (define key (string->bytes/latin-1 (string-trim (substring key-line 18))))
    (fprintf out "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ~a\r\n\r\n"
             (ws-accept-key key))
    (flush-output out)
    (note! 'handshake)
    (with-handlers ([exn:fail? void])
      (let loop ()
        (match-define (list op payload masked?) (read-frame in))
        (note! (list op masked?))
        (cond
          [(= op 8) (void)]                                   ; close: done
          [(= op 9) (write-frame out 10 payload) (loop)]     ; ping -> pong
          [(bytes=? payload #"ping-me")
           (write-frame out 9 #"p")                          ; server ping
           (match-define (list pong-op pong-data _) (read-frame in))
           (note! (list 'pong pong-op pong-data))
           (write-frame out 1 #"pong-ok")
           (loop)]
          [(bytes=? payload #"frag")
           (write-frame out 1 #"ab" #f)                      ; fragmented message
           (write-frame out 0 #"cd" #f)
           (write-frame out 0 #"ef")
           (loop)]
          [else (write-frame out 1 payload) (loop)])))))     ; echo

(define listener (tcp-listen 0 5 #t "127.0.0.1"))
(define-values (_l port _r _rp) (tcp-addresses listener #t))
(define server
  (thread (lambda ()
            (define-values (in out) (tcp-accept listener))
            (file-stream-buffer-mode out 'none)
            (serve in out)
            (close-input-port in)
            (close-output-port out))))

(define ws (ws-connect "127.0.0.1" port "/echo"))

(check-true (websocket? ws))

(for ([payload (in-list (list #"hi" (make-bytes 200 65) (make-bytes 70000 66)))]
      [label (in-list '("short" "16-bit length" "64-bit length"))])
  (ws-send! ws payload)
  (check-equal? (ws-recv! ws) payload label))

;; the server pings us inside this exchange and expects a pong
(ws-send! ws #"ping-me")
(check-equal? (ws-recv! ws) #"pong-ok" "ping answered transparently")

(ws-send! ws #"frag")
(check-equal? (ws-recv! ws) #"abcdef" "fragmented message reassembled")

(ws-close! ws)
(kill-thread server)
(tcp-close listener)

;; every frame the server saw was a masked client frame, and the pong came back
(define frames (filter list? log))
(check-true (andmap second frames) "all client frames masked")
(check-not-false (member (list 'pong 10 #"p") frames) "client answered the server ping")
