#!/bin/sh
# build_aot.sh — TrollAgent AOT 录制辅助（rcarmo 录制式 AOT，arm64 guest → arm64 host）
#
# 用法：
#   sh build_aot.sh record    构建 Darwin ARM64 录制器并对 musl/busybox 录制
#                            → recordings/aot_musl.S aot_busybox.S + manifest.json
#   sh build_aot.sh check     环境检查（bun/fakefs/内核）
#   sh build_aot.sh layout    打印观察版采集 aot-layout.json 的步骤（iOS 专用，需真机）
#
# 前置：
#   - Apple Silicon（GitHub macos-13 runner 是 arm64，可编 Darwin ARM64 录制器）
#   - bun（targeted.ts 编排）：curl -fsSL https://bun.sh/install | bash
#   - fakefs：先跑 prepare_alpine_rootfs.sh（产物 deps/resources/alpine-rootfs/，
#     必须与 App 内 rootfs 字节一致——录制镜像按 sha256 校验，不一致全被拒）
#
# 原理（rcarmo NATIVE_AOT_BUILD_PLAN.md）：
#   - 录制器 = ish CLI 可执行（-Djit=true -Djit_emit=true，jit_emit 默认 true）——
#     跑训练 workload 时用 ISH_JIT_RECORD 把 JIT 现场翻译记进 JSONL
#   - gen.py（targeted.ts 内部调用）→ 生成 .S 镜像（__TEXT,__ish_aot + constructor
#     调 _ish_aot_register）→ 链接进 App（App 内核 -Djit=true，ISH_JIT_NO_EMIT/执行开关控制）
#   - App 内核不用改：ish_aot_register 实现在 asbestos/guest-arm64/jit.c（-Djit=true 默认带上）
#
# 本脚本产出在 <repo>/scripts/ish-build/recordings/ 下，App 集成见文件尾部说明。

set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$SCRIPT_DIR")
ISH_DIR="$SCRIPT_DIR/ish"                       # build_ish.sh 的 clone 目标（CI: ish-stage/ish）
FAKEFS_DIR="$SCRIPT_DIR/resources/alpine-rootfs" # prepare_alpine_rootfs.sh 产物（与 App 内一致）
RECORD_DIR="$SCRIPT_DIR/recordings"
BUILD_DIR="$ISH_DIR/build-ios"                  # build_ish.sh 的 meson build 目录（App 静态库同源）

log()  { printf '\033[1;36m[build_aot]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[build_aot]\033[0m WARN: %s\n' "$*"; }
die()  { printf '\033[1;31m[build_aot]\033[0m ERROR: %s\n' "$*"; exit 1; }

check_env() {
    log "check: bun"
    command -v bun >/dev/null 2>&1 || warn "bun 未安装——record 需要（curl -fsSL https://bun.sh/install | bash）"
    log "check: fakefs ($FAKEFS_DIR)"
    [ -d "$FAKEFS_DIR" ] || warn "fakefs 缺失——先跑 prepare_alpine_rootfs.sh"
    log "check: 内核 clone ($ISH_DIR)"
    [ -d "$ISH_DIR" ] || warn "内核缺失——先跑 build_ish.sh（或 CI 的 clone 步骤）"
    log "check: meson build dir ($BUILD_DIR)"
    [ -f "$BUILD_DIR/build.ninja" ] || warn "meson 未配置——先跑 build_ish.sh"
}

# 构建录制器：在 build_ish.sh 的 build 目录里直接 ninja 出 CLI 可执行（同 meson 配置，
# jit_emit 默认 true = 录制器；App 静态库用 ISH_JIT_NO_EMIT/执行开关控制发射）。
build_recorder() {
    [ -f "$BUILD_DIR/build.ninja" ] || die "build-ios/build.ninja 不存在——先跑 build_ish.sh 生成 meson 配置"
    log "ninja ish（录制器 CLI 可执行，-Djit=true，jit_emit 默认 true）"
    ninja -C "$BUILD_DIR" ish
    [ -x "$BUILD_DIR/ish" ] || die "录制器构建失败：$BUILD_DIR/ish 不存在"
    log "录制器就绪: $BUILD_DIR/ish"
}

# 录制 musl + busybox（不录 python——rcarmo 实测 AOT 反而更慢 0.87x + 内存 3x）。
# targeted.ts 默认 4 模块；用定制的 targeted-tools.ts（同目录）只录 musl/busybox。
record() {
    check_env
    [ -d "$FAKEFS_DIR" ] || die "fakefs 缺失——先跑 prepare_alpine_rootfs.sh"
    command -v bun >/dev/null 2>&1 || die "bun 缺失——curl -fsSL https://bun.sh/install | bash"
    build_recorder

    rm -rf "$RECORD_DIR"
    mkdir -p "$RECORD_DIR"

    TS="$REPO_DIR/tools/jit_aot/targeted-tools.ts"
    [ -f "$TS" ] || TS="$REPO_DIR/tools/jit_aot/targeted.ts"   # 未定制时回落官方 4 模块版
    log "录制: bun $TS $BUILD_DIR/ish $FAKEFS_DIR $RECORD_DIR macho"
    bun "$TS" "$BUILD_DIR/ish" "$FAKEFS_DIR" "$RECORD_DIR" macho

    log "录制完成，产物："
    ls -lh "$RECORD_DIR"/aot_*.S 2>/dev/null || warn "未生成 aot_*.S（看 $RECORD_DIR 内日志）"
    [ -f "$RECORD_DIR/manifest.json" ] && log "manifest: $RECORD_DIR/manifest.json"
}

layout_hint() {
    cat <<'EOF'
iOS AOT 布局采集（观察版）：
  1. 先以 AOT_IMAGE_EXECUTION=0 构建观察版 App（内核编译宏 ISH_AOT_IMAGE_EXECUTION=0）
  2. 真机启动一次 → Documents/aot-layout.json（记录运行时 CPU/frame/block 布局）
  3. 采集该文件 → 录制器用同布局录制（ABI 必须与 App 内核一致）
  4. 再以 AOT_IMAGE_EXECUTION=1 + AOT_IMAGES_DIR=recordings 构建启用版
参考 rcarmo docs/NATIVE_AOT_IOS.md（已移植到仓库 docs/aot/）。
EOF
}

case "${1:-check}" in
    record) record ;;
    check)  check_env ;;
    layout) layout_hint ;;
    *) echo "用法: $0 {record|check|layout}" >&2; exit 2 ;;
esac

# === App 集成（后续步骤，录制验证通过后）===
# 1) 内核（build_ish.sh）：-Djit=true（已有）；App 侧控制发射用 ISH_JIT_NO_EMIT=1 宏。
# 2) 链接：aot_*.S 加进 CISH target sources；需保住 _ish_aot_register 符号：
#    OTHER_LDFLAGS: -Wl,-u,_ish_aot_register（SPM: .unsafeFlags(["-Xlinker","-u","-Xlinker","_ish_aot_register"])）
#    并 DEAD_CODE_STRIPPING=NO / -Wl,-force_load（照 rcarmo AppARM64AOTBootstrap.xcconfig）。
# 3) 运行时开关：AOT_IMAGE_EXECUTION=1 + ISH_AOT_IMAGE_EXECUTION=1（App 宏）启用镜像执行；
#    0 = 观察版（只采集布局不执行）。
