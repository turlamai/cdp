# Changelog

## 0.1

Initial release.

- `cdp/websocket`: hand-written RFC 6455 client (`ws-connect`, `ws-send!`, `ws-recv!`, ping/pong, fragmentation).
- `cdp/browser`: `find-browser` (`CDP_BROWSER` override), `run-process`, `headless-screenshot`, `headless-print-pdf`, `with-temp-directory`.
- `cdp/client`: `cdp-launch`/`cdp-close`/`with-cdp`, `cdp-call` with per-client ids, `cdp-evaluate`, `cdp-wait`, `cdp-navigate`, `cdp-screenshot`, `cdp-print-to-pdf`.
