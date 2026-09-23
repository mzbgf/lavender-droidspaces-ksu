# libanland_consumer.so 的二进制补丁

Android 端 consumer（`com.anland.termux` 的 `lib/arm64/libanland_consumer.so`）两处
二进制补丁。正路是改 `native_consumer.c` 后用 NDK 重编 APK，这里是省掉 NDK 的等效近路。

| 文件 | 内容 |
|---|---|
| `libanland_consumer.so.orig` | 原始（lfdevs 5.13.3） |
| `libanland_consumer.so.fence-patched` | 坑 5：`refresh_done` 里 `ldr w0,[x8,#0x10]` → `mov w0,#-1`（VMA `0xecd8`）。kgsl sync_file 交给 SurfaceFlinger 会 `FAILED_TRANSACTION` → `LOG_ALWAYS_FATAL`；退化为 `queueBuffer(...,-1)` 即 ready-now，等待语义保留 |
| `libanland_consumer.so.input-patched` | 5.3b：`push_input_event` / `push_input_event_with_length` 里 `bl enter_fallback`（VMA `0xede8` / `0xef40`）→ `nop`。输入事件发送失败不该拆显示连接 |

⚠️ **input-patched 只堵了三个入口里的两个**，event 线程那条仍在（见文档 5.3b 追记）。
覆盖到 `/data/app/~~*~~/com.anland.termux-*/lib/arm64/libanland_consumer.so` 后 `force-stop` app 生效。
