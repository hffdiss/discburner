#!/bin/bash
#
# 一键构建「光盘刻录」App（不需要 Xcode，只需要 Command Line Tools）。
#
# 做的事：
#   1. 为 x86_64 与 arm64 分别编译 DiscBurnKit、discburn、自检程序、GUI
#   2. lipo 成通用二进制（Intel 与 Apple Silicon 都能原生运行）
#   3. 组装 DiscBurner.app（图标、Info.plist、本地化、内置命令行工具）
#   4. ad-hoc 签名并校验
#   5. 打包成 DMG（拖进「应用程序」即可）和 ZIP
#
# 用法：
#   ./build.sh                     # 完整构建 + 打包
#   ARCHS=x86_64 ./build.sh        # 只编当前架构，快一些
#   ./build.sh --no-package        # 只构建 App，不生成 DMG/ZIP
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/.build-manual"
DIST="$ROOT/dist"
ARCHS="${ARCHS:-x86_64 arm64}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-11.0}"
VERSION="${VERSION:-1.0.0}"
PACKAGE=1

for argument in "$@"; do
    case "$argument" in
        --no-package) PACKAGE=0 ;;
        --help|-h) sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    esac
done

say() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

SDK_PATH="$(xcrun --show-sdk-path 2>/dev/null || true)"
[[ -n "$SDK_PATH" ]] || fail "找不到 macOS SDK，请先安装 Command Line Tools：xcode-select --install"

mkdir -p "$BUILD" "$DIST"

# ---------------------------------------------------------------- 1. 编译

build_arch() {
    local arch="$1"
    local target="${arch}-apple-macos${DEPLOYMENT_TARGET}"
    local dir="$BUILD/$arch"
    mkdir -p "$dir"

    say "· 编译 $arch"
    swiftc -O -sdk "$SDK_PATH" -target "$target" \
        -emit-module -emit-library -static \
        -module-name DiscBurnKit \
        -emit-module-path "$dir/DiscBurnKit.swiftmodule" \
        -o "$dir/libDiscBurnKit.a" \
        "$ROOT"/Sources/DiscBurnKit/*.swift

    local item target_name sources binary_name
    for item in discburn:discburn DiscBurnSelfTest:discburn-selftest DiscBurnerApp:DiscBurner; do
        target_name="${item%%:*}"
        binary_name="${item##*:}"
        swiftc -O -sdk "$SDK_PATH" -target "$target" \
            -I "$dir" -L "$dir" -lDiscBurnKit \
            "$ROOT"/Sources/"$target_name"/*.swift -o "$dir/$binary_name"
    done
}

for arch in $ARCHS; do
    build_arch "$arch"
done

# ---------------------------------------------------------------- 2. 合并

# 注意：变量后面紧跟中文时要用 ${} 包起来，否则某些 locale 下 bash 会把
# 多字节字符当成变量名的一部分（报 ARCHS: unbound variable）。
say "· 合并通用二进制（${ARCHS}）"
mkdir -p "$BUILD/universal"

universal() {
    local name="$1"
    local slices=()
    local arch
    for arch in $ARCHS; do
        slices+=("$BUILD/$arch/$name")
    done
    if [[ ${#slices[@]} -eq 1 ]]; then
        cp "${slices[0]}" "$BUILD/universal/$name"
    else
        lipo -create "${slices[@]}" -output "$BUILD/universal/$name"
    fi
}

for name in discburn discburn-selftest DiscBurner; do
    universal "$name"
done

# ---------------------------------------------------------------- 3. 组装 App

say "· 组装 DiscBurner.app"
APP="$DIST/DiscBurner.app"
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/zh-Hans.lproj"

cp "$BUILD/universal/DiscBurner" "$CONTENTS/MacOS/DiscBurner"
# 命令行工具随 App 一起分发。放在 MacOS/ 下，它会被当作嵌套代码一起签名与校验；
# 放在 Resources/ 下则不会被 App 签名覆盖。
cp "$BUILD/universal/discburn" "$CONTENTS/MacOS/discburn"

cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi

cat > "$CONTENTS/Resources/zh-Hans.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleName" = "光盘刻录";
"CFBundleDisplayName" = "光盘刻录";
STRINGS

cat > "$CONTENTS/Resources/命令行工具说明.txt" <<EOF
本 App 内置了同名的命令行工具，路径：

    /Applications/DiscBurner.app/Contents/MacOS/discburn

常用命令：

    discburn list
    discburn check ~/Documents
    discburn burn ~/Movies ~/合同.pdf --name 归档
    discburn burn ~/Documents --fix-names
    discburn burn ~/backup.iso
    discburn erase --mode quick

刻录前会先做兼容性预检（Windows 非法字符、保留名、大小写冲突、超长名…），
加 --fix-names 可以自动把不兼容的名字改掉（只改光盘里的副本）。

运行 discburn --help 查看全部选项。

版本 $VERSION
EOF

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" "$CONTENTS/Info.plist" >/dev/null

# ---------------------------------------------------------------- 4. 签名

say "· 签名与校验"
if command -v codesign >/dev/null 2>&1; then
    # 先签嵌套的可执行文件，再签整个 App
    codesign --force --sign - --timestamp=none "$CONTENTS/MacOS/discburn" >/dev/null 2>&1 || true
    if codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1; then
        if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
            say "  ad-hoc 签名完成，校验通过"
        else
            say "  签名完成，但校验未通过"
        fi
    else
        say "  ad-hoc 签名失败（App 仍可运行）"
    fi
fi

# ---------------------------------------------------------------- 5. 打包

if [[ "$PACKAGE" == "1" ]]; then
    say "· 打包 DMG 与 ZIP"
    STAGE="$BUILD/dmg-stage"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/应用程序"

    DMG="$DIST/DiscBurner-$VERSION.dmg"
    rm -f "$DMG"
    hdiutil create \
        -volname "光盘刻录 $VERSION" \
        -srcfolder "$STAGE" \
        -fs HFS+ \
        -format UDZO \
        -ov \
        "$DMG" >/dev/null

    ZIP="$DIST/DiscBurner-$VERSION.zip"
    rm -f "$ZIP"
    (cd "$DIST" && ditto -c -k --sequesterRsrc --keepParent "DiscBurner.app" "$ZIP")
fi

# ---------------------------------------------------------------- 汇总

printf '\n'
say "构建完成 🎉"
echo "  应用：      $APP"
echo "  命令行工具：$BUILD/universal/discburn"
echo "  自检程序：  $BUILD/universal/discburn-selftest"
if [[ "$PACKAGE" == "1" ]]; then
    echo "  安装包：    $DIST/DiscBurner-$VERSION.dmg"
    echo "  压缩包：    $DIST/DiscBurner-$VERSION.zip"
fi
echo ""
echo "架构：      $(lipo -archs "$CONTENTS/MacOS/DiscBurner" 2>/dev/null || echo 未知)"
echo "打开应用：  open \"$APP\""
