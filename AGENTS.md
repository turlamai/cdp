# AGENTS.md

Chrome DevTools Protocol 客户端的纯 Racket 实现（MIT）：手写 WebSocket、浏览器发现、无头启动、求值/导航/截图/打印 PDF。

## 结构

Multi-collection 包：collection 即 `cdp/` 子目录，scribblings 声明在 `cdp/info.rkt`（collection 级）。`websocket.rkt`（RFC 6455）→ `browser.rkt`（发现与命令行开关）→ `client.rkt`（协议客户端），单向依赖；`main.rkt` 汇总导出。

## 常用命令

```bash
raco pkg install --auto --link "$(pwd)"
raco test -p cdp
```

`cdp/test/cdp-test.rkt` 与 quickstart 需要机器上有 Chrome/Edge/Chromium，没有则跳过并提示。调试协议时设 `CDP_DEBUG=1`，指定浏览器用 `CDP_BROWSER`。

## 验证与发版

- CI（`ci.yml`）：即上面两条命令 + quickstart + `raco setup --check-pkg-deps`，三平台跑（runner 自带浏览器）。
- 发版 = tag `v<版本>` + CHANGELOG 同步；catalog 侧为手动提交（pkgd）。
