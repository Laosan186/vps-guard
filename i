#!/usr/bin/env bash
# vps-guard 安装入口。用 root 运行：bash <(curl -fsSL https://laosan186.github.io/vps-guard/i)
# 做的事：把主脚本下载到 /usr/local/bin/vps-traffic-guard，再运行它的 install，参数原样传过去（例如 --yes）。
# 已经装过时再运行一次就是更新，配置和计数保留。
# 主脚本源码：https://github.com/Laosan186/vps-guard/blob/main/vps-traffic-guard.sh
# 全部写在 main 里、最后一行才调用：这个文件没收完整时什么都不会执行。
set -euo pipefail

main() {
  local url="https://raw.githubusercontent.com/Laosan186/vps-guard/main/vps-traffic-guard.sh"
  local bin="/usr/local/bin/vps-traffic-guard" tmp

  [[ $(id -u) == 0 ]] || { echo "请用 root 运行：先执行 sudo -i，再粘贴命令" >&2; exit 1; }
  command -v curl >/dev/null 2>&1 || { echo "缺少 curl：先安装（apt install -y curl 或 yum install -y curl）" >&2; exit 1; }

  tmp=$(mktemp)
  trap "rm -f '$tmp'" EXIT   # 现在就展开路径：set -e 中途退出时 main 的局部变量已经没了
  echo "正在下载 vps-traffic-guard ……"
  curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 "$url" -o "$tmp" || { echo "下载失败：$url" >&2; exit 1; }
  # 下载不完整、或拿到的不是这个脚本（比如被换成了网页）就停下，不覆盖已安装的版本。
  # 主脚本的最后两行固定是 main 调用，截在函数之间的半截脚本 bash -n 也能通过，所以要单独查结尾。
  if [[ $(head -n 1 "$tmp") != '#!/usr/bin/env bash' ]] || ! grep -q '^VERSION=' "$tmp" ||
     [[ $(tail -n 2 "$tmp") != $'  main "$@"\nfi' ]] || ! bash -n "$tmp" 2>/dev/null; then
    echo "下载的文件不完整或不对，已停止，什么都没改。" >&2
    exit 1
  fi
  mkdir -p "${bin%/*}"
  install -m 755 "$tmp" "$bin"
  rm -f "$tmp"
  trap - EXIT

  # 用 curl ... | bash 运行时，标准输入是管道；接回终端，安装时才能提问
  if [[ ! -t 0 ]] && { : </dev/tty; } 2>/dev/null; then
    exec bash "$bin" install "$@" </dev/tty
  fi
  exec bash "$bin" install "$@"
}

main "$@"
