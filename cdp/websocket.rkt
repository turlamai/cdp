#lang racket/base
;; A hand-written RFC 6455 WebSocket client over a TCP connection, enough
;; for the Chrome DevTools Protocol: a text/binary message channel with
;; masking, fragmentation, ping/pong and close handling. No third-party
;; package is needed.
(require racket/tcp racket/port racket/random racket/string file/sha1 net/base64)
(provide websocket
         (struct-out websocket)
         exn:fail:websocket
         ws-connect
         ws-connect-url
         ws-close!
         ws-send!
         ws-recv!
         ws-send-raw!
         ws-accept-key
         read-crlf-line)

(struct websocket (in out) #:transparent)

;; Raised when the peer closes the connection or the handshake fails.
(struct exn:fail:websocket exn:fail ())

(define (debug . args)
  (when (getenv "CDP_DEBUG")
    (apply eprintf args)))

;; ---------------------------------------------------------------------------
;; Framing
;; ---------------------------------------------------------------------------

(define (read-exact in n)
  (define b (make-bytes n))
  (let loop ([got 0])
    (define n0 (read-bytes! b in got))
    (cond [(eof-object? n0) (raise (exn:fail:websocket "websocket: connection closed" (current-continuation-marks)))]
          [(< (+ got n0) n) (loop (+ got n0))]
          [else b])))

;; XOR `data` with the repeating 4-byte `mask` starting at offset 0.
(define (unmask data mask)
  (define out (make-bytes (bytes-length data)))
  (for ([k (in-range (bytes-length data))])
    (bytes-set! out k (bitwise-xor (bytes-ref data k) (bytes-ref mask (bitwise-and k 3)))))
  out)

;; Header of one frame with a masked payload of `n` bytes.
(define (client-frame-header op n)
  (define fin+op (+ op 128))
  (cond [(< n 126) (bytes fin+op (+ 128 n))]
        [(< n 65536) (bytes-append (bytes fin+op (+ 128 126)) (integer->integer-bytes n 2 #f #t))]
        [else (bytes-append (bytes fin+op (+ 128 127)) (integer->integer-bytes n 8 #f #t))]))

;; Send one complete masked frame (fin = 1). `op` is 1 (text) or 2 (binary).
(define (ws-send-raw! ws op payload)
  (define mask (crypto-random-bytes 4))
  (write-bytes (client-frame-header op (bytes-length payload)) (websocket-out ws))
  (write-bytes mask (websocket-out ws))
  (write-bytes (unmask payload mask) (websocket-out ws))
  (flush-output (websocket-out ws)))

(define (ws-send! ws payload) (ws-send-raw! ws 1 payload))

;; Read one data message, answering pings and reassembling fragments.
;; Control frames (ping 9, pong 10) never interleave with a fragment
;; except between fragments, which the loop handles naturally.
(define (ws-recv! ws)
  (let loop ([parts '()])
    (define b0 (bytes-ref (read-exact (websocket-in ws) 1) 0))
    (define b1 (bytes-ref (read-exact (websocket-in ws) 1) 0))
    (define fin? (bitwise-bit-set? b0 7))
    (define op (bitwise-and b0 15))
    (define len
      (let ([l (bitwise-and b1 127)])
        (case l
          [(126) (integer-bytes->integer (read-exact (websocket-in ws) 2) #f #t)]
          [(127) (integer-bytes->integer (read-exact (websocket-in ws) 8) #f #t)]
          [else l])))
    (define mask (and (bitwise-bit-set? b1 7) (read-exact (websocket-in ws) 4)))
    (define raw (read-exact (websocket-in ws) len))
    (define data (if mask (unmask raw mask) raw))
    (case op
      [(8) (raise (exn:fail:websocket "websocket: closed by peer" (current-continuation-marks)))]
      [(9) (ws-send-raw! ws 10 data) (loop parts)]
      [(10) (loop parts)]
      [else (let ([parts (append parts (list data))])
              (if fin? (apply bytes-append parts) (loop parts)))])))

(define (ws-close! ws)
  (with-handlers ([exn:fail? void]) (ws-send-raw! ws 8 #""))
  (with-handlers ([exn:fail? void]) (close-input-port (websocket-in ws)))
  (with-handlers ([exn:fail? void]) (close-output-port (websocket-out ws))))

;; ---------------------------------------------------------------------------
;; Opening handshake
;; ---------------------------------------------------------------------------

(define ws-guid #"258EAFA5-E914-47DA-95CA-C5AB0DC85B11")

;; `accept` is sha1(key + GUID) in base64, the value a server must reply
;; with; exported for tests that act as the server.
;; sha1 yields a hex string (also on older Racket), so decode it back.
(define (ws-accept-key key) (base64-encode (hex-string->bytes (sha1 (bytes-append key ws-guid))) #""))

;; One CRLF-terminated line as bytes, read a byte at a time. The reader-level
;; `read-line` cannot be mixed with `read-bytes!` on the same port (the
;; reader buffers ahead), and the frames are read with `read-bytes!`.
(define (read-crlf-line in)
  (let loop ([acc '()])
    (define b (bytes-ref (read-exact in 1) 0))
    (cond [(= b 10) (apply bytes-append (reverse (if (and (pair? acc) (equal? (car acc) #"\r")) (cdr acc) acc)))]
          [else (loop (cons (bytes b) acc))])))

(define (handshake! ws host port ws-path)
  (define key (base64-encode (crypto-random-bytes 16) #""))
  (fprintf (websocket-out ws)
           "GET ~a HTTP/1.1\r\nHost: ~a:~a\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ~a\r\nSec-WebSocket-Version: 13\r\n\r\n"
           ws-path host port key)
  (flush-output (websocket-out ws))
  (define status (read-crlf-line (websocket-in ws)))
  (let drain ()
    (define l (read-crlf-line (websocket-in ws)))
    (unless (zero? (bytes-length l)) (drain)))
  (unless (and (bytes? status) (regexp-match? #" 101 " status))
    (raise (exn:fail:websocket (format "websocket handshake failed: ~a" status) (current-continuation-marks))))
  (debug "WS handshake ok ~a:~a~a\n" host port ws-path))

;; Connect to ws://host:port/ws-path (plain TCP; DevTools endpoints do not
;; use TLS).
(define (ws-connect host port ws-path)
  (define-values (in out) (tcp-connect host port))
  (file-stream-buffer-mode out 'none)
  (define ws (websocket in out))
  (with-handlers ([exn:fail? (lambda (e) (ws-close! ws) (raise e))])
    (handshake! ws host port ws-path))
  ws)

;; Connect using the URL written to DevToolsActivePort, which has no
;; scheme and host: "/devtools/browser/<uuid>".
(define (ws-connect-url host port url)
  (define ws-path (if (string-prefix? url "/") url (car (regexp-match #px"/.*" url))))
  (ws-connect host port ws-path))
