# TrollAgent

**AI-driven iOS experimentation & QA workbench for TrollStore** — Swift + SwiftUI + SwiftPM, runs on iOS 15+ under TrollStore, ships **37 native tools, 100+ subcommands**, all callable by AI through natural language.

> Zero-learning mode: just say it in plain words ("analyze how this app works", "is this plugin safe", "capture this app's traffic") — the AI picks the tools, installs dependencies, does the job, and gives you a one-line human answer.

---

## Table of Contents

- [Project Overview](#project-overview)
- [Quick Start](#quick-start)
- [Architecture](#architecture)
- [Technology Stack](#technology-stack)
- [Project Structure](#project-structure)
- [Module Details](#module-details)
- [Tool Registry (full list)](#tool-registry-full-list)
- [Technology Integration Roadmap](#technology-integration-roadmap)
- [Build & Release](#build--release)
- [Development Guide](#development-guide)
- [Related Docs](#related-docs)

---

## Project Overview

**TrollAgent** is an AI-driven workbench for the TrollStore ecosystem: it wraps iOS injection, app analysis, decryption, traffic capture, cross-app UI control, device spoofing and more into a set of **native tools callable by AI through natural language**, plus an always-on floating AI voice companion (HUD) over any app.

### Background & motivation

- The iOS reverse-engineering / TrollStore ecosystem historically demanded deep expertise: which tool, which flag, which signing identity, which container path. TrollAgent removes that barrier — the **AI drives every tool** through a unified chat interface.
- Previous generations of iOS automation stacks (iSH emulation, dual-track Alpine routing) were slow, crash-prone and duplicated. TrollAgent moved to a **single unified Linux userspace** (TrollRuntime) and is converging on fully native aarch64 execution (see [Roadmap](#technology-integration-roadmap)).

### Core capabilities

| Area | Description |
|---|---|
| Tool system | 37 native tools / 100+ subcommands, single registration hub, progressive disclosure |
| Unified execution env | Built-in TrollRuntime (unified Linux userspace); the AI can `apk add` any Linux tool and read iOS files directly |
| AI chat | Multiple upstream models (OpenAI-compatible / Anthropic Messages), SSE streaming, reasoning intensity control, skill system, tool batching |
| HUD companion | Separate-process floating window (loli / bunny-girl / cat-girl), full voice loop: STT → AI → Edge TTS, 200+ bilingual bubble lines |
| Remote ops | Gateway WebSocket pairing, SSH tunnel, built-in HTTP terminal, GitHub Actions build & artifact fetch |
| Security | Dangerous-command interception (dual-layer), TCC entitlements passthrough, crash auto-recovery |

### Design principles

- **Zero-learning mode**: natural language straight to results; the AI selects tools and installs dependencies by itself
- **Clean failure boundaries**: high-priority tools return unified `error_code / reason / next_step`, no misleading errors
- **Recoverability**: failed injections auto-rollback + launch self-check (auto-restore on crash)
- **Nativization direction**: progressively retiring iSH/Alpine emulation layers toward aarch64 Linux ELF running directly

---

## Quick Start

### Install

1. Build from CI (recommended): every push to `main` triggers GitHub Actions which produces `TrollAgent.tipa` (artifact name `TrollAgent`).
2. Or build locally on macOS: `bash scripts/build-ipa.sh`.
3. Open the `.tipa` in **TrollStore** → install → launch.

### First conversation

| You say | The AI does |
|---|---|
| "Analyze how this app works" | `app diagnose` → injection-residue / encryption / signature checks → explicit report |
| "Is this plugin safe?" | `inject ipa_inspect` / `dylib_inspect` → arch / signature / entitlements / dependencies analysis |
| "Capture this app's traffic" | `network.capture` start → injected NetworkTweak → TLSHook-decrypted request list |
| "What's in this app's data?" | `db list` / `db query` → native sqlite3 read of the app data container |
| "Spoof this app's device model" | `device fake` → in-memory FakeDevice.dylib spoofing (zero residue) |
| "Back it up before uninstalling" | `app duplicate` → silent duplicate via trollstorehelper |

> Model & API key: configured in Settings → Model. Multiple upstream providers supported. The HUD voice loop shares the same configuration via App Group.

---

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│                    UI layer (SwiftUI)                       │
│  ChatView · SettingsView · BrowserView · GatewayView ·      │
│  CleanupView · FakeDeviceView · ControlCenterView · ...     │
└──────────────────────────┬─────────────────────────────────┘
                           │
┌──────────────────────────▼─────────────────────────────────┐
│               AI chat kernel (OpenAIClient)                 │
│  Multi-upstream models · SSE streaming · reasoning control ·│
│  skill system · batched tool selection                      │
└──────────────────────────┬─────────────────────────────────┘
                           │ tool dispatch (ToolRegistry / MCPCore)
┌──────────────────────────▼─────────────────────────────────┐
│            Tool Registry (37 tools / 100+ subcommands)      │
│  inject · app · file · db · browser · control · device ·    │
│  web · network · vpn · github · tool.install · ...          │
└───┬──────────┬──────────┬───────────┬──────────────────────┘
    │          │          │           │
┌───▼───┐ ┌───▼───┐ ┌────▼────┐ ┌────▼────┐
│Injection││Decrypt ││ Browser ││ Control │
│engine   ││engine  ││WKWebView││Agent.dylib│
│(TrollFools)│(Decrypt)││+JS inject││         │
└───┬───┘ └───┬───┘ └────┬────┘ └────┬────┘
    │         │          │           │
┌───▼─────────▼──────────▼───────────▼───────────────────────┐
│            TrollRuntime (unified Linux userspace)           │
│  Asbestos interpreter · full Alpine toolchain · iOS file    │
│  auto-bind · aarch64 binaries via 3 channels (bundled /     │
│  CI cross-compiled / self-written dylib)                    │
└──────────────────────────┬─────────────────────────────────┘
                           │
┌──────────────────────────▼─────────────────────────────────┐
│              System base (TrollStore mechanics)             │
│  setuid root toolchain (ldid/optool/insert_dylib/ct_bypass) │
│  trollstorehelper silent install · JIT double-ensure · TCC  │
└────────────────────────────────────────────────────────────┘
```

### Layer responsibilities

| Layer | Components | Responsibility |
|---|---|---|
| UI (SwiftUI) | ChatView, SettingsView, BrowserView, GatewayView, CleanupView, FakeDeviceView, ControlCenterView, AppPickerView… | Full bilingual UI (Simplified Chinese / English) |
| AI kernel | OpenAIClient, Models.swift (chat loop), SystemPrompts, UsageRecorder | Multi-upstream chat, SSE streaming, tool selection & **batching**, usage/token accounting, skill system |
| Tool registry | MCPCore.swift | Single registration hub; default-enabled whitelist; progressive disclosure (`isCore`); per-tool enable state |
| Domain engines | InjectionExecTool, DecryptEngine, BrowserExecTool, ControlExecTool, AppExecTool, FileExecTool/DbExecTool… | Actual iOS operations |
| Runtime | ShellExecTool + TrollRuntimeEngine | Unified Linux userspace (Asbestos interpreter + Alpine toolchain), iOS file auto-bind |
| System base | Build scripts, ldid/optool/insert_dylib/ct_bypass, trollstorehelper | JIT double-ensure, TCC entitlements, setuid root toolchain |

### Key design decisions

- **Single registry**: every tool registered in one place (`MCPCore.swift`); default whitelist means new users are productive immediately.
- **Unified execution env**: iSH retired; all shell commands run in TrollRuntime (Asbestos interpreter, full Alpine rootfs + apk ecosystem). No dual-track routing since v6.6.0.
- **JIT double-ensure**: ptrace self-attach (silent) + unconditional TrollStore URL (`apple-magnifier://enable-jit`); waits 3s before the first shell command.
- **Native tool three channels**: bundled binaries / GitHub Actions cross-compilation / self-written dylibs (`inject load_dylib`).
- **TrollStore mechanics**: bundled setuid root toolchain; silent install via trollstorehelper; TCC entitlements passthrough (mic / speech recognition without prompts).
- **HUD separate process**: `ch.xxtou.hudapp` independent binary embedded as a sub-package; App Group shared config; voice loop runs fully on-device.
- **Tool batching (v7.1.99-103)**: read-only/query tools batch up to 4 (executed sequentially, results visible to subsequent calls); state-changing/write tools run one at a time — with dual-layer safety (classification whitelist + dangerous-command interception in ShellTool).
- **Progressive disclosure**: only core tools (shell.exec / control.screenshot) are always resident; the rest are revealed on demand to keep the model context lean.

---

## Technology Stack

| Dimension | Detail |
|---|---|
| Languages | Swift (main app / tools / AI kernel), Objective-C++ (HUD window), C (CHev/CISH/CLaunch/CMitm bridge components) |
| UI | SwiftUI (iOS 15+), full Simplified-Chinese / English bilingual switching (including HUD bubble lines) |
| Platform | iOS 15+ / TrollStore (jailbreak-friendly) |
| Dependency mgmt | SwiftPM |
| Runtime env | TrollRuntime unified Linux userspace (Asbestos interpreter + Alpine toolchain); roadmap target: aarch64 Linux ELF running directly |
| External integration | GitHub Actions (CI build & artifacts), Edge TTS (speech synthesis), multi-upstream LLMs (OpenAI-compatible / Anthropic Messages) |
| Process model | Main app + HUD independent sub-process (`NSPrincipalClass=HUDMainApplication`) |
| Injection system | TrollFools-aligned strategy (dylib inject/remove/backup-rollback with `.bak_macho`), in-memory injection (opainject), ControlAgent.dylib cross-app control |
| Network | WebSocket (gateway pairing, Edge TTS), URLSession (downloads with progress), local HTTP terminal `127.0.0.1:8790` |
| Storage | UserDefaults + App Group (`group.com.ai.iosxcode`), sqlite3 direct container reads, file workspace |

---

## Project Structure

```
TrollAgent/
├── Sources/TrollMCP2/            # Main project (136 Swift files)
│   ├── AppMain.swift             # Entry point
│   ├── MCPCore.swift            # Tool registry hub (single registration table, default whitelist)
│   ├── Models.swift             # AI chat kernel (tool selection / batching / execution loop)
│   ├── OpenAIClient.swift       # Multi-upstream model client (SSE / usage stats)
│   ├── ChatView.swift           # Chat UI (model picker sheet)
│   ├── SettingsView.swift       # Settings page
│   ├── BrowserManager.swift     # WKWebView + JS-injection browser
│   ├── DecryptEngine.swift      # App decryption engine (memory dump → repackaged ipa)
│   ├── ControlTools.swift       # Cross-app UI control (ControlAgent)
│   ├── CleanupTools.swift       # System cleanup
│   ├── GatewayClient.swift      # Gateway WebSocket pairing
│   ├── GitHubAccountStore.swift # GitHub Actions build / artifact fetch
│   ├── AppPickerView.swift      # App picker (search / category / index)
│   ├── GirlCompanion.swift      # Desktop companion character logic
│   ├── AppTools.swift           # app.* subcommands (launch/diagnose/install/decrypt...)
│   ├── FileDbTools.swift        # file/db container access
│   ├── BridgeTools.swift        # tool.install / env.setup_re / native chip bridging
│   ├── BuildTools.swift         # github.* CI tooling
│   ├── AdvancedTools.swift      # system.exec_root / download
│   └── ... (tools split by domain: ArchiveTools/CleanupTools/DiagnoseAndServer/...)
├── HUD/                         # Floating companion (Objective-C++)
│   ├── sources/HUDRootViewController.mm  # Voice loop / character animation
│   ├── HUD/Resources/           # Character assets (loli / bunny-girl / cat-girl:
│   │                           #  idle/blink/talk/sit/kneel/climb/jump/fall/side...
│   │                           #  incl. bunny-girl sitting pose rabit_chin_sit.png)
│   └── supports/entitlements.plist  # TCC + application-groups
├── CHev/ CISH/ CLaunch/ CMitm/  # C bridge components
├── scripts/                     # Build & QA scripts
│   ├── build-ipa.sh             # Local macOS build → TrollAgent.ipa
│   ├── build-hud.sh             # HUD sub-package build
│   ├── verify_ipa.py            # IPA structure verification
│   ├── check_tool_registration.py  # Registry consistency check
│   ├── check_braces.py / check_swift_braces.py / check_tweak_braces.py  # Syntax guards
│   ├── gen_icons.py             # Icon generation
│   ├── build-openssl.sh         # OpenSSL cross-build
│   ├── git.py / nscan.py / patch_keychain_wipe.py  # CI helpers
│   └── ish-build/               # (retired iSH build tree)
├── Resources/                   # Assets
├── Support/Info.plist           # Version (CFBundleShortVersionString)
├── benchmark/ build_out/        # Benchmarks / build output
└── *.md                         # Docs (README/GOALS/DEV_HANDOVER/FAQ...)
```

---

## Module Details

### 🧩 Injection & automation (TrollFools-aligned)
- `inject` (enable / disable / remove / restore / enable_persisted / status / inspect / list): dylib injection, removal, backup-restore with automatic `.bak_macho` rollback
- `inject verify`: post-injection health check (Mach-O load commands + process liveness + crash detection); `inject static`: Mach-O static analysis
- `inject mem`: in-memory injection (opainject, zero file residue); `hook_apply` / `probe_inspect`; `inject load_dylib`: load your own dylib
- `rescue` (scan / recover_all / cleanup): emergency recovery against "app won't open after injection"
- Failed injections auto-rollback + post-injection launch self-check (auto-restore on crash)

### 📱 App management
- `app` (launch / stop / restart / status / stats): process control (3-tier start fallback: `open -b` → direct exec → url scheme)
- `app diagnose`: auto root-cause for launch failures (injection residue / encryption / signature / crash scene → explicit `next_step`)
- `app install / uninstall / duplicate`: AI install / uninstall / duplicate (silent install via trollstorehelper first)
- `app encrypt_info / decrypt / replace_decrypted / restore_binary`: built-in decryption engine (`task_for_pid` + `vm_read` memory dump → rebuilt decrypted image → packaged ipa)
- `app entitlements / deps / cache_inspect / cache_clear / launch_options / inject_package`
- `inject ipa_inspect / dylib_inspect`: IPA/dylib parsing (arch / signature / entitlements / dependencies, telling "parse failed" apart from "genuinely absent")

### 🧹 System cleanup
- Storage ring card + 6 cache categories + quick/advanced cleanup tabs + one-tap cleanup (setuid root full-directory rebuild)

### 📂 Filesystem & data
- `artifact` (read / write / list): workspace file management
- `bind_app` / `bind_app_write` / `app_write_file`: read-only / backup-first writable container binding

### 🌐 Browser (WKWebView + JS injection, Playwright-style)
- `browser` (status / navigate / screenshot / snapshot / text / click / type / submit / scroll / wait / wait_for) + absolute XPath for elements
- `browser form_fields / fill_form`: full-form autofill (React/Vue-compatible value setter + events)
- `browser adblock / clear`: ad/tracker blocking (WKContentRuleList) + cache/Cookie clearing; `navigate` supports `fresh=true` to bypass cache

### 🎮 Device spoofing (GreenShield-style)
- `device fake / restore`: in-memory FakeDevice.dylib to spoof UIDevice model (zero residue, resets on reboot)
- `device advertising / idfv`: ad identifiers / IDFV; `inject keychain_wipe`: keychain cleaning

### 🛡️ Security detection
- `device info / probe / snapshot`: full checks for TrollStore / task_for_pid / container read-write / injection toolchain

### 🔌 Cross-app UI control
- `control` (inject / status / ui_tree / screenshot / tap / swipe / type / key / tap_text / type_text)
- Injects ControlAgent.dylib → localhost:4789 HTTP API (/status /ui_tree /tap /swipe /type)

### 🏗️ Build & engineering
- `tool.install`: unified tool install loop — one-click in the unified environment (apk→pip→CI; CI cross-compiles native iOS binaries best-effort)
- `env.setup_re`: one-click reverse-engineering toolchain (binutils/file/python3/sqlite/tcpdump/7z…)
- `github` (account_status / trigger_build / fetch_runs / download_artifact): trigger GitHub Actions, watch progress, grab artifacts — the CI builds and ships TrollAgent.tipa
- `project`: workspace project management
- `system.exec_root`: system-side Mach-O execution (jroot jailbreak tooling)

### 🤖 AI & models
- Multiple upstream models (OpenAI-compatible / Anthropic Messages), SSE streaming word-by-word output, reasoning intensity control
- Tool batching: read-only/query tools batch (up to 4, executed sequentially); state-changing/write tools run one at a time (double-layer safety)
- Skill system: `skills.list` / `skills.read` / `skills.set_enabled` (reusable standard workflows)
- Usage accounting: per-request token display (real `usage` preferred, estimated fallback)

### 📡 Gateway & automation
- Gateway WebSocket pairing, multi-node calls, `automation` (run / list / jobs / stop / status / history / set_enabled), `ssh` (exec / scp)
- **Remote terminal service**: built-in HTTP terminal on `127.0.0.1:8790` (/api/tools), reachable from a browser or via SSH tunnel

### 📊 Network & diagnostics
- `web.search` (multi-engine fallback Bing→DuckDuckGo→Baidu, parallel `queries`, source-graded `sort`, results into knowledge base via `save`)
- `web.fetch` (auto article extraction, article/main first + built-in browser fallback)
- `network.capture` (start / stop / requests / analyze): NSURLSession capture via injected NetworkTweak; TLSHook decrypts SSL_read/SSL_write
- `vpn.capture`: system-proxy capture — the reliable path is the local proxy (WiFi manual proxy `127.0.0.1:18180`)
- `diagnose` (startup / injection), crash log parsing
- `wifi_proxy`: WiFi proxy management

### 📚 Knowledge & system
- `knowledge` (import_text / import_file / search / delete / clear): knowledge base CRUD
- `memory` (search / modify / freeze), `assistant_memory` (cross-session memory)
- `location` (get / fake / status / clear), `reminder` (create / schedule / recurring)
- `memory_tweak`: in-memory tweak tooling

### 🐰 Desktop companion (HUD)
- Floating anime companion (loli / bunny-girl / cat-girl) on top of any app: idle frames, wall-climbing, bubble chat
- Full voice loop: STT → AI → Edge TTS; speech-animation reset, sitting/voice-hold pose assets (`<prefix>_chin_sit` fallback for bunny-girl)
- 200+ bilingual bubble lines (time greetings, weather, moods, interactions) that follow the app language setting
- Quick menu to launch WeChat / Douyin / AI chat / hide, resizable, draggable, multi-gesture interactions
- Character asset set: idle / blink / talk / sit / kneel / climb / jump / fall / side / heart / surprise / giggle… (~30 frames per character)

---

## Tool Registry (full list)

37 tools exposed to the AI (43 registered tool objects), all default-enabled for new users:

| Tool | Purpose | Key subcommands |
|---|---|---|
| `shell.exec` | Unified shell (TrollRuntime) | any Linux command; `apk add` installs |
| `app` | Process control & app analysis | launch / stop / restart / status / diagnose / install / uninstall / duplicate / decrypt / entitlements / deps |
| `inject` | dylib injection | enable / disable / remove / restore / mem / verify / static / load_dylib / hook_apply / ipa_inspect / dylib_inspect |
| `control` | Cross-app UI control | inject / ui_tree / screenshot / tap / swipe / type / key |
| `browser` | In-app browser | navigate / snapshot / text / click / type / submit / form_fields / fill_form / adblock / clear |
| `device` | Device info & spoofing | info / probe / snapshot / fake / restore / advertising / idfv |
| `bind_app` / `bind_app_write` | Container binding | read-only / backup-first writable |
| `app_write_file` | Direct file write | with pre-write backup |
| `artifact` | Workspace files | read / write / list |
| `network.capture` | Traffic capture | start / stop / requests / analyze |
| `vpn.capture` | System-proxy capture | start / stop / analyze |
| `wifi_proxy` | WiFi proxy | set / clear |
| `web.search` | Web search | multi-engine fallback, parallel queries |
| `web.fetch` | Page fetch | auto article extraction |
| `github` | CI builds | account_status / trigger_build / fetch_runs / download_artifact |
| `tool.install` | Unified tool install | apk→pip→CI loop |
| `env.setup_re` | RE toolchain setup | one-click |
| `system.exec_root` | Mach-O execution | jroot tooling |
| `ssh` | Remote shell | exec / scp |
| `automation` | Automations | run / list / jobs / stop / status / history / set_enabled |
| `project` | Project management | workspace ops |
| `diagnose` | Failure diagnosis | startup / injection |
| `rescue` | Injection recovery | scan / recover_all / cleanup |
| `memory` / `assistant_memory` | Memory | search / modify / freeze |
| `knowledge` | Knowledge base | import_text / import_file / search / delete / clear |
| `location` | Location | get / fake / status / clear |
| `reminder` | Reminders | create / schedule / recurring |
| `skills.*` | Skill system | list / read / set_enabled |
| `shell.stop` | Kill runaway shell | — |

---

## Technology Integration Roadmap

**Long-term goal** (see [GOALS.md](GOALS.md)): **full nativization** — abolish the iSH/Alpine dual-track routing, ultimately run aarch64 Linux ELF directly so the AI perceives a single environment.

| Phase | Status | Notes |
|---|---|---|
| P1 Unified userspace | ✅ done | TrollRuntime (Asbestos interpreter) took over; iSH emulation retired |
| P2 Dual-track routing convergence | ✅ done (v6.6.0) | Routing abolished + unified env layer landed: runtime param removed, ISHEngine → TrollRuntimeEngine, iSH copy cleared; CELF/elf-runner/static busybox retired |
| P3 Full nativization | 🎯 target | aarch64 Linux ELF running directly; the AI perceives a single environment (N1 gateway LAN tunneling for debugging) |
| Supporting | ongoing | Tool batching for throughput, HUD voice loop, versioned build & release (7.1.x auto-bump) |

### Historical timeline (unification, v6.5.0 → v6.6.0)

- **v6.5.0** — core switch to rcarmo/ios-linuxkit **Asbestos** (ARM64 interpreter branch of iSH, no JIT, iOS W^X compliant): full Alpine rootfs + apk ecosystem + full dynamic ELF support, device-verified.
- **v6.6.0 (fix1-9)** — unified environment landed: CELF / elf-runner / static busybox / iSH routing **all retired**; `shell.exec` has no runtime param — all commands default to TrollRuntime; iOS-specific commands auto-handled natively; rootfs completed; native-chip tools cleared (lua/node/r2/cstool/llvm family — Alpine replaces them); CI 25-45 min faster.
- **Key decision (2026-10-17→10-23)**: the busybox static-ELF route (emu.c/CELF) retired — composed commands' final form = P5 ELF runtime (Linux shell semantics for free); self-written Swift shell unnecessary; fork verified to hang on native iOS (python3 subprocess NO JSON).

### Recent milestones (7.1.x)

| Version | What landed |
|---|---|
| 7.1.88-90 | HUD voice-loop polish: wall-climb guard fix (speech no longer stuck), back-to-idle after playback (`audioPlayerDidFinishPlaying`), bunny-girl sitting pose asset fallback (`<prefix>_chin_sit`) |
| 7.1.91-92 | UI fixes: app icons fill rounded corners (`scaledToFill` + clipShape), device-spoofing target picker (full AppPickerView with search/category/A-Z index) |
| 7.1.93-97 | Performance & navigation: removed HUD diag log real-time reads, model-manager jump fixes (delayed push → in-sheet `NavigationLink`), saveAndTest → lightweight connectivity test, upstream-model fetch in the model picker, update-install now jumps to TrollStore (main-thread fix) |
| 7.1.98 | Usage-stats token display: real `usage` captured in `OpenAIClient`, per-request "≈N tok" rendering |
| 7.1.99-103 | Tool batching for throughput: read-only batch ≤4, interpreter batching with script blacklist, audit fixes for env/curl/kill/sed — double-layer safety (classification + dangerous-command interception) |

---

## Build & Release

### Local build (macOS)

```bash
bash scripts/build-ipa.sh          # → TrollAgent.ipa (installable via TrollStore)
bash scripts/build-hud.sh          # → HUD sub-package
```

### CI release flow

- Every push to `main` triggers **GitHub Actions**.
- The workflow bumps `CFBundleShortVersionString` (+1, commit `[skip ci]`), so **the artifact version is always the submitted version + 1**.
- CI accepts `RELEASE_VERSION` to auto-inject the release version (fixes version drift).
- Artifacts: `TrollAgent` zip containing `TrollAgent.tipa` (~161 MB). The `latest` release tag is overwritten on every build.
- QA guards run in CI: `verify_ipa.py` (IPA structure), `check_tool_registration.py` (registry consistency), brace checks.

### Versioning convention

- `Support/Info.plist` → `CFBundleShortVersionString`; bump per feature batch.
- Commit convention: `7.1.x: <what landed>`. Docs-only changes carry their own message.

---

## Development Guide

### Getting started

1. Open the repo in Xcode (SwiftPM layout under `Sources/TrollMCP2/`).
2. Signing: TrollStore signing handled by build scripts (`ldid -S` with `Support/TrollAgent.entitlements`); no developer account needed.
3. HUD is a separate target (`HUD/`, Objective-C++, `NSPrincipalClass=HUDMainApplication`).

### Code conventions

- Tools are registered once in `MCPCore.swift`; new tools must also land in the default whitelist if meant to be available out of the box.
- High-priority tools return unified `error_code / reason / next_step`; never return a misleading success.
- Keep the unified environment in mind: shell commands run in TrollRuntime (Alpine), not on iOS natively — iOS-specific needs go through dedicated tools.
- `check_tool_registration.py` / brace checks must pass before push.

### Common pitfalls

- Version drift: always let the workflow bump, or pass `RELEASE_VERSION` explicitly.
- HUD config is per-process: read/write model config via App Group `group.com.ai.iosxcode`, not plain UserDefaults.
- `.waitingForConnectivity` (not `.waiting`) is the correct `URLSession` readiness value.

---

## Related Docs

- [GOALS.md](GOALS.md) — long-term goals and architecture evolution (unification decisions, roadmap status)
- [FAQ.md](FAQ.md) — JIT, unified environment, known issues
- [DEV_HANDOVER.md](DEV_HANDOVER.md) — dev handover doc (blockers/fixes/next steps)
- [AGENTS.md](AGENTS.md) / [RULES.md](RULES.md) — AI collaboration conventions
- [HUD_PROGRESS.md](HUD_PROGRESS.md) — HUD development progress
- [VPN_DEVLOG.md](VPN_DEVLOG.md) — VPN capture dev log
- [CORUNA_INTEGRATION.md](CORUNA_INTEGRATION.md) — Coruna integration notes
