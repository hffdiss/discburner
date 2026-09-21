# 项目约定（给协作者和 AI 助手）

这是 **DiscBurner（光盘刻录）**：macOS 上把任意文件刻到 CD / DVD / 蓝光的应用，
图形界面 + 命令行两套入口。写盘用系统自带的 `drutil`，映像用 `xorriso`（首选，
多区段嫁接靠它）/ `mkisofs`（兜底）/ 系统自带的 `hdiutil makehybrid`。

## 硬性约定

- **一律用中文**：代码注释、界面文案、文档、提交说明，以及跟用户对话，全部中文。
- **不要用 `swift build`**：这台机器只有 Command Line Tools（无 Xcode），SwiftPM 会因为没有 xctest 失败。
  构建一律用 `./build.sh`（约 110 秒，产出 `dist/DiscBurner.app`、`.dmg`、`.zip`）。
- **自检必须全过**：`./.build-manual/universal/discburn-selftest`，加一条断言就要同步更新 README 里的项数。
- **编译产物不进仓库**：`.build-manual/`、`build/`、`dist/` 已在 `.gitignore` 里，靠 `build.sh` 重新生成。
- **每个版本有自己的目录**：`build.sh` 打包后会在 `dist/v<版本>/` 里放这一版的
  App、dmg、zip 和 `SHA256.txt`（本地归档，同样不进仓库）。

## 改完之后：自动提交并推送

默认流程是**改完就跑自检、然后提交并推到 `origin/main`**（`github.com/hffdiss/discburner`）：

```bash
./Tools/sync.sh "一句话说明这次改了什么" --test
```

`git commit` 之后 `.git/hooks/post-commit` 会自动 `git push origin main`，
所以手动 `git add -A && git commit` 也会自动同步到远端。

例外：用户明确说「先别提交 / 先别推」时，就只改文件、不提交。

## 发新版本

版本号在仓库根的 `VERSION` 文件里（`X.Y.Z`），发版一条命令：

```bash
./Tools/release.sh patch "这次改了什么"    # 或 minor / major / 直接写 1.2.3
```

它会构建、跑自检、改 `VERSION`、提交、打 `vX.Y.Z` tag、建 GitHub Release，
并把 `dist/DiscBurner-<版本>.dmg` 与 `.zip` 传上去。
没验证过就先 `--dry-run`；想先发草稿就 `--draft`。发版前工作区必须是干净的。

## 真机相关的注意事项

- 光驱：PIONEER DVD-RW DVR-XU01C（USB，`drutil` 里显示 `SupportLevel: Unsupported`，但可用）。
- **这台驱动器不支持模拟刻录**：`drutil burn -test`、`hdiutil burn -testburn` 都会报「该光盘与操作的类型不符」，
  所以界面里的「测试模式」在本机跑不起来，验证只能真刻。
- **刻录后端必须是 `drutil burn`**：`hdiutil burn` 即使加 `-noforceclose` 也会把 DVD+R 收尾，导致无法追加。
- 驱动器偶尔在刻完后短暂「认不到盘」（`drutil status` 报 No Media Inserted），
  `drutil eject` + `drutil tray close` 循环几次、或手动弹出再放回即可恢复，盘上的数据不受影响。
- 任何会写盘的验证都要先跟用户确认，别拿用户的盘做实验。

## 多区段追加（容易踩的坑）

- **规范**：ISO 9660 多区段要求**光盘绝对地址**（第一帧 = 0），而且新段目录树要包含之前所有段的文件。
  每段各自「从本段开头算地址」这种写法，Windows / Linux 读最后一段时会指到错误扇区，新老文件都看不到。
- **实现**：`xorriso -as mkisofs -M <旧段来源> -C 上段起始,下段起始`。旧文件只是被引用，不重写数据。
- **旧段来源**：优先 `-M stdio:/dev/diskN`（卷挂载着会 Resource busy，先 `diskutil unmount` 独占读盘）；
  读不了就走 `Multisession.sparseGraftImage` 把旧段按扇区抄成稀疏映像再 `-M <文件>`。
- **自校验**：`Multisession.verifyGraft` 会核对「根目录是绝对地址」+「引用了旧文件」，不过就中止刻录。
- **mkisofs 的坑**：cdrtools 的 `mkisofs` 写 Joliet 名字只保留前 8 个字符（中文长名变 NUL），
  所以只在没装 xorriso 时用它，并且要提示用户装 xorriso。

## 看界面的正确姿势

- **优先看真窗口**：`open dist/DiscBurner.app`，然后
  `osascript -e 'tell application "System Events" to tell process "DiscBurner" to get {position, size} of window 1'`
  拿到位置，再 `screencapture -x -R x,y,w,h /tmp/shot.png`。这是唯一可靠的界面验收方式。
- **`--render-preview` 只当粗略参考**：离屏渲染没有窗口，左栏「要刻录的内容」那块
  （`List` / `VSplitView` 撑起来的部分）画不出来，会出现黑块和缺文字，别据此判断 UI 坏了；
  右栏、底栏是准的。
- 截图用的启动参数有顺序要求：解析时先找 `--demo-compatibility`，所以两者同时用要写成
  `--args --demo-compatibility --demo-items <路径…>`，反了会加不进内容。
  `--demo-notice` 可以把「刻录完成」弹窗直接摆出来（不用真刻盘）。
- 第一次让新构建的 App 读光盘时，macOS 可能弹「想访问可移除宗卷上的文件」，选「允许」。
- **改外观/主题时别踩的坑**：`NSApp.appearance` 一旦被显式写过（哪怕写的是 `nil`），
  AppKit 会把这个 App 的外观钉在当时的系统外观上——之后系统在深色/浅色之间自动切换它不再跟，
  而新开的 sheet 仍按当前系统外观画，结果就是一个窗口深、一个窗口浅（实测踩过）。
  所以「跟随系统」这一档**不要写 `NSApp.appearance`**，只在明确选了浅色/深色时才写。
- 系统外观是「自动」时，一天里会在深色和浅色之间翻，判断「界面是不是坏了」之前先看一眼
  `defaults read -g AppleInterfaceStyle`（读不到 = 当前是浅色）。

## 目录结构

```
Sources/DiscBurnKit/        核心库：驱动检测、暂存、映像生成、刻录 / 擦除、兼容性预检
Sources/discburn/           命令行工具
Sources/DiscBurnerApp/      SwiftUI 图形界面
Sources/DiscBurnSelfTest/   自检程序
Tools/make_icon.swift       生成 App 图标
Tools/sync.sh               提交并推送
docs/                       README 用的截图
```
