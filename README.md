# cdp — Chrome DevTools Protocol in pure Racket

**English** · [中文](README.zh-CN.md)

[![CI](https://github.com/turlamai/cdp/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/cdp/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

`cdp` drives the **Chrome DevTools Protocol** of the Chromium-based
browser already on the machine — Chrome, Edge or Chromium — from
Racket: launch it headless with a throw-away profile, attach to a page,
evaluate JavaScript, navigate, wait, take screenshots and print to PDF
with a custom header or footer (something the plain `--print-to-pdf`
switch cannot do).

Everything is implemented in pure Racket: no FFI, no third-party
package, no bundled browser. The WebSocket transport (RFC 6455) is
written by hand in `cdp/websocket`, with masking, fragmentation and
ping/pong.

## Installation

```
raco pkg install cdp
```

## Usage

```racket
#lang racket/base
(require cdp)

(with-cdp
 (lambda (c)
   (cdp-navigate c "https://racket-lang.org/")
   (cdp-wait c "document.readyState === 'complete'")
   (displayln (cdp-evaluate c "document.title"))     ; "Racket"
   (with-output-to-file "racket.png"
     (lambda () (write-bytes (cdp-screenshot c))))
   (cdp-print-to-pdf c "racket.pdf" #:header-footer? #t
                     #:footer-template "<div style='font-size:10px;width:100%;text-align:center'><span class='pageNumber'></span></div>")))
```

### Browser discovery

`find-browser` returns a usable executable or `#f`: the `CDP_BROWSER`
environment variable (a path) overrides discovery, then known install
locations per platform, then `PATH`. Set `CDP_DEBUG` to trace every
protocol message on stderr.

### Without the protocol

`headless-screenshot` and `headless-print-pdf` go through the plain
command-line switches of the browser — enough for a one-shot PNG or PDF
with no session at all. Both retry a few times, since headless startup
of the system browser occasionally hangs (an upstream issue).

### WebSocket

`ws-connect` / `ws-send!` / `ws-recv!` are a small RFC 6455 client on
their own, usable for any plain `ws://` endpoint; `ws-accept-key` is
exported so tests can act as the server.

## API documentation and development

The [Scribble API reference](cdp/scribblings/cdp.scrbl) defines the
client, launch options, the printing parameters, browser discovery and
the WebSocket layer. The [executable
quickstart](cdp/examples/quickstart.rkt) renders a page, reads its
title, takes a screenshot and prints a PDF with a page-number footer;
it skips with a note when no browser is installed.

From the repository root, with Racket, `raco` and a Chromium-based
browser installed:

```sh
raco pkg install --auto --link "$(pwd)"
raco test -p cdp
racket cdp/examples/quickstart.rkt
raco setup --check-pkg-deps -l cdp
```

These steps are covered by the Linux/macOS/Windows CI matrix. Racket
module path `cdp` is the public API; at runtime only the browser is
needed, never npm, Playwright or a bundled Chromium. For bugs, submit
the browser name and version plus a minimal script to
[GitHub Issues](https://github.com/turlamai/cdp/issues).

## License

[MIT](LICENSE).
