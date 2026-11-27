#lang scribble/manual
@(require (for-label racket/base
                     racket/contract
                     cdp)
          scribble/example)

@(define cdp-eval (make-base-eval #:lang 'racket/base '(require cdp)))

@title[#:tag "cdp"]{cdp: Chrome DevTools Protocol}
@author{turinglambdaai}

@defmodule[cdp]

The @filepath{cdp} package drives the @deftech{Chrome DevTools Protocol}
of the Chromium-based browser already on the machine (Chrome, Edge,
Chromium) from Racket: launch it headless with a throw-away profile,
attach to a page, evaluate JavaScript, navigate, wait, take
screenshots and print to PDF with a custom header or footer —
something the plain @tt{--print-to-pdf} switch cannot do.

Everything is implemented in pure Racket: no FFI, no third-party
package, no bundled browser. The WebSocket transport (RFC 6455) is
written by hand in @racket[cdp/websocket].

@section{Quick start}

@examples[
#:eval cdp-eval
(hash-ref a4-paper 'paperWidth)
]

@codeblock{
#lang racket/base
(require cdp)

(with-cdp
 (lambda (c)
   (cdp-navigate c "https://racket-lang.org/")
   (cdp-wait c "document.readyState === 'complete'")
   (displayln (cdp-evaluate c "document.title"))
   (with-output-to-file "racket.pdf"
     (lambda () (write-bytes (cdp-screenshot c))))))
}

@section{Client}

@defstruct*[cdp ([ws websocket?] [proc subprocess?] [profile path-string?]
                 [session (or/c string? #f)] [next-id exact-nonnegative-integer?])]{
 One attached page. @racket[session] is the flattened session id of
 the page target; @racket[next-id] is the id of the next message, so
 two clients never share a counter.
}

@defproc[(cdp-launch [#:browser browser (or/c path-string? #f) #f]
                     [#:args args (listof string?) '()]
                     [#:headless? headless? boolean? #t]
                     [#:timeout-ms timeout-ms exact-nonnegative-integer? 30000])
         cdp?]{
 Launches the browser with a scratch profile and a DevTools port,
 waits for @tt{DevToolsActivePort}, connects, creates a page target,
 attaches to it with a flattened session and enables @tt{Page} and
 @tt{Runtime}. @racket[browser] defaults to @racket[find-browser];
 @racket[args] adds command-line switches; @racket[headless?]
 @racket[#f] opens a visible window.
}

@defproc[(cdp-close [c cdp?]) void?]{
 Closes the browser, the socket and removes the profile.
}

@defproc[(with-cdp [body (-> cdp? any)] [#:browser browser (or/c path-string? #f) #f]
                  [#:args args (listof string?) '()])
         any]{
 Evaluates @racket[(body c)] with a fresh client; the browser is
 closed afterwards, even when @racket[body] raises.
}

@defproc[(cdp-call [c cdp?] [method string?] [params jsexpr? (hasheq)]
                   [session (or/c string? #f) (cdp-session c)])
         jsexpr?]{
 Sends one command and waits for the reply with the same id; events
 that arrive meanwhile are dropped. Protocol errors and page script
 errors raise @racket[exn:fail]. Set the @tt{CDP_DEBUG} environment
 variable to trace every message on stderr.
}

@defproc[(cdp-evaluate [c cdp?] [expr string?]) jsexpr?]{
 Evaluates @racket[expr] in the page with @tt{returnByValue} and
 @tt{awaitPromise}; returns the JSON value.
}

@defproc[(cdp-wait [c cdp?] [expr string?] [timeout-ms exact-nonnegative-integer? 30000])
         boolean?]{
 Polls @racket[expr] every 250 ms until it evaluates truthy;
 @racket[#f] when the timeout passes first. Errors while polling count
 as ``not yet''.
}

@defproc[(cdp-navigate [c cdp?] [url string?]) (or/c string? #f)]{
 Loads @racket[url] in the page; returns the frame id.
}

@defproc[(cdp-screenshot [c cdp?] [#:full-page? full-page? boolean? #f]) bytes?]{
 PNG bytes of the viewport (or of the whole page).
}

@defthing[a4-paper jsexpr?]{
 A4 portrait in inches, for @racket[cdp-print-to-pdf].
}

@defproc[(cdp-print-to-pdf [c cdp?] [out-path path-string?]
                           [#:paper paper jsexpr? a4-paper]
                           [#:landscape? landscape? boolean? #f]
                           [#:margins margins jsexpr? (hasheq 'marginTop 1 'marginBottom 1 'marginLeft 1 'marginRight 1)]
                           [#:header-footer? header-footer? boolean? #f]
                           [#:header-template header-template string? "<div></div>"]
                           [#:footer-template footer-template string? "<div></div>"])
         void?]{
 Prints the page with backgrounds on. @racket[paper] and
 @racket[margins] are hashes of the @tt{Page.printToPDF} keys of the
 same names; the templates are HTML with the DevTools placeholder
 classes (@tt{pageNumber}, @tt{title}, @tt{date}, ...) and are only
 drawn when @racket[header-footer?] is true.
}

@section{Browser discovery and command-line helpers}

@defproc[(find-browser) (or/c path-string? #f)]{
 Path of a usable browser, or @racket[#f]. The @tt{CDP_BROWSER}
 environment variable (path to an executable) overrides discovery;
 otherwise known install locations are tried, then the @tt{PATH}.
}

@defproc[(browser-error) any]{
 Raises @racket[exn:fail] explaining that no browser was found.
}

@defproc[(path->file-url [p path-string?]) string?]{
 The @tt{file://} URL of @racket[p], for navigating to local files.
}

@defproc[(with-temp-directory [body (-> path? any)]) any]{
 Evaluates @racket[(body dir)] with a fresh temporary directory that
 is removed afterwards.
}

@defproc[(run-process [exe path-string?] [args (listof string?)]
                      [#:timeout timeout real? 30])
         (values (or/c exact-integer? #f) string?)]{
 Runs @racket[exe]; returns the exit code (@racket[#f] when killed
 after @racket[timeout] seconds) and stderr. All three streams go to
 temp files so the browser inherits no console handles.
}

@defproc[(headless-screenshot [url string?] [out-png path-string?]
                              [width exact-positive-integer?] [height exact-positive-integer?]
                              [#:background background (or/c string? #f) #f]
                              [#:timeout timeout real? 20])
         void?]{
 Screenshot through the plain @tt{--screenshot} switch — no protocol
 needed. The viewport is exactly @racket[width] by @racket[height]
 CSS px at device scale 1; @racket[background] @racket[#f] keeps
 transparency, otherwise a @tt{#RRGGBB} string.
}

@defproc[(headless-print-pdf [url string?] [out-pdf path-string?]
                             [#:timeout timeout real? 60])
         void?]{
 Prints through the plain @tt{--print-to-pdf} switch; page size and
 margins come from the page's @tt["@page"] CSS.
}

@section{WebSocket}

@defstruct*[websocket ([in input-port?] [out output-port?])]{
 One open connection.
}

@defproc[(ws-connect [host string?] [port exact-nonnegative-integer?] [ws-path string?]) websocket?]{
 Opens a TCP connection and performs the opening handshake.
}

@defproc[(ws-connect-url [host string?] [port exact-nonnegative-integer?] [url string?]) websocket?]{
 Like @racket[ws-connect] with the path taken from a URL.
}

@defproc[(ws-send! [ws websocket?] [payload bytes?]) void?]{
 Sends one masked text frame.
}

@defproc[(ws-recv! [ws websocket?]) bytes?]{
 Reads one message, reassembling fragments and answering pings; a
 close frame raises @racket[exn:fail:websocket].
}

@defproc[(ws-send-raw! [ws websocket?] [op exact-nonnegative-integer?] [payload bytes?]) void?]{
 Sends one masked frame of any opcode (1 text, 2 binary, 8 close,
 9 ping, 10 pong).
}

@defproc[(ws-close! [ws websocket?]) void?]{
 Sends a close frame and closes the ports.
}

@defproc[(ws-accept-key [key bytes?]) bytes?]{
 The @tt{Sec-WebSocket-Accept} value for a @tt{Sec-WebSocket-Key}, for
 tests that act as the server.
}

@section{License}

MIT.
