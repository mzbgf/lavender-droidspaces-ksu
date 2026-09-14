# 补丁清单

全部补丁都是基于固定 commit
`b2ee0c8f4cd75fbb2097b9bcd8dc3306166f241c`
（`pix106/android_kernel_xiaomi_sdm660_southwest-ng`，Linux 4.19.325）的原始文件
**精确生成**的（生成脚本保证上下文与空白字符逐字节一致），并已逐个
`patch -p1 --dry-run` 校验通过。

应用顺序与幂等判据由 `scripts/apply-patches.sh` 中的表定义。

| 补丁 | 目标文件 | 作用 | 是否必需 |
|---|---|---|---|
| `buildfix/0001-cgroup-noprefix-compat-links.patch` | `kernel/cgroup/cgroup.c` | 在 `cgroup_add_file()` 里为 noprefix 挂载的 cgroup v1 根额外创建 `控制器名.文件名` 前缀别名 | 必需。Android 把多个 legacy 控制器以 `noprefix` 挂载，而 Droidspaces/LXC 会去探测经典的带前缀名字（`cpuacct.usage` 之类），没有别名就探不到 |
| `buildfix/0002-write-once-expression.patch` | `include/linux/compiler.h` | 把本树 CAF 版的 `WRITE_ONCE`（`do { ... } while (0)` 语句形式）恢复成上游 4.19 的语句表达式形式 | 必需。`lib/fault-inject.c:114` 写了 `if (!WRITE_ONCE(current->fail_nth, fail_nth - 1))`，语句形式在这一处直接编译不过 |
| `buildfix/0003-extract-cert-openssl3-compat.patch` | `scripts/extract-cert.c` | OpenSSL ≥ 3 时不再包含 `<openssl/engine.h>`（3.5 起该头文件被移除），复用它自己已有的 BoringSSL 分支 | 条件必需。Ubuntu 22.04/24.04 的 OpenSSL 3.0 仍有 `engine.h`，此时脚本会自动跳过；Fedora 44 之类（OpenSSL 3.5）必须用它 |
| `resukisu/0001-manual-hooks.patch` | `fs/stat.c`、`fs/exec.c`、`fs/open.c`、`kernel/reboot.c` | 按 ReSukiSU 官方 manual integrate 文档，在 4.19 上挂 stat / execve / faccessat / sys_reboot 四组 hook | 必需。4.19 非 GKI 不能用 tracepoint hook（仅 5.10+ GKI2），`CONFIG_KSU_MANUAL_HOOK` 会在编译期逐个校验这些 hook，缺一个就编译失败 |
| `resukisu/0002-selinux-symbol-exports.patch` | `security/selinux/selinuxfs.c` | 去掉 `write_op` 与 `sel_handle_status_ops` 的 `static` | 必需。ReSukiSU 在未开 `CONFIG_KALLSYMS_ALL` 时会校验这些符号导出，缺失即编译失败。4.19 已有 `selinux_state` 结构，所以官方文档里标注 “4.17-” 的其余导出（`selinux_status_page`、`policy_rwlock`、`sel_mutex`、`selinux_ops`）不需要处理 |

## 没有用到的官方补丁

- Droidspaces 官方 non-GKI 补丁 `01.fix_kernel_panic_in_xt_qtaguid.patch`：
  **本树没有 `net/netfilter/xt_qtaguid.c`**（已确认 404，且全树无 qtaguid 相关文件），
  因此无从应用，也不需要——该 bug 只在带 qtaguid 的树上存在。
- Droidspaces 官方 non-GKI 补丁 `02.fix_restore cgroup file prefix handling.patch`：
  官方版针对的是 5.x 的 `kernel/cgroup/cgroup.c` 目录布局，本树虽然也是
  `kernel/cgroup/cgroup.c`，但写法不同；我们用的是按本树重制的
  `buildfix/0001-cgroup-noprefix-compat-links.patch`。

## 上游来源

- Droidspaces（`ravindu644/Droidspaces-OSS`，GPL-3.0）的
  `Documentation/resources/kernel-patches/non-GKI/` 与
  `Documentation/Kernel-Configuration.md`
- `Oh-Zhou/platina-droidspace-ksu`（同 SoC 的 SDM660，4.19 + Android 16 已验证）
  的 `kernel-package/`：本仓库的 4.19 符号名校正与三个构建修正均以此为准，
  并按本树逐条复核
- ReSukiSU 官方文档 `resukisu.org/guide/manual-integrate.html`
