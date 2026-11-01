#!/usr/bin/env bash
# 在服务器上启动网页预览（热重载）：
#   tmux 会话 ark 里开三个窗口：
#     app    flutter run 网页开发服务器（端口 8090）
#     proxy  wenku8 转发程序（端口 8091）
#     watch  每 15 秒检查一次 GitHub，有新提交就拉取并热重载
#
# 用法：tool/preview_server.sh <监听地址，建议用 Tailscale IP>
# 环境：FLUTTER_HOME 指向 Flutter 目录；需要代理时提前 export https_proxy
set -euo pipefail

if [[ "${1:-}" == "--watch" ]]; then
  BIND="$2"; BRANCH="$3"
  REPO="$(cd "$(dirname "$0")/.." && pwd)"
  cd "$REPO"
  while true; do
    sleep 15
    git fetch -q origin "$BRANCH" || continue
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$BRANCH")" ]] && continue
    changed="$(git diff --name-only HEAD "origin/$BRANCH")"
    git merge -q --ff-only "origin/$BRANCH" || { echo "无法快进合并，请手动处理"; continue; }
    echo "$(date '+%H:%M:%S') 更新到 $(git log -1 --format='%h %s')"
    if grep -qE '^(pubspec\.yaml|tool/preview_proxy\.dart)$' <<<"$changed"; then
      # 依赖或转发程序变了：热重载不够，整体重启
      # 重启会关掉当前 tmux 会话（包括这个窗口），所以放到会话外面执行
      setsid nohup bash "$REPO/tool/preview_server.sh" "$BIND" >/tmp/ark_preview_restart.log 2>&1 &
      exit 0
    fi
    tmux send-keys -t ark:app "${RELOAD_KEY:-r}"
  done
fi

BIND="${1:?用法: tool/preview_server.sh <监听地址>}"
FLUTTER="${FLUTTER_HOME:?请设置 FLUTTER_HOME}/bin/flutter"
DART="${FLUTTER_HOME}/bin/dart"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
SESSION=ark

APP_CMD="cd '$REPO' && '$FLUTTER' run -d web-server -t lib/next/main.dart --web-hostname '$BIND' --web-port 8090"
PROXY_CMD="cd '$REPO' && PREVIEW_BIND='$BIND' PREVIEW_PORT=8091 '$DART' run tool/preview_proxy.dart"

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -n app "$APP_CMD; bash"
tmux new-window -t "$SESSION" -n proxy "$PROXY_CMD; bash"
tmux new-window -t "$SESSION" -n watch "RELOAD_KEY='${RELOAD_KEY:-r}' bash '$REPO/tool/preview_server.sh' --watch '$BIND' '$BRANCH'"
echo "已启动：http://$BIND:8090  （tmux attach -t $SESSION 查看）"
