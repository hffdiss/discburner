#!/usr/bin/env bash
#
# 打一个版本并发布到 GitHub Release（自动附上 .dmg 与 .zip）。
#
#   ./Tools/release.sh 1.0.1                   指定版本号
#   ./Tools/release.sh patch "修了追加写"       按当前版本自动 +1（patch / minor / major）
#   ./Tools/release.sh minor --draft           先发成草稿，自己检查完再在网页上点发布
#
# 做的事：
#   1. 把版本号写进仓库根的 VERSION 文件
#   2. 用这个版本号跑 ./build.sh（产出 dist/DiscBurner-<版本>.dmg 与 .zip）
#   3. 跑一遍自检，不过就停在这里，不发版
#   4. 提交 VERSION、打 tag vX.Y.Z、推送（commit 由 post-commit 钩子推 main）
#   5. 调 GitHub API 建 Release 并把 .dmg / .zip 传上去
#
# 需要能访问 github.com 的凭据：默认用 git 的 credential helper（本机是 store，
# 存在 ~/.git-credentials）；也可以用 GITHUB_TOKEN 环境变量临时覆盖。

set -euo pipefail
cd "$(dirname "$0")/.."

REPO="hffdiss/discburner"

version_arg=""
notes=""
notes_file=""
draft=0
allow_dirty=0
dry_run=0

while [ $# -gt 0 ]; do
    case "$1" in
        --draft) draft=1 ;;
        --allow-dirty) allow_dirty=1 ;;
        --dry-run) dry_run=1 ;;
        --notes) shift; notes="${1:-}" ;;
        --notes-file) shift; notes_file="${1:-}" ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        -*) echo "不认识的参数：$1" >&2; exit 2 ;;
        *) if [ -z "$version_arg" ]; then version_arg="$1"; else notes="$1"; fi ;;
    esac
    shift
done

say() { printf '\033[1m· %s\033[0m\n' "$1"; }
die() { printf '\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

current_version="$(cat VERSION 2>/dev/null || echo 1.0.0)"

# ---------------------------------------------------------------- 1. 版本号

bump() {
    local base="${1%-*}" kind="$2"
    local major minor patch
    IFS='.' read -r major minor patch <<<"$base"
    major="${major:-0}"; minor="${minor:-0}"; patch="${patch:-0}"
    case "$kind" in
        major) echo "$((major + 1)).0.0" ;;
        minor) echo "${major}.$((minor + 1)).0" ;;
        patch) echo "${major}.${minor}.$((patch + 1))" ;;
    esac
}

case "$version_arg" in
    "")            version="$current_version" ;;
    major|minor|patch) version="$(bump "$current_version" "$version_arg")" ;;
    [0-9]*.[0-9]*.[0-9]*) version="$version_arg" ;;
    *) die "版本号要写成 X.Y.Z，或者用 major / minor / patch 自动 +1（当前 $current_version）" ;;
esac

tag="v$version"
say "版本：$current_version → $version（tag $tag）"

# ---------------------------------------------------------------- 2. 工作区检查

if [ -n "$(git status --porcelain)" ] && [ "$allow_dirty" = "0" ]; then
    echo "工作区还有没提交的改动：" >&2
    git status --short >&2
    die "先提交（./Tools/sync.sh）再做发布；确实要带着未提交的改动发版就加 --allow-dirty"
fi

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    die "本地已经有 $tag 了，换个版本号（或先 git tag -d $tag）"
fi

# ---------------------------------------------------------------- 3. 凭据（先检查，别构建完了才发现推不上去）

token="${GITHUB_TOKEN:-}"
if [ -z "$token" ]; then
    token="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null \
        | sed -n 's/^password=//p' | head -1)"
fi
[ -n "$token" ] || die "拿不到 GitHub 凭据：设置 GITHUB_TOKEN，或先让 git 记住 github.com 的账号密码"

whoami_json="$(curl -sS -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$REPO")"
printf '%s' "$whoami_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("full_name"):
    print("· 目标仓库：", d["full_name"], "（私有）" if d.get("private") else "（公开）")
    raise SystemExit(0)
print("✗ 访问仓库失败：", d.get("message", d))
raise SystemExit(1)
' || die "GitHub 凭据或仓库不对"

# ---------------------------------------------------------------- 3. 构建 + 自检

say "构建 $version（约 110 秒）"
VERSION="$version" ./build.sh >/tmp/discburner-build.log 2>&1 || {
    tail -20 /tmp/discburner-build.log >&2
    die "构建失败，日志在 /tmp/discburner-build.log"
}
tail -3 /tmp/discburner-build.log | sed 's/^/  /'

dmg="dist/DiscBurner-$version.dmg"
zip="dist/DiscBurner-$version.zip"
[ -f "$dmg" ] || die "没找到 $dmg"
[ -f "$zip" ] || die "没找到 $zip"

say "跑自检"
selftest=".build-manual/universal/discburn-selftest"
test_output="$("$selftest")" || { echo "$test_output" | tail -10 >&2; die "自检没过，不发版"; }
test_line="$(printf '%s\n' "$test_output" | tail -1)"
echo "  $test_line"

# ---------------------------------------------------------------- 4. 发布说明

previous_tag="$(git describe --tags --abbrev=0 HEAD 2>/dev/null || true)"
if [ -n "$previous_tag" ]; then
    changes="$(git log --no-merges --pretty='- %s' "$previous_tag..HEAD" | head -20)"
else
    changes="$(git log --no-merges --pretty='- %s' -12 HEAD)"
fi

if [ -n "$notes" ]; then
    body="$notes"
elif [ -n "$notes_file" ]; then
    body="$(cat "$notes_file")"
else
    body="$(
        cat <<EOF
把任意文件刻录到 CD / DVD / 蓝光的 macOS 应用，图形界面 + 命令行两套入口。

### 安装

1. 打开 \`DiscBurner-$version.dmg\`，把「光盘刻录」拖进「应用程序」
2. 首次打开如果被 Gatekeeper 拦住，右键 →「打开」（ad-hoc 签名，没有做 Apple 公证）
3. 或者直接用 \`DiscBurner-$version.zip\` 解压

### 这个版本

$changes

### 说明

- $test_line
- 详细用法、兼容性预检规则、追加写说明见仓库 README
EOF
    )"
fi

if [ "$dry_run" = "1" ]; then
    say "dry-run：构建与自检都过了，跳过提交 / 打 tag / 建 Release"
    printf '%s\n' "$body"
    exit 0
fi

# ---------------------------------------------------------------- 5. 改版本号 + 提交 + 打 tag

printf '%s\n' "$version" >VERSION

say "提交并打 tag"
if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -q -m "发布 $tag"
else
    echo "  （版本号没变，直接给当前提交打 tag）"
fi
git tag -a "$tag" -m "光盘刻录 $version"
git push origin "$tag"

# ---------------------------------------------------------------- 6. 建 Release + 上传

say "创建 GitHub Release"
payload="$(VERSION="$version" TAG="$tag" DRAFT="$draft" BODY="$body" python3 - <<'PY'
import json, os
print(json.dumps({
    "tag_name": os.environ["TAG"],
    "name": "光盘刻录 " + os.environ["VERSION"],
    "body": os.environ["BODY"],
    "draft": os.environ["DRAFT"] == "1",
    "prerelease": False,
}, ensure_ascii=False))
PY
)"

response="$(curl -sS -X POST "https://api.github.com/repos/$REPO/releases" \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -d "$payload")"

release_id="$(printf '%s' "$response" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id",""))' 2>/dev/null || true)"
release_url="$(printf '%s' "$response" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("html_url",""))' 2>/dev/null || true)"
if [ -z "$release_id" ]; then
    printf '%s\n' "$response" >&2
    die "创建 Release 失败（上面是 GitHub 返回的内容）"
fi

for file in "$dmg" "$zip"; do
    name="$(basename "$file")"
    say "上传 $name（$(du -h "$file" | cut -f1 | tr -d ' ')）"
    upload="$(curl -sS -X POST \
        "https://uploads.github.com/repos/$REPO/releases/$release_id/assets?name=$name" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/octet-stream" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        --data-binary "@$file")"
    printf '%s' "$upload" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("state") == "uploaded" or d.get("browser_download_url"):
    print("  ✓", d.get("name"), d.get("size"), "bytes")
else:
    print("  ✗", d)
    sys.exit(1)
' || die "上传 $name 失败"
done

echo
say "发布完成：$release_url"
