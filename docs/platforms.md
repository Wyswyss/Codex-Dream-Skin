# 平台对照

## 运行模型

两端都只给官方 Codex 的渲染页面增加 CSS 与装饰 DOM，不替换原生侧栏、输入框、建议卡，也不修改 `app.asar` 或官方签名。传输方式并不相同：

```text
Windows 安全模式
Node 守护进程 ──启动──▶ 官方 Store Codex
       │                    ▲
       └── 继承的匿名管道 ──┘  CDP；无 TCP 监听/无回退

macOS upstream 模式
主题工具 ── 127.0.0.1 回环 CDP ──▶ 官方 Codex
```

Windows 的 Node 守护进程持有这对私有管道，并负责重载后的重新注入。它必须在主题会话期间保持运行；关闭守护进程会关闭这次主题化的 Codex。macOS 回环端点不会暴露到局域网，但仍可被同一用户下的其他本机进程访问。

## 路径速查

### macOS

| 用途 | 路径 |
|------|------|
| 源码（本整理包） | `Codex-Dream-Skin/macos/` |
| 安装后引擎 | `~/.codex/codex-dream-skin-studio` |
| 状态 / 日志 | `~/Library/Application Support/CodexDreamSkinStudio` |
| Codex 配置 | `~/.codex/config.toml`（仅外观相关项可能被改，可恢复） |
| CDP 传输 | `127.0.0.1` 回环端点（无同一用户认证） |

### Windows

| 用途 | 路径 |
|------|------|
| 源码（本整理包） | `Codex-Dream-Skin/windows/` |
| 状态 / 运行文件 | `%LOCALAPPDATA%\CodexDreamSkin` |
| Codex 配置 | `%USERPROFILE%\.codex\config.toml` |
| CDP 传输 | 启动时继承的 `--remote-debugging-pipe`（不监听 TCP） |
| 官方应用 | 每次动态解析已注册、非开发模式且 `SignatureKind=Store` 的 `OpenAI.Codex` 包 |

## 能力矩阵

| 功能 | macOS | Windows |
|------|:-----:|:-------:|
| 安装脚本 | ✅ | ✅ |
| 启动 + 注入 | ✅ | ✅，私有管道 |
| 导航 / renderer 重载后重应用 | ✅ | ✅，守护进程须保持运行 |
| 一键恢复 | ✅ | ✅ |
| 自动 verify | ✅ | ✅，新鲜状态 + 会话 / 进程身份 |
| 通过 CDP 截图 | ✅ | ❌，安全模式不开放第二连接 |
| 用户选图定制 | ✅ | ❌ |
| 官方签名校验 | ✅ | Store 签名类型 + 包身份 |
| 客户部署提示词 | ✅ | ❌（可用 Mac 文案改写） |
| 打客户 ZIP | ✅ `build-client-release.sh` | 手动压缩 `windows/` |

## Windows 安全边界与限制

- 安全模式不会启动 `--remote-debugging-port`，也不会在管道失败时回退到 TCP。Verify 读取本次会话绑定、原子写入且满足新鲜度要求的本地状态，再核对 Node 与 Codex 的精确路径、PID、启动时间、参数和 Store 包身份。
- 状态文件不是抵抗同一用户恶意进程的密码学认证。匿名管道显著减少了偶然或跨进程访问面，但无法防御已经能以同一用户执行、复制句柄或向进程注入代码的恶意软件。
- Windows 需要 Node.js 22 或更新版本。Store 包更新后会在下次启动时重新发现包；若 DOM 结构变化，注入会安全失败并需要更新适配。
- Appx、WindowsApps、`app.asar` 和签名保持不变。`config.toml` 只允许安全编辑已知外观键：严格 UTF-8、原始字节备份、并发修改检测和可恢复原子替换。
- 自动验证只证明进程、会话与注入标记在最近一次心跳时一致，不等于视觉验收。发布前仍需在真实 Windows + 当前 Store Codex 上检查主页、普通任务、导航重载、辅助窗口以及 Restore / 重应用闭环。

## 不要放进这个目录的东西

- API Key、`.codex/auth.json`
- 中转站密钥、服务器私钥
- 含客户隐私的实机截图（若要公开）
