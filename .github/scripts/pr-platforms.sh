#!/usr/bin/env bash
set -eu

platforms=android,macos,windows
files=$(git diff --name-only "$1...$2")
# 清单中的依赖、资源、字体等改动影响三端；发版机器人只改 version 时沿用快速路径。
if ! grep -Fxq pubspec.lock <<<"$files" && git diff --quiet -I '^version:' "$1...$2" -- pubspec.yaml; then
  platforms=
  grep -qE '^(lib|assets|android)/' <<<"$files" && platforms+=android,
  grep -q '^macos/' <<<"$files" && platforms+=macos,
  grep -q '^windows/' <<<"$files" && platforms+=windows,
  # 改动涉及平台适配、网络适配器、安全存储、字体、TTS 或导出文件流时，同步触发桌面端编译守卫
  if grep -qE '^lib/next/(net_|session\.dart|web_fetch\.dart|security\.dart|fonts\.dart|export_book\.dart|reader/reader_tts\.dart)' <<<"$files"; then
    [[ "$platforms" == *macos* ]] || platforms+=macos,
    [[ "$platforms" == *windows* ]] || platforms+=windows,
  fi
fi
echo "${platforms%,}"
