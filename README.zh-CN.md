# cdp — Chrome DevTools Protocol in pure Racket

[English](README.md) · **中文**

[![CI](https://github.com/turlamai/cdp/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/cdp/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

`cdp` 从 Racket 驱动机器上已有的 Chromium 系浏览器（Chrome、Edge、Chromium）的 **Chrome DevTools Protocol**：用一次性 profile 无头启动、附着到页面、执行 JavaScript、导航、等待、截图，以及带自定义页眉页脚打印 PDF（纯 `--print-to-pdf` 开关做不到的事）。

全部以纯 Racket 实现：无 FFI，无第三方包，不捆绑浏览器。WebSocket 传输（RFC 6455）在 `cdp/websocket` 中手写，支持掩码、分片与 ping/pong。

## 安装

```
raco pkg install cdp
```

## 用法

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

### 浏览器发现

`find-browser` 返回可用可执行文件路径或 `#f`：`CDP_BROWSER` 环境变量（一个路径）优先，其次是各平台的已知安装位置，最后是 `PATH`。设置 `CDP_DEBUG` 可在 stderr 追踪每条协议消息。

### 不走协议

`headless-screenshot` 与 `headless-print-pdf` 直接用浏览器的命令行开关——一次性的 PNG 或 PDF 不需要会话。两者都会重试几次，因为系统浏览器的无头启动偶尔会挂起（上游问题）。

### WebSocket

`ws-connect` / `ws-send!` / `ws-recv!` 本身就是一个精简的 RFC 6455 客户端，可用于任何明文 `ws://` 端点；`ws-accept-key` 一并导出，便于测试充当服务端。

## API 文档与开发

客户端、启动选项、打印参数、浏览器发现以及 WebSocket 层请查阅
[Scribble API 文档](cdp/scribblings/cdp.scrbl)。
[独立入门示例](cdp/examples/quickstart.rkt)渲染页面、读取标题、截图并打印带页码页脚的 PDF；未安装浏览器时跳过并提示。

安装 Racket、`raco` 和任一 Chromium 系浏览器后，在仓库根目录运行：

```sh
raco pkg install --auto --link "$(pwd)"
raco test -p cdp
racket cdp/examples/quickstart.rkt
raco setup --check-pkg-deps -l cdp
```

CI 在 Linux、macOS、Windows 上检查这些步骤。`cdp` 是公开的 `require` 模块路径；运行时只需要浏览器，不需要 npm、Playwright 或捆绑的 Chromium。如发现问题，请在
[GitHub Issues](https://github.com/turlamai/cdp/issues)
提交浏览器名称与版本以及最小复现脚本。

## 许可证

[MIT](LICENSE)。
