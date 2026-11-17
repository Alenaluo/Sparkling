# Sparkling ✦

Mac 菜单栏里的灵感便签。在任何 App 里按 `⌥⇧Space` 呼出面板，写下想法，选一个项目（点 tag、`⌘1–9`、`Tab`，或在正文里打 `@` 补全），`⏎` 就装好了；没选项目的进「未归类」。

每个项目是一个文件夹，每条灵感是一个 Markdown 文件，默认放在 `~/Documents/Sparkling`，可以直接用 Obsidian、VS Code 或 Finder 打开、同步、备份。

**剪贴板历史**（0.1.2 起）：按 `⌥⇧V` 翻最近复制过的文字、截图和文件，`⏎` 复制回去，`⌘S` 存成灵感（图片拷进项目的 `assets/`，文件只写链接）。默认保留最近 50 条，只存在这台 Mac 上（`~/Library/Application Support/Sparkling/clipboard/`），不上传；密码管理器标记的敏感内容一律跳过。也可以在主窗口侧栏「剪贴板」里浏览。

**中文 / English**（0.1.2 起）：偏好设置 ›「通用」›「语言」可选跟随系统、中文或 English，重启后生效。

## 下载安装

要求：macOS 14 Sonoma 或更新，Apple 芯片和 Intel 都支持。

1. 到 [Releases](../../releases) 下载最新的 `Sparkling-x.y.z.dmg`。
2. 双击打开，把 **Sparkling** 拖进「应用程序」。
3. 第一次打开会提示「无法验证开发者」或「Apple 无法检查其是否包含恶意软件」——这是因为本 App 没有付费做 Apple 公证，不是病毒。放行方法任选其一：
   - **系统设置 › 隐私与安全性**，往下拉到安全性，点「仍要打开」，再输入密码确认；
   - 或在「终端」里执行一次：
     ```bash
     xattr -dr com.apple.quarantine /Applications/Sparkling.app
     ```
4. 打开后菜单栏出现图标，跟着首次引导选好数据文件夹即可。

### 常见问题

- **按快捷键没反应**：多半是和别的 App（Raycast、Alfred、ChatGPT 等）抢了同一个键。点菜单栏图标 ›「偏好设置…」，在「通用」页的「呼出快捷键」里换一个；剪贴板的 `⌥⇧V` 在「剪贴板」页里改。
- **不想记录剪贴板**：偏好设置 ›「剪贴板」关掉「记录剪贴板」，或把某些 App 加进「不记录这些 App」；「清空剪贴板历史…」会删掉全部记录。
- **开机自启**：在偏好设置里打开。
- **卸载**：退出后把 `/Applications/Sparkling.app` 拖进废纸篓。你的灵感文件留在数据文件夹里，不会被删。

## 开发

### 构建与运行

```bash
swift build && swift test          # 构建 + 单测（IdeaCoreTests 19 项、IdeaUITests 8 项）
./scripts/run.sh                   # 开发运行：根目录 ~/IdeaNotes-dev，日志 build/run.log
SPARKLING_SKIP_ONBOARDING=1 ./scripts/run.sh   # 跳过首次引导
./scripts/bundle.sh release --install           # 正式包装到 /Applications 并启动
./scripts/package.sh                            # 打分发包 dist/Sparkling-<版本>.dmg（通用二进制）
```

- 根目录取值：环境变量 `SPARKLING_ROOT` > 偏好设置 > `~/Documents/Sparkling`（0.1 版默认是 `~/Documents/IdeaNotes`，首次启动自动改名迁移）。开发期别用 `~/Documents`：ad-hoc 签名每次构建身份都变，文稿文件夹授权会反复弹。
- 签名：`bundle.sh` 优先用 `SPARKLING_SIGN_ID`，其次钥匙串里的自签证书「Sparkling Dev」（本机已建，钥匙串访问 › 证书助理 › 创建证书，类型选代码签名），都没有才 ad-hoc。固定身份才能让文稿授权和开机自启稳定。自签证书显示 `CSSMERR_TP_NOT_TRUSTED` 属正常，不影响本机使用。
- 日志：`/usr/bin/log stream --predicate 'subsystem == "local.sparkling"' --level debug`（zsh 里 `log` 是内建命令，要写全路径）。包含热键到面板获得焦点的耗时、每次保存的文件名、按键决策。

### ideactl（命令行调试）

```bash
swift run ideactl --root ~/IdeaNotes-dev repos
swift run ideactl --root ~/IdeaNotes-dev repo add 播放器重构 --short pr
swift run ideactl --root ~/IdeaNotes-dev save "长按右侧 2 倍速 #交互" --repo 播放器重构
swift run ideactl --root ~/IdeaNotes-dev match bfq     # @ 补全结果
swift run ideactl --root ~/IdeaNotes-dev grep 倍速      # 跨仓库搜索
```

### 结构

- `Sources/IdeaCore`：纯逻辑（文件头读写、存储、拼音匹配、@ 解析、tag 选择、按键决策、搜索、剪贴板历史、中英文案），全部有单测。
- `Sources/IdeaUI`：AppKit + SwiftUI 界面（热键、呼出面板、剪贴板面板、HUD、灵感库、设置、首次引导）。
- `Sources/Sparkling`：App 入口；`Sources/ideactl`：命令行工具。

### 已知限制（MVP）

- 外部改动不实时同步：重启、打开全部灵感窗口或「文件 › 重新读取文件夹」后读到。
- 拼音由系统按单字转换，多音字可能不准（「重构」默认短码是 `bfqzg`）；常见多音字已加备选，`@bfqcg` 也能匹配。
- 保存动效用淡出代替「便签飞向菜单栏」；图标暂用 SF Symbols 占位（设计待画 inbox / repo / move / trash）。

### 底纹素材

`Sources/IdeaUI/TextureAssets.swift` 由设计稿里的 SVG 底纹生成（源文件不在本仓库）（SVG 直接内嵌，加载时把 `#37352F` 换成主题正文色）。素材更新后在仓库根目录 `Tools/` 重跑生成脚本，或手动把新 SVG 粘进对应常量。

### 发布新版本

1. 改 `Resources/Info.plist` 里的 `CFBundleShortVersionString`（如 `0.1.1`）和 `CFBundleVersion`（+1）。
2. `./scripts/package.sh`，得到 `dist/Sparkling-<版本>.dmg` 和 `.sha256`。
3. 提交并打 tag：`git commit -am "v0.1.1" && git tag v0.1.1 && git push --tags`。
4. GitHub 仓库页 › Releases › Draft a new release，选这个 tag，把 dmg 和 sha256 拖进附件，发布。

想让用户免去「仍要打开」这一步：加入 Apple Developer Program（99 美元/年），用 Developer ID 证书签名并公证——`package.sh` 已支持，见脚本顶部注释。

## 许可

MIT，见 [LICENSE](LICENSE)。
