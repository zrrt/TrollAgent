# TrollAgent — Project Goals & Roadmap (2026-10)

> This file is the project's single authoritative goal record. If context is compressed/lost, read this file first to recover direction.
> Last updated: 2026-10-23 (v6.6.0 — unified environment landed; CELF/elf-runner/iSH routing all retired)

## End Goal (one line)

**Converge the project from "iOS native + iSH/Alpine dual-track + routing translation" into "one iOS environment + Linux userspace runtime" — done: iSH retired (Asbestos took over), AI perceives a single environment.**

## Why (user-recorded motivation)

- "After auditing, many tool commands don't work / crash" — the dual-track routing + iSH emulator was the #1 crash source (cpu_run_to_interrupt, rootfs self-reference, numpy segfaults)
- "I don't trust any of these tools; it feels buggy and unstable, not one coherent whole"
- User explicitly asked: "pull a-Shell over and figure out how to abolish iSH and routing, go fully native"

## Confirmed Architecture Decisions (with evidence; don't overturn lightly)

| Decision | Evidence |
|---|---|
| **14c1: engine reverted to pure arm64** (done) | 14ca3ca dual-arch built libish into arm64e, A15 segfaulted on iSH x86 emulation; 6.0.25 pure arm64 works |
| **14c3: Alpine trimming** (done) | commands covered natively were removed from Alpine (idempotent); kept rm/mv/cp/mkdir/chmod/ln/sh/sed/awk/grep/find/head/tail (apk script deps) |
| **Default: drop iSH, keep only if a tool genuinely needs kernel semantics** (user decision) | real Linux kernel semantics are used by AI/user <1% of the time; removing iSH = crash root fix + ~15MB smaller |
| **ELF: not "format conversion", but "runtime translation"** | ELF→Mach-O conversion is infeasible (dyld/libc/syscall don't map); correct approach = ELF loader + direct instruction execution + syscall translation layer (WSL1/elfuse architecture) |
| **"Install tools" new entry points**: pip install-on-demand / download arm64 binaries / CI recompile into the package; apk optional | apk installs Linux ELF, can't run natively; with source, recompile (99% of tools); without source, use the ELF runtime |
| **Env vars: not "installed" but "unified"** | the old dual-track (Alpine PATH / native process env) was inconsistent; after unification PATH(bin/)/HOME/TMPDIR are uniform, AI-agnostic |

## Layered Vision (final state)

```
Unified environment (AI sees one entry point = TrollRuntime)
 └─ Asbestos ARM64 interpreter + full Alpine rootfs (apk installs anything — python3/git/sqlite/jq/binutils/lua/node/radare2…)
      ├─ all commands run in the unified env (ls/cat/git/python3/ps/df…)
      ├─ iOS-specific tools (plutil/sqlite3) always available as Swift-native implementations
      └─ iOS injection toolchain (ldid/optool/insert_dylib/ct_bypass) runs natively
(since v6.6.0: no routing, no dual environment, no iSH/QEMU fallback — one environment)
```

## Roadmap Status

| Phase | Content | Status |
|---|---|---|
| P0 | 14c1 engine reverted to pure arm64, Alpine restored | ✅ delivered & installed (Alpine sh verified) |
| P1 | ~~native tool expansion~~ **merged into the unified env** (v6.6.0: Alpine apk toolchain replaces all native-chip tools — lua/node/r2/cstool/llvm family cleared) | ✅ merged in v6.6.0 |
| P3 | ~~native pip~~ **unified-env Alpine python3+pip complete** (apk installs anything) | ✅ v6.6.0 |
| P4 | routing abolished + unified env layer | ✅ v6.6.0 (runtime param removed, ISHEngine→TrollRuntimeEngine, iSH copy cleared) |
| P5 | aarch64 ELF runtime → **taken over by rcarmo/ios-linuxkit Asbestos (core switch v6.5.0, unified env v6.6.0)** — emu.c/CELF retired | ✅ v6.5.0–v6.6.0 (device-verified: apk installs/dynamic lib chains/git/ps/df/numpy all pass) |
| ~~P2~~ | ~~native restricted shell (composed commands)~~ **merged into P5** | user decision 2026-10-17: composed commands' final form = P5 ELF runtime (Linux shell semantics for free); self-written Swift shell unnecessary; fork verified to hang on native iOS (python3 subprocess NO JSON) |

**Key decision (2026-10-17→10-23)**: the busybox static-ELF route (emu.c/CELF) **retired (v6.6.0)** — replaced by rcarmo Asbestos (ARM64 kernel of iSH; JIT enabled v7.0.3+, ptrace self-enabled v7.0.4+): full Alpine rootfs + apk ecosystem + full dynamic ELF support, device-verified.

## Current State (2026-10-23, v6.6.0 pushed)

- **v6.6.0 series pushed (fix1-9)**: CELF/elf-runner/static busybox/iSH routing all retired; unified environment landed (shell.exec has no runtime param — all commands default to TrollRuntime = Asbestos + full Alpine toolchain; iOS-specific commands auto-handled natively); rootfs completed; native-chip tools cleared (lua/node/r2/cstool/llvm family — Alpine replaces them) + CI 25-45min faster
- **Next**: v6.6.0 device verification (overwrite install) → broad regression → vendored (Asbestos source into the repo) + CISH target rename wrap-up
- Recorded fact: python3 subprocess/os.system hangs on native iOS (fork restriction re-confirmed) → composed commands merged into P5, no self-written Swift shell

## Repo & Release Info

- Repo: zrrt/TrollAgent (main); GitHub token lives in session memory / env vars (never write it into this file — Push Protection blocks it)
- Release: latest = TrollAgent.tipa (overwritten on every build)
- Device remote test: N1 SSH jump host → iPhone terminal :8790 (/health needs no auth; check build). The jump host's public IP is dynamic — ask the user for the current one; credentials are kept in session memory, not in the repo.
- a-Shell conclusion: main app source is not public; a-Shell-commands are WASM commands (not native iOS ARM binaries), usable only as a tool-list reference

---

## Archived Handoffs (details live in git history)

- **VPN/capture main line handoff (archived 2026-10-19)**: kfd-injection route abandoned (DMA panic → black screen); final decision = VpnTunnel starts the tunnel directly with its own entitlements. Full analysis and dead-end list are in git history / old versions of this file.
- **Historical debug records (archived)**: 2026-10-19/20 elf-runner offline debugging (CSEL/SDIV/RBIT/BFM/LDUR/stub syscall; UBFM root cause; SXTW/SXTX shifts; stack layout v4; device UNSUPPORTED madd…) — all archived with emu.c retirement, see git log (v6.6.0 removal commit 16000fa).
