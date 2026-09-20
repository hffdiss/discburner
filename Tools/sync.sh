#!/usr/bin/env bash
#
# 一键同步：把工作区的改动提交并推送到 GitHub（origin = hffdiss/discburner）。
#
#   ./Tools/sync.sh                 自动生成提交说明
#   ./Tools/sync.sh "修复追加写"      用给定的提交说明
#   ./Tools/sync.sh "改速度档位" --test  提交前先跑一遍自检，没过就不推
#
# 每次 `git commit` 之后也会由 .git/hooks/post-commit 自动推送，
# 这个脚本只是把「加进来 + 写说明 + 提交 + 推送」四步合成一条命令。

set -euo pipefail
cd "$(dirname "$0")/.."

message=""
run_tests=0
for arg in "$@"; do
    case "$arg" in
        --test) run_tests=1 ;;
        *) message="$arg" ;;
    esac
done

if [ "$run_tests" = "1" ]; then
    selftest=".build-manual/universal/discburn-selftest"
    if [ -x "$selftest" ]; then
        echo "· 先跑自检…"
        "$selftest" | tail -1
    else
        echo "· 还没构建过自检程序，先 ./build.sh"
        exit 1
    fi
fi

if [ -z "$(git status --porcelain)" ]; then
    echo "没有需要提交的改动，工作区是干净的。"
    exit 0
fi

if [ -z "$message" ]; then
    message="更新：$(date '+%Y-%m-%d %H:%M')"
fi

git add -A
git commit -m "$message"
git push origin main

echo "已推送到 $(git remote get-url origin)"
