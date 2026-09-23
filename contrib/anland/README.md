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
