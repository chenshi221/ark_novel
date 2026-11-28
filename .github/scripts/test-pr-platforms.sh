#!/usr/bin/env bash
set -eu

selector="$(cd "$(dirname "$0")" && pwd)/pr-platforms.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
cd "$fixture"
git init -q
git config user.name fixture
git config user.email fixture@example.invalid
git config commit.gpgsign false
printf 'name: fixture\nversion: 1.0.0+1\n' > pubspec.yaml
git add .
git commit -qm base

expect_platforms() {
  git add .
  git commit -qm "$1"
  actual=$(bash "$selector" HEAD^ HEAD)
  if [[ "$actual" != "$2" ]]; then
    echo "FAIL $1 — expected [$2], got [$actual]" >&2
    exit 1
  fi
}

all=android,macos,windows
printf 'name: fixture\nversion: 1.0.1+2\n' > pubspec.yaml
expect_platforms version-only ''
printf 'flutter:\n  assets:\n    - assets/icon.png\n' >> pubspec.yaml
expect_platforms assets-manifest "$all"
printf 'changed\n' > pubspec.lock
expect_platforms dependency-lock "$all"
mkdir -p lib/next
touch lib/next/main.dart
expect_platforms app-code android
touch lib/next/session.dart
expect_platforms platform-adapter "$all"
