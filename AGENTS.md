# 存放规矩

**代码、源码树、补丁、构建产物一律不得放在 `/tmp`** —— macOS 重启会清空 `/private/tmp`，
本项目已经因此丢过一次工作目录。`/tmp` 只允许放临时下载（压缩包/安装包/镜像，可重下）
与运行日志/探针输出/截屏等过程产物。其余放持久目录（如 `~/lavender-wayland/`）或直接进仓库。

持久存放处：`~/lavender-wayland/`
- `lavender-droidspaces-ksu/` 本仓库（内核配方 + 文档 + contrib 产物）
- `wlr-build/` wlroots/niri 的移植源码树与构建产物
- `scratch/` 参考源码、二进制补丁变体、真机截屏
