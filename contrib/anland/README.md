# anland producer 的移植产物

anland 是 Android 上跑 Wayland 的协议：Android 端 app（consumer）分配 dmabuf 并
上屏到 SurfaceFlinger，Linux 端合成器（producer）只把桌面渲染进那些共享 dmabuf。
协议与接线见 `docs/WAYLAND-ON-LAVENDER.md`。

本目录放**已经跑通的 producer 移植产物**，防止构建机的工作目录（`/private/tmp`，
macOS 重启会清空）丢失后无法复现。

```
producer-lib/   vendor 的 5 个文件（5-fd 版，与 lfdevs 5.13.3 同源）
                protocol.h / socket_utils.{c,h} / display_producer.{c,h}
                移植新合成器时把它们**拷贝**进去（协议要求 vendor，不要软链接）
wlroots/        wlroots 0.18.2 的 backend-anland
                anland-wlroots-0.18.2.patch  干净 tarball 上 patch -p1 可重放
                ANLAND-PORT-NOTES.md         改了哪些文件 / 怎么构建 / 设计取舍
                xwayland.pc                  构建环境用的 pkg-config shim
tests/          mock daemon + 冒烟宿主，端到端自检可复跑
```

wlroots 那份已真机跑通：`WLR_BACKENDS=anland WLR_RENDERER=gles2 sway` →
`GL renderer: FD512` + `zwp_linux_dmabuf_v1` + 实机出画。

## niri（smithay）

`niri/anland-niri-26.04.patch` 在干净的 niri v26.04 上可重放；
`niri/ANLAND-NIRI-NOTES.md` 是移植说明（含渲染层取舍与未验证清单）。

用法：`ANLAND=1 niri`。渲染走 smithay 的 `Bind<Dmabuf>`（与 Tty/DRM 同一生产路径），
帧节奏 consumer 驱动。

⚠️ **当前真机状态**：niri 能连 daemon、建出 `anland-1` 1080x2340@60Hz、起 IPC，
但**画面全黑** —— 卡在 `push_input_event` 一失败就拆显示连接的共病
（见 `docs/WAYLAND-ON-LAVENDER.md` 5.3b）。sway / Plasma 有静态内容尚能出画，
niri 依赖 `buffer_ready` 才重绘，握手一空转就永远不渲染。

## ⚠️ `protocol.h` 必须用 consumer 那份（28 字节 `buf_info`）

`producer-lib/protocol.h` 已替换为 lfdevs consumer 的真身
（`stride, width, height, format, modifier, offset` = 28 字节）。
**KWin 补丁里 vendor 的那份是旧版**（少了 `width`/`height`，20 字节），照抄它会让
`receive_dmabufs()` 的 `dhdr.size / sizeof(buf_info)` 算出 5 而 `fd_count` 是 4，
每一轮都拒收 → 没有 dmabuf → 全黑。详见 `docs/WAYLAND-ON-LAVENDER.md` 5.3c。

`tests/anland-step-probe.c` 是定位这个 bug 用的分步探针（打印 `pickup_fds` 与
`receive_dmabufs` 各自的成败），真机上对着活的 daemon + consumer 跑即可。
