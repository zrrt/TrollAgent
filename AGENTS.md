# AGENTS.md — TrollAgent AI Agent Entry

> You are the AI agent running on TrollAgent (iOS reverse-engineering / automation MCP toolkit). **Read this file fully before starting any task**, then follow the routing contract in RULES.md.

## What This Is

TrollAgent is a native MCP service deployed on iOS devices. Through its toolchain it lets AI operate the real iOS system directly: app management, dylib injection, network capture, SQLite forensics, cross-environment file access, memory modification, package dissection, device/location info, and more. All shell commands run in the **unified environment TrollRuntime** (Alpine Linux rootfs + Asbestos translator; iSH is retired) — there is a single environment, no environment routing.

## First Principle: Route First, Then Act

When you get a user task, **don't randomly try tools**. Follow this order:

1. **Read RULES.md** for the operating contract (MUST/SHOULD semantics).
2. **Route**: use `skills.list` to search for a matching skill (query with task keywords like `inject`/`capture`/`shell`/`memory`). On a hit, `skills.read` the full instructions and **follow them**.
3. **No hit**: compose tools from each tool's summary documentation; for complex multi-step flows prefer existing skill methodologies.
4. When executing, call the tool name directly (e.g. `app`, `inject`, `network.capture`) and produce structured results with evidence.

> Note: call tool names directly — **never add a `ta` prefix** (there is no `ta` alias; adding it errors with unknownTool). Pass subcommands via the `command:` param, e.g. `app command:launch bundle_id:com.xxx`; `app launch ...` in docs is just natural-language shorthand.

## Core Tool Quick Reference

| Tool | Purpose | Typical usage |
|---|---|---|
| `app` | App management/launch/install/diagnose/decrypt/repack | `app command:status bundle_id:...` |
| `inject` | dylib injection & reverse engineering | `inject command:status` / `command:enable` |
| `network.capture` | HTTP/HTTPS capture | `network.capture command:start` |
| `vpn.capture` | System-level MITM tunnel (**WIP, under development**; degrades to local proxy when limited) | `vpn.capture command:status` |
| `memory` | In-process memory modification (H5GG-like) | `memory ...` |
| `device` / `location` | Device info / location | `device command:info` |
| `shell.exec` | Shell in the unified environment (Alpine toolchain) | `shell.exec ...` |
| `knowledge` | Knowledge-base search/import | `knowledge command:search ...` |
| `web.search` / `web.fetch` | Web search / page fetch | `web.search ...` |
| `skills.list` / `skills.read` | Skill discovery & reading | `skills.list query:...` |
| `tool.install` | Install tools/dependencies (python3, DB, etc.; install first when a tool is missing) | `tool.install ...` |

## Environment & Bridging (Key Constraints)

- **Unified environment only**: every command runs in TrollRuntime (Alpine Linux aarch64). Full shell composition is supported (pipes, `&&`, `;`, loops, redirection). Missing tools must be installed explicitly with `apk add` (no auto-install).
- **iOS paths**: only Workspace, Containers and System directories are auto-bridged; other paths need `cp` into the Workspace first, or use `bind_app` for app data containers (read-only).
- **Missing tools**: search and install in the unified environment yourself (`tool.install` / `apk add`); native iOS binaries (py3-native / node-native) are available once the Python/Node xcframeworks are compiled in.
- **File size**: the old 2MB bridge cap is lifted; large files read and write fine.
- Tool output may spill to `tool_spill` files — read them with absolute paths.

## Output Contract

- Lead with the conclusion, then evidence (command/path/bytes/hash/table structure).
- Use **absolute paths** for concrete files, never placeholders or relative paths.
- State clearly what you did, what the result is, and what the next step is based on.

## Positioning

TrollAgent is a **lightweight iOS operation toolkit**: AI routing + native tool execution + experience memory (assistant_memory / knowledge base). When you hit an unfamiliar reverse/capture/injection flow, check the skill library first; if a skill is missing, suggest adding one — don't force a task into a mismatched tool.
