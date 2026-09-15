#!/usr/bin/env bash
# 静态检查：拦住两类已经踩过的坑（在昂贵的编译之前就跑，失败即中止）
#   1) bash 语法（bash -n）
#   2) 「未加花括号的 $VAR 之后紧跟非 ASCII 字节」——bash 会把多字节字符的首字节
#      吃进变量名，在 set -u 下表现为 unbound variable（本仓库已踩过两次）。
source "$(dirname "$0")/lib.sh"

bad=0
FILES=()
for f in "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/scripts/tests/*.sh "$REPO_ROOT"/anykernel/*.sh; do
  [ -f "$f" ] && FILES+=("$f")
done
[ "${#FILES[@]}" -gt 0 ] || die "没找到要检查的脚本"

log "静态检查 1/2：bash 语法（${#FILES[@]} 个文件）"
for f in "${FILES[@]}"; do
  bash -n "$f" || { warn "语法错误: ${f#"$REPO_ROOT"/}"; bad=$((bad + 1)); }
done

log "静态检查 2/2：变量名后紧跟非 ASCII 字节"
# 只有「未加花括号」的形式会出问题，写成 ${X} 时 bash 明确知道变量名边界，所以只匹配前一种；
# 注释行不参与执行，直接跳过（LC_ALL=C 让字符类比只覆盖 ASCII 字节）。
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  warn "  ${hit#"$REPO_ROOT"/}"
  bad=$((bad + 1))
done < <(LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^[:space:][:punct:][:alnum:]]' "${FILES[@]}" 2>/dev/null \
           | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)

[ "$bad" -eq 0 ] || die "静态检查发现 $bad 个问题（上面已列出）；变量后面接中文标点时请写成 \${VAR}"
log "静态检查通过 ✔"
