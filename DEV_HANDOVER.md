# TrollAgent 开发接手文档（2026-10-25）

> ⚠️ **已过期（2026-11-03 标注）**：本文档是 2026-10-25（v7.1.33-7.1.35 时代）的历史快照，所述问题（TTS 无声、HUD 语音无回复等）均已过时，后续大量版本迭代（v7.1.x→v7.2.x，含 JIT 恢复、Device Flow、系统 HID 工具等）已改变仓库状态。
> **当前状态以 [GOALS.md](GOALS.md) 为准**。本文档保留仅作历史诊断参考（TTS 协议分析、UserDefaults 隔离、远程通道边界等思路仍可复用）。

> 本文件供下一个接入的 AI 快速接手，避免重复排查。按时间顺序记录当前卡点、已做的修复、下一步。

## 一、当前状态总览

| 问题 | 状态 | 说明 |
|---|---|---|
| ① HUD 长按提示"请先允许麦克风和语音识别权限" | ✅ **已解决（7.1.33 实装验证）** | TCC entitlements 直通生效 |
| ② 聊天顶部自动朗读无声（气泡喇叭有声） | 🕐 **已提交修复待验证（7.1.34→构建产物 7.1.35）** | WS 长连接复用 + UI 诊断日志 |
| ③ HUD 长按说话后 AI 无回复 | 🆕 **新问题，未定位** | 见第五节 |

用户手机实装版本：**7.1.33**（TCC 权限修复版，`13ce9b3` 构建产物，GitHub 构建自动 bump 版本号所以产物显示 7.1.33）。
用户测试结果：HUD 不再提示权限 ✅；发语音后 AI 不回复 ❌；顶部自动朗读仍未验证新包。

## 二、版本与构建机制（重要）

- 仓库：`zrrt/TrollAgent`，main 分支。
- **GitHub Actions 每次 push 会自动 bump 版本号**（读 Info.plist 当前版本 +1，commit "[skip ci]"）——所以**提交时的版本号 ≠ 产物版本号**（产物总是 +1）。如：提交 7.1.34 → 产物 7.1.35。
- 构建产物在 Actions artifact（`TrollAgent` zip，内含 `TrollAgent.tipa`），约 161MB。
- 本地仓库：`/home/user/Doubao/chats/38448344203617282/trollmcp2_clone`（云沙箱）。
- 提交链（最近）：
  - `13ce9b3` 7.1.32：TCC entitlements 直通（主 App + HUD 加 kTCCServiceMicrophone/SpeechRecognition）→ 产物 7.1.33 ✅ 已交付已装
  - `dcf74ba` 7.1.34：WS 长连接复用 + UI 诊断日志（**编译失败**：`.waiting` 应为 `.waitingForConnectivity`）
  - `b19d38e` 7.1.34 编译修复版：**正在构建**（目标 sha=b19d38e，轮询脚本 `/tmp/poll_build.sh` 已更新）

## 三、已解决问题与方案

### ① HUD 麦克风/语音识别权限（TCC 直通）
- 根因：主 App `Support/TrollAgent.entitlements` 的 `com.apple.private.tcc.allow` 只有 PostEvent/SystemPolicyAllFiles；HUD `HUD/supports/entitlements.plist` 完全没有 tcc.allow → tccd 拒绝。
- 方案：两个 entitlements 均加入 `kTCCServiceMicrophone` + `kTCCServiceSpeechRecognition`（platform-application + tcc.allow = tccd 直接放行不弹窗，TrollStore 生态标准做法）。
- 注入点：主 App `scripts/build-ipa.sh` 用 `ldid -S"Support/TrollAgent.entitlements"`；HUD 用 `HUD/Makefile` + workflow 里 `ldid -SHUD/supports/entitlements.plist`。
- **验证：用户装 7.1.33 后不再提示权限 ✅**

## 四、进行中：自动朗读无声（②）

### 现象
- 聊天"气泡喇叭"（`speakForced`，整段一次合成）**有声** ✅
- 顶部"自动朗读开关"（`speak`，逐句流水线）开着，AI 新回复**无声** ❌
- 手机移动网络（用户切换过广西本地电脑 IP / 云沙箱，与 IP 无关——微软已升级 v2 协议，v1 全 403）

### 已确认的代码路径
- `Sources/TrollMCP2/ChatView.swift` ~1693：`.onChange(of: message.content)` → `autoSpeak(newContent)`（autoSpokenUpTo 增量防重）→ `TTSService.shared.speak(sentence)`
- `Sources/TrollMCP2/TTSService.swift`：`speak` → `enqueueSentences` → `pump` 逐句 `synthesize`；`speakForced` → `stopInternal` + 一次 `synthesize` 整段。
- `synthesize` 走微软 Edge TTS v2 协议（Sec-MS-GEC v2 双哈希 + 长 voice 名 + speech.config/ssml 双发），电脑 Python 模拟与 Swift 算法实现已对拍 3/3 MATCH。

### 已提交的修复（b19d38e，构建中）
1. **WS 长连接复用**：原实现每句新建 URLSession+WebSocket 握手，自动朗读逐句合成 = 高频握手，疑似被微软限流/静默断（气泡喇叭单次连接所以正常）。新实现复用同一条 WS 串行收发（`ensureWS`/`startReceiveLoop`/`finishSentence`，句级 20s 超时自动断线重连）。**注意 `.waitingForConnectivity` 枚举值**（编译坑已修）。
2. **UI 自诊断**：`TTSService.recentTTSLogs`（40 条环形缓冲）+ ChatView 长按顶部喇叭 → 弹窗"TTS 诊断日志" → sheet 显示最近合成/播放日志。**用户复现无声后直接长按喇叭查看卡点，绕开沙箱读文件通道**。

### 验证方法（下一步）
用户装 7.1.35 后：① 开顶部喇叭发消息 → 有无自动朗读；② 无声则长按顶部喇叭 → 看 TTS 诊断日志卡在哪一段（synthesize start / ws connected / ssml sent / turn.end / play / FAIL）。

## 五、新问题：HUD 长按说话后 AI 无回复（③，未定位）

### 现象
权限已通（不再提示），录音/识别疑似成功，但说话后无任何回复。

### 疑点（按可能性排序）
1. **HUD 独立进程 UserDefaults 隔离**：HUD bundle 是 `ch.xxtou.hudapp`（独立二进制，主 App 内嵌子包 `Payload/TrollAgent.app/hud/TrollAgentHUD.app`，`NSPrincipalClass=HUDMainApplication`）。HUD 的 `_askAI` 读主 App 写入的 `trollmcp2.model_configs`（UserDefaults）——**独立进程默认 UserDefaults 是 per-process 的**，很可能读到空 → 走 deepseek-chat 兜底；若兜底配置缺失/网络问题 → 无回复。**需要验证/修复：HUD 用 App Group `group.com.ai.iosxcode` 的 UserDefaults(suiteName:) 读写模型配置**（entitlements 已含 application-groups，App Group 通道是通的）。
2. HUD 录音/识别链路本身（识别出的文本是否为空）——需 HUD 侧日志（`tts_debug.log` 或 HUD 自带日志）实证。
3. HUD `_askAI` 网络/鉴权失败。

### 相关代码位置
- `HUD/sources/HUDRootViewController.mm`：`_ensureSpeechPermission`（~2989）、`_beginRecording`、`_askAI`、`_speakTTS`（namespace hud_v2，v2 DRM 已移植 C++）。
- `HUD/Info.plist`（bundle ch.xxtou.hudapp）、`HUD/supports/entitlements.plist`（已含 application-groups + tcc.allow）。

## 六、远程/日志通道（已探明的边界）

- 手机 TrollAgent 内置 HTTP 服务 `:8790`（局域网地址与 Bearer token **不入库**，取当前会话记忆/环境变量）：**只有 `/health` 和 `/api/tools`（GET 工具列表），无外部执行端点**（POST 全 no_route）。工具只能在 App 内嵌 AI 里执行。
- App 容器 shell.exec（Alpine）挂载只有 Workspace/Containers/System，读不到 `/var/mobile/Documents/`；`system.exec_root` 返回空（哑通道）；`/ios_workspace` 挂载状态异常（写文件能 cat 但 ls 计数 0）。
- 日志文件：`/var/mobile/Documents/tts_debug.log`（存在，~192KB，全链路插桩）。读取唯一可靠路径 = **App 内嵌 AI 用 file 工具读末尾原文**，或 **7.1.35 的 UI 诊断日志面板**（推荐，用户零操作）。
- N1 网关：公网 SSH 跳板（公网 IP/端口动态，凭据**不入库**，取会话记忆）；公网 18790→手机 8790 的转发曾被 N1 IP 池劫持（502），**局域网直连手机 8790 是通的**（手机在线时）。手机 22/22022 关闭。

## 七、下一步行动清单（给下一个 AI）

1. **等 b19d38e 构建绿**（`/tmp/poll_build.sh` 在跑，目标 sha=b19d38e；完成后 curl Actions artifact 下载 → 校验（~161MB、HUD.app 80 项）→ FileBatchUpload → present_files 交付 7.1.35）。
2. 用户装 7.1.35 → 验证顶部自动朗读；若无声 → 让用户长按顶部喇叭看 TTS 诊断日志（recentTTSLogs）→ 定位失败分支。
3. HUD 语音无回复：**优先排查 UserDefaults 跨进程隔离**——检查 HUD `_askAI` 读模型配置的方式；改为 App Group suite 读写（entitlements 已支持 `group.com.ai.iosxcode`）。
4. 若 7.1.35 自动朗读仍无声且日志指向连接/协议问题：检查 zstd 压缩（Swift URLSession WebSocket 不支持 permessage-deflate，edge-tts 用 aiohttp compress=15）——但 7.1.33 的气泡喇叭有声说明当前协议路径本身能出音频，优先怀疑逐句时序/限流而非压缩。

## 八、交付物链接（历史）

- 7.1.33（TCC 权限版）：`https://aka.doubaocdn.com/s/VKL6d42UVX`（161,205,446B，md5 33cec1d89797901e85a20c0879a0598e）
- 7.1.31/7.1.30 历史包：`https://aka.doubaocdn.com/s/zAUlEKkDqV`、`https://aka.doubaocdn.com/s/t0Jw52QMIz`
- 最新构建产物始终在 GitHub Actions artifact（`TrollAgent` zip），或 Release `latest` tag 直链。

## 九、已知偏好/约束（用户）

- 英文回复须附中文翻译；"不要截图，直接读取文件内容"；持续监控 + 轮询编译失败就修。
- 语音角色：聊天界面可切音色（萝莉=小米+15Hz/猫娘=晓晓-8Hz御姐+句尾喵~/兔娘=小米+5Hz+呜~）；HUD 角色音色固定不随聊天切换。
- 用户 token 告急时，把进度写进本文件即可交接。
