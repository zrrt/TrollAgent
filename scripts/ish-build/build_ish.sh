#!/bin/bash
set -e

# ============================================================================
# iSH-ARM64 Build Script for iOS Static Library
# ============================================================================
# This script builds libish, libish_emu, and libfakefs as static libraries
# for iOS (arm64) integration, using the ish-arm64 fork which emulates an
# ARM64 Linux guest on iOS.
#
# Repository: https://github.com/rcarmo/ios-linuxkit（v6.5.0 起——Asbestos ARM64 内核，OpenMinis 已停更退役；v7.0.3 起 JIT 恢复 -Djit=true + jit-fallback.patch）
#
# Prerequisites:
#   - Xcode with iOS SDK
#   - Python 3 with meson (pip3 install meson)
#   - Ninja (brew install ninja)
#   - LLVM/Clang (brew install llvm) - required for VDSO compilation
#   - libarchive (brew install libarchive)
#
# Usage:
#   ./build_ish.sh [clean|debug|release]
#
# Output:
#   deps/libs/      - Static libraries (.a files)
#   deps/include/   - Header files
#   deps/resources/ - VDSO and other resources
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISH_DIR="$SCRIPT_DIR/ish"
OUTPUT_LIBS="$SCRIPT_DIR/libs"
OUTPUT_INCLUDE="$SCRIPT_DIR/include"
OUTPUT_RESOURCES="$SCRIPT_DIR/resources"

# Build configuration
BUILD_TYPE="${1:-release}"
# v6.1.4: 双架构（arm64 + arm64e）——arm64e 切片让 App 在 A12+ 设备原生运行，
# 修复 compat 模式下 MobileIcons/CoreImage 渲染分享扩展图标 SIGSEGV
#（TrollStore/TrollFools 均双架构原生运行，故分享正常）。
# v6.1.5(14c1): 回退纯 arm64——14ca3ca 双架构后 libish 编入 arm64e 切片，
# v6.5.0 起: guest 为 ARM64(Asbestos)——不再有 x86 模拟；历史: OpenMinis x86 时代 A15 段错误 cpu_run_to_interrupt
# （真机 10-17 实测 busybox/sh/file 全崩；崩溃时间线 10-16 前无 cpu_run_to_interrupt）。
# 纯 arm64 compat 模式 = 6.0.25 时代行为（Alpine 正常）。分享面板 SIGSEGV 留待后续单独处理。
ARCHS="arm64"
IOS_DEPLOYMENT_TARGET="14.0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
    exit 1
}

# ============================================================================
# Check Prerequisites
# ============================================================================
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check for Python 3
    if ! command -v python3 &> /dev/null; then
        log_error "Python 3 is required. Install with: brew install python3"
    fi

    # Check for meson
    if ! command -v meson &> /dev/null; then
        log_error "Meson is required. Install with: pip3 install meson"
    fi

    # Check for ninja
    if ! command -v ninja &> /dev/null; then
        log_error "Ninja is required. Install with: brew install ninja"
    fi

    # Check for Xcode
    if ! xcode-select -p &> /dev/null; then
        log_error "Xcode command line tools are required. Install with: xcode-select --install"
    fi

    # Check for LLVM (needed for VDSO)
    LLVM_CLANG=""
    for clang_path in "/opt/homebrew/opt/llvm/bin/clang" "/usr/local/opt/llvm/bin/clang" "/opt/local/bin/clang"; do
        if [ -x "$clang_path" ]; then
            LLVM_CLANG="$clang_path"
            break
        fi
    done

    if [ -z "$LLVM_CLANG" ]; then
        log_warning "LLVM Clang not found. VDSO may not build correctly."
        log_warning "Install with: brew install llvm"
    else
        log_info "Found LLVM Clang: $LLVM_CLANG"
    fi

    log_success "Prerequisites check passed"
}

# ============================================================================
# Initialize Submodules
# ============================================================================
init_submodules() {
    log_info "Initializing iSH submodules..."

    cd "$ISH_DIR"

    if [ ! -d "deps/libapps/.git" ] && [ ! -f "deps/libapps/.git" ]; then
        git submodule update --init --recursive --depth 1
        log_success "Submodules initialized"
    else
        log_info "Submodules already initialized"
    fi

    cd "$SCRIPT_DIR"
}

# ============================================================================
# Clean Build
# ============================================================================
clean_build() {
    log_info "Cleaning build artifacts..."

    rm -rf "$ISH_DIR/build-ios"
    rm -rf "$ISH_DIR/build-ios-arm64e"
    rm -rf "$OUTPUT_LIBS"
    rm -rf "$OUTPUT_INCLUDE"
    rm -rf "$OUTPUT_RESOURCES"

    log_success "Clean completed"
}

# ============================================================================
# Setup Cross Compilation
# ============================================================================
setup_cross_compile() {
    local arch="$1"
    local build_dir="$2"
    log_info "Setting up iOS cross-compilation ($arch)..."

    mkdir -p "$build_dir"

    # Get iOS SDK path
    IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)

    # Create cross-compilation file for meson
    CROSS_FILE="$build_dir/ios-cross.txt"

    cat > "$CROSS_FILE" << EOF
[binaries]
c = ['clang', '-arch', '$arch', '-isysroot', '$IOS_SDK', '-miphoneos-version-min=$IOS_DEPLOYMENT_TARGET']
ar = 'ar'
strip = 'strip'
pkg-config = 'false'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = []
c_link_args = ['-L$IOS_SDK/usr/lib']

[properties]
needs_exe_wrapper = true
sys_root = '$IOS_SDK'
library_dirs = ['$IOS_SDK/usr/lib']
EOF

    log_success "Cross-compilation file created"
}

# ============================================================================
# Build iSH Libraries
# ============================================================================
build_ish() {
    log_info "Building iSH libraries for iOS ($BUILD_TYPE)..."

    cd "$ISH_DIR"

    # v3.7.2: patch iSH 内核 —— meta.db 缺失/空时 boot rc=-22 (fake_db_init 用
    # SQLITE_OPEN_READWRITE 无 CREATE，且空库缺初始 schema 会让 fakefs_migrate 失败)。
    # 这里: 1) 加 CREATE 标志；2) 在 busy_timeout 后注入"paths 表不存在则建初始三表"。
    if grep -q 'SQLITE_OPEN_READWRITE' fs/fake-db.c; then
        # macOS BSD sed 的 -i 需带后缀，直接改用 python 做替换（跨平台、稳妥）
        python3 - "$ISH_DIR" <<'PATCH_PY'
import sys, os
ish_dir = sys.argv[1]
p = os.path.join(ish_dir, "fs/fake-db.c")
s = open(p).read()
old = "sqlite3_open_v2(db_path, &fs->db, SQLITE_OPEN_READWRITE, NULL);"
new = "sqlite3_open_v2(db_path, &fs->db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);"
assert old in s, "open-line not found in fake-db.c"
s = s.replace(old, new, 1)
open(p, "w").write(s)
print("PATCHED fake-db.c: SQLITE_OPEN_CREATE added")
PATCH_PY
        python3 - "$ISH_DIR" <<'SCHEMA_PY'
import sys, os
ish_dir = sys.argv[1]
p = os.path.join(ish_dir, "fs/fake-db.c")
s = open(p).read()
anchor = "    sqlite3_busy_timeout(fs->db, 5000);"
assert anchor in s, "anchor not found in fake-db.c"
init = anchor + """
    // v3.7.2: ensure initial schema exists when meta.db was missing/empty
    { sqlite3_stmt *t = NULL;
      sqlite3_prepare_v2(fs->db, "select name from sqlite_master where type='table' and name='paths'", -1, &t, 0);
      int has = (t && sqlite3_step(t) == SQLITE_ROW); if (t) sqlite3_finalize(t);
      if (!has) {
        char *init = "create table paths (path blob primary key, inode integer);"
                     "create table stats (inode integer primary key, stat blob);"
                     "create table meta (key text primary key, value text);"
                     "insert into meta (key, value) values ('db_inode', '0');";
        char *er = 0;
        if (sqlite3_exec(fs->db, init, 0, 0, &er) != SQLITE_OK) {
          printk("fake_db_init schema init failed: %s\\n", er ? er : "?"); sqlite3_free(er); }
        else printk("fake_db_init: created empty schema (meta.db was missing/empty)\\n");
      } }"""
s = s.replace(anchor, init, 1)
open(p, "w").write(s)
print("PATCHED fake-db.c: CREATE + schema-init injected")
SCHEMA_PY
    else
        log_warning "fake-db.c 未找到 SQLITE_OPEN_READWRITE，跳过 schema-init patch"
    fi

    # v4.0.2: patch iSH 内核 —— fakefs_bind_mount 写 meta.db 污染权限 → 后续 exec
    # 读到无执行位 rc=-13 (EACCES)。源码根因：bind 挂载点解析走 bind mount 表
    # (resolve/translate_path)，不依赖 meta.db inode mode；两段 meta.db 写入是冗余且
    # 有害的（把挂载点 inode 强制覆盖成 0755/0644，破坏原路径权限记录）。
    # 这里删除 fake.c 里这两段（update 分支 + create 分支），只保留 symlink + bind 表。
    if [ -f fs/fake.c ]; then
        python3 - "$ISH_DIR" <<'BIND_PATCH_PY'
import sys, os
ish_dir = sys.argv[1]
p = os.path.join(ish_dir, "fs/fake.c")
s = open(p).read()
orig = s
# 第1段：update 分支里的 meta.db 写入块
p1_start = "            /* Always refresh the meta.db mode — the read-only flag may have"
p1_end = "                db_commit(fs);\n            }\n"
i1 = s.find(p1_start); i2 = s.find(p1_end, i1)
if i1 != -1 and i2 != -1:
    s = s[:i1] + s[i2+len(p1_end):]
# 第2段：create 分支里的 meta.db 写入块
p2_start = "            /* Ensure the mount point exists in meta.db (dir or file), with the"
p2_end = "            db_commit(fs);\n"
i3 = s.find(p2_start); i4 = s.find(p2_end, i3)
if i3 != -1 and i4 != -1:
    s = s[:i3] + s[i4+len(p2_end):]
# 清理因此未使用的变量定义 (dir_mode/file_mode/top_mode)
var_block = """    uint32_t dir_mode = read_only ? 0555 : 0755;
    uint32_t file_mode = read_only ? 0444 : 0644;
    uint32_t top_mode = is_file_mount ? (S_IFREG | file_mode) : (S_IFDIR | dir_mode);

"""
if var_block in s:
    s = s.replace(var_block, "", 1)
if s != orig:
    open(p, "w").write(s)
    print("PATCHED fs/fake.c: removed meta.db writes from fakefs_bind_mount (rc=-13 fix)")
else:
    print("fake.c bind patch: no change (pattern not matched, skip)")
BIND_PATCH_PY
    else
        log_warning "fs/fake.c 未找到，跳过 bind 污染 patch"
    fi

    # v4.0.6: patch iSH 内核 —— 访问时刻守卫(隐藏自身 rootfs)。真根因：绑 /var/mobile 时，
    # 符号链接 data/ios_mobile 建在 root_fd(Documents/alpine-rootfs/data) 里，而 /var/mobile
    # 又包含 root_fd → 自引用成环。Alpine 经 /ios_mobile/.../alpine-rootfs/data 绕回自身底层存储，
    # fakefs 对自己 meta.db/inode 建记录 → 写坏 → 后续 exec rc=-13。
    # 守卫：fakefs_open 对落在 root_fd 的绑定路径返回 _ELOOP(隐藏)，bind_mount_ensure_inode
    # 跳过建 inode(不污染)。Alpine 的 /(root_fd) 正常访问、apk 装工具均不受影响。
    if [ -f fs/fake.c ]; then
        python3 - "$ISH_DIR" <<'GUARD_PATCH_PY'
import sys, os
ish_dir = sys.argv[1]
p = os.path.join(ish_dir, "fs/fake.c")
s = open(p).read()
orig = s

# 1) 在 bind_mount_ensure_inode 前插入守卫 helper
helper_anchor = """/* Auto-create a meta.db entry for a path under a bind mount.
 * Probes the host filesystem to determine if it's a file or directory. */
static inode_t bind_mount_ensure_inode(struct fakefs_db *fs, struct mount *mount,
"""
helper = """/* v4.0.6 guard: hide the fakefs's own backing store (the whole Documents/alpine-rootfs
 * directory, which contains both data/ and meta.db) from bind-mounted views. The app rootfs
 * lives under /var/mobile, so binding /var/mobile makes /ios_mobile/.../alpine-rootfs re-enter
 * the fakefs backing store -> self-referential cycle -> corrupts its own meta.db/inodes ->
 * later exec rc=-13 (and cpu_run_to_interrupt segfault). Refuse ONLY this region through binds;
 * normal rootfs access (Alpine /), other app containers, and the Workspace are unaffected. */
static bool bind_mount_target_is_backing_store(const char *host_abs) {
    if (g_fakefs_mount == NULL || g_fakefs_mount->source == NULL)
        return false;
    /* backing store = parent of source (.../alpine-rootfs), holds data/ + meta.db.
     * v4.0.9: called on EVERY fakefs_open (entry guard) -> MUST be stack-light;
     * PATH_MAX temporaries overflow the iSH kernel stack on deep opens. */
    const char *r = g_fakefs_mount->source;
    size_t rlen = strlen(r);
    if (rlen >= 5 && strcmp(r + rlen - 5, "/data") == 0)
        rlen -= 5;
    const char *h = host_abs;
    if (strncmp(h, "/private/", 9) == 0) h += 8;
    if (strncmp(r, "/private/", 9) == 0) { r += 8; rlen -= 8; }
    return strncmp(h, r, rlen) == 0 && (h[rlen] == '/' || h[rlen] == '\0');
}

"""
if helper_anchor in s and "bind_mount_target_is_backing_store" not in s:
    s = s.replace(helper_anchor, helper + helper_anchor, 1)

# 2) bind_mount_ensure_inode：翻译出的 host 落在 root_fd → 跳过建 inode
g1_old = """    if (bind_mount_translate_path(path, host_abs, sizeof(host_abs))) {
        if (stat(host_abs, &host_stat) < 0)
            return 0;"""
g1_new = """    if (bind_mount_translate_path(path, host_abs, sizeof(host_abs))) {
        if (bind_mount_target_is_backing_store(host_abs))
            return 0; /* v4.0.6: don't create meta.db inode for own rootfs via bind */
        if (stat(host_abs, &host_stat) < 0)
            return 0;"""
if g1_old in s:
    s = s.replace(g1_old, g1_new, 1)

# 3) fakefs_open：绑定路径落 root_fd → 拒绝(隐藏)
g2_old = """    if (bind_mount_translate_path(path, host_abs, sizeof(host_abs))) {
        int real_flags = 0;"""
g2_new = """    if (bind_mount_translate_path(path, host_abs, sizeof(host_abs))) {
        if (bind_mount_target_is_backing_store(host_abs))
            return ERR_PTR(_ELOOP); /* v4.0.6: hide own rootfs via bind */
        int real_flags = 0;"""
if g2_old in s:
    s = s.replace(g2_old, g2_new, 1)

# 2.5) v4.0.8: 入口守卫——/var/mobile 访问会先把 /ios_mobile 符号链接解析成宿主路径
#     (/var/mobile/...)，再走 fakefs_open 的 realfs 兜底分支，绕过 G2(仅 bind 翻译分支)。
#     故在 fakefs_open 入口对【原始路径 + 翻译后路径】都做 backing-store 检查，兜底也拦。
g0_helper = """/* v4.0.9: entry guard uses stack-light bind_mount_target_is_backing_store directly. */
"""
g0_anchor = """static inode_t bind_mount_ensure_inode(struct fakefs_db *fs, struct mount *mount,
"""
if g0_helper not in s and g0_anchor in s:
    s = s.replace(g0_anchor, g0_helper + g0_anchor, 1)

g0_open_old = """    if ((flags & (O_WRONLY_ | O_RDWR_ | O_CREAT_ | O_TRUNC_ | O_APPEND_)) &&
        is_under_readonly_bind_mount(path)) {
        return ERR_PTR(_EROFS);
    }
"""
g0_open_new = """    /* v4.0.9: hide own backing store from ANY bind view (incl. host-resolved paths).
     * Raw-path check only (stack-light): catches host-resolved /var/mobile/.../alpine-rootfs.
     * Linux bind paths (/ios_mobile/...) are caught below by G2 after translation. */
    if (bind_mount_target_is_backing_store(path))
        return ERR_PTR(_ELOOP);
    if ((flags & (O_WRONLY_ | O_RDWR_ | O_CREAT_ | O_TRUNC_ | O_APPEND_)) &&
        is_under_readonly_bind_mount(path)) {
        return ERR_PTR(_EROFS);
    }
"""
if g0_open_old in s:
    s = s.replace(g0_open_old, g0_open_new, 1)

# 4) fakefs_bind_mount_resolve_path(host→linux)：解析进 root_fd → 不映射(纵深防御)。
#    该函数位于 helper 定义之前，故需同时插入前向声明。
g3_old = """bool fakefs_bind_mount_resolve_path(const char *resolved, char *out_path, size_t out_size) {
    for (int i = 0; i < FAKEFS_MAX_BIND_MOUNTS; i++) {"""
g3_new = """static bool bind_mount_target_is_backing_store(const char *host_abs); /* v4.0.6 fwd decl */

bool fakefs_bind_mount_resolve_path(const char *resolved, char *out_path, size_t out_size) {
    if (bind_mount_target_is_backing_store(resolved))
        return false; /* v4.0.6: hide own rootfs via bind (reverse mapping) */
    for (int i = 0; i < FAKEFS_MAX_BIND_MOUNTS; i++) {"""
if g3_old in s:
    s = s.replace(g3_old, g3_new, 1)

if s != orig:
    open(p, "w").write(s)
    print("PATCHED fs/fake.c: access-time guard (hide own rootfs via bind) added")
else:
    print("fake.c guard patch: no change (pattern not matched, skip)")
GUARD_PATCH_PY
    else
        log_warning "fs/fake.c 未找到，跳过 bind 守卫 patch"
    fi

    # Configure meson build
    MESON_BUILDTYPE="release"
    # meson's `release` buildtype only implies -O3; it does NOT define NDEBUG
    # (that is a separate `b_ndebug` option). Without it every assert() in the
    # kernel stays live in a shipping build, so a failed assertion calls
    # abort() on a user's device instead of being a development-only check.
    # That is how the mem_ptr() CoW assert reached TestFlight as a SIGABRT in
    # sys_execve/args_copy. Keep asserts in debug builds, compile them out of
    # release ones.
    MESON_NDEBUG="true"
    if [ "$BUILD_TYPE" == "debug" ]; then
        MESON_BUILDTYPE="debug"
        MESON_NDEBUG="false"
    fi

    # v6.1.4: 每架构独立 build 目录 + meson 交叉配置（arm64→build-ios, arm64e→build-ios-arm64e）
    for arch in $ARCHS; do
        if [ "$arch" == "arm64" ]; then
            BUILD_DIR="$ISH_DIR/build-ios"
        else
            BUILD_DIR="$ISH_DIR/build-ios-$arch"
        fi
        CROSS_FILE="$BUILD_DIR/ios-cross.txt"
    # Configure meson build
    # Check if already configured
    if [ ! -f "$BUILD_DIR/build.ninja" ]; then
        log_info "Configuring meson build ($arch)..."

        meson setup "$BUILD_DIR" \
            --cross-file "$CROSS_FILE" \
            --buildtype="$MESON_BUILDTYPE" \
            -Db_ndebug="$MESON_NDEBUG" \
            -Dlog="" \
            -Dlog_handler=nslog \
            -Dkernel=ish \
            -Dengine=asbestos \
            -Dguest_arch=arm64 \
            -Djit=true \
            # v7.0.3: 恢复 JIT + jit-fallback 补丁（jit_on 运行时化——map_dual 失败时回退纯解释器，等价 -Djit=false；成功时真 JIT）
    else
        # Reconfigure both options: an existing build-ios/ from before
        # b_ndebug was introduced would otherwise keep asserts enabled.
        log_info "Meson already configured, reconfiguring ($arch)..."
        meson configure "$BUILD_DIR" \
            --buildtype="$MESON_BUILDTYPE" \
            -Db_ndebug="$MESON_NDEBUG"
    fi

    # Build libraries
    log_info "Building with ninja ($arch)..."
    ninja -C "$BUILD_DIR" libish.a libish_emu.a libfakefs.a

    # Also build VDSO (arm64 guest VDSO is at vdso/arm64/libvdso.so.elf)
    # 仅 arm64 一次构建（guest 产物与 host 架构无关）
    if [ "$arch" == "arm64" ]; then
        log_info "Building VDSO..."
        ninja -C "$BUILD_DIR" vdso/arm64/libvdso.so.elf || log_warning "VDSO build failed (may need LLVM)"
    fi
    done

    cd "$SCRIPT_DIR"
    log_success "iSH libraries built successfully"
}

# ============================================================================
# Copy Output Files
# ============================================================================
copy_outputs() {
    log_info "Copying output files..."

    BUILD_DIR="$ISH_DIR/build-ios"

    # Create output directories
    mkdir -p "$OUTPUT_LIBS"
    mkdir -p "$OUTPUT_INCLUDE/ish"
    mkdir -p "$OUTPUT_INCLUDE/ish/emu"
    mkdir -p "$OUTPUT_INCLUDE/ish/kernel"
    mkdir -p "$OUTPUT_INCLUDE/ish/fs"
    mkdir -p "$OUTPUT_INCLUDE/ish/fs/proc"
    mkdir -p "$OUTPUT_INCLUDE/ish/util"
    mkdir -p "$OUTPUT_INCLUDE/ish/platform"
    mkdir -p "$OUTPUT_INCLUDE/ish/asbestos"
    mkdir -p "$OUTPUT_RESOURCES"

    # Copy static libraries
    log_info "Copying libraries (lipo arm64+arm64e)..."
    # v6.1.4: arm64e 切片存在则 lipo 合并为 fat，否则回退单架构
    for lib in libish libish_emu libfakefs; do
        ARM64_LIB="$ISH_DIR/build-ios/$lib.a"
        ARM64E_LIB="$ISH_DIR/build-ios-arm64e/$lib.a"
        if [ -f "$ARM64E_LIB" ]; then
            lipo -create "$ARM64_LIB" "$ARM64E_LIB" -output "$OUTPUT_LIBS/$lib.a"
            log_success "fat $lib.a (arm64+arm64e)"
        else
            cp "$ARM64_LIB" "$OUTPUT_LIBS/$lib.a"
            log_warning "$lib.a arm64e 缺失，回退 arm64 only"
        fi
    done

    # Copy VDSO if built (arm64 guest VDSO path)
    if [ -f "$BUILD_DIR/vdso/arm64/libvdso.so.elf" ]; then
        cp "$BUILD_DIR/vdso/arm64/libvdso.so.elf" "$OUTPUT_RESOURCES/"
        log_success "VDSO copied"
    elif [ -f "$BUILD_DIR/vdso/libvdso.so.elf" ]; then
        cp "$BUILD_DIR/vdso/libvdso.so.elf" "$OUTPUT_RESOURCES/"
        log_success "VDSO copied"
    fi

    # Copy header files
    log_info "Copying header files..."

    # Root headers
    cp "$ISH_DIR/debug.h" "$OUTPUT_INCLUDE/ish/"
    cp "$ISH_DIR/misc.h" "$OUTPUT_INCLUDE/ish/"
    cp "$ISH_DIR/xX_main_Xx.h" "$OUTPUT_INCLUDE/ish/"

    # EMU headers
    cp "$ISH_DIR"/emu/*.h "$OUTPUT_INCLUDE/ish/emu/"

    # Kernel headers
    cp "$ISH_DIR"/kernel/*.h "$OUTPUT_INCLUDE/ish/kernel/"

    # FS headers
    cp "$ISH_DIR"/fs/*.h "$OUTPUT_INCLUDE/ish/fs/"
    if [ -d "$ISH_DIR/fs/proc" ]; then
        cp "$ISH_DIR"/fs/proc/*.h "$OUTPUT_INCLUDE/ish/fs/proc/" 2>/dev/null || true
    fi

    # Util headers
    cp "$ISH_DIR"/util/*.h "$OUTPUT_INCLUDE/ish/util/" 2>/dev/null || true

    # Platform headers
    cp "$ISH_DIR"/platform/*.h "$OUTPUT_INCLUDE/ish/platform/"

    # Asbestos headers
    cp "$ISH_DIR"/asbestos/*.h "$OUTPUT_INCLUDE/ish/asbestos/"
    # ARM64 guest gadgets
    mkdir -p "$OUTPUT_INCLUDE/ish/asbestos/guest-arm64/gadgets-aarch64"
    cp "$ISH_DIR"/asbestos/guest-arm64/gadgets-aarch64/*.h "$OUTPUT_INCLUDE/ish/asbestos/guest-arm64/gadgets-aarch64/" 2>/dev/null || true
    cp "$ISH_DIR"/asbestos/gadgets-generic.h "$OUTPUT_INCLUDE/ish/asbestos/" 2>/dev/null || true

    # ARM64 emu headers
    mkdir -p "$OUTPUT_INCLUDE/ish/emu/arch/arm64"
    cp "$ISH_DIR"/emu/arch/arm64/*.h "$OUTPUT_INCLUDE/ish/emu/arch/arm64/" 2>/dev/null || true

    # ARM64 kernel arch headers
    mkdir -p "$OUTPUT_INCLUDE/ish/kernel/arch/arm64"
    cp "$ISH_DIR"/kernel/arch/arm64/*.h "$OUTPUT_INCLUDE/ish/kernel/arch/arm64/" 2>/dev/null || true

    # Copy generated headers if exist
    if [ -f "$BUILD_DIR/cpu-offsets.h" ]; then
        cp "$BUILD_DIR/cpu-offsets.h" "$OUTPUT_INCLUDE/ish/"
    fi

    # Deps config
    if [ -f "$ISH_DIR/deps/config.h" ]; then
        mkdir -p "$OUTPUT_INCLUDE/ish/deps"
        cp "$ISH_DIR/deps/config.h" "$OUTPUT_INCLUDE/ish/deps/"
    fi

    # Copy RootfsPatch bundle (rootfs overlay patches applied on boot)
    if [ -d "$ISH_DIR/app/RootfsPatch.bundle" ]; then
        cp -r "$ISH_DIR/app/RootfsPatch.bundle" "$OUTPUT_RESOURCES/"
        log_success "RootfsPatch.bundle copied"
    fi

    log_success "Output files copied"
}

# ============================================================================
# Create Umbrella Header
# ============================================================================
create_umbrella_header() {
    log_info "Creating umbrella header..."

    cat > "$OUTPUT_INCLUDE/ish/ish.h" << 'EOF'
/*
 * iSH-ARM64 - Linux shell for iOS (ARM64 guest emulation)
 * Umbrella header for static library integration
 *
 * https://github.com/rcarmo/ios-linuxkit
 */

#ifndef ISH_H
#define ISH_H

#include "misc.h"
#include "debug.h"

// Kernel
#include "kernel/init.h"
#include "kernel/task.h"
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "kernel/memory.h"
#include "kernel/signal.h"
#include "kernel/errno.h"

// File System
#include "fs/fd.h"
#include "fs/stat.h"
#include "fs/tty.h"
#include "fs/fake.h"
#include "fs/real.h"
#include "fs/poll.h"
#include "fs/dev.h"

// EMU
#include "emu/cpu.h"
#include "emu/tlb.h"
#include "emu/mmu.h"
#if defined(GUEST_X86)
#include "emu/float80.h"
#endif

// Platform
#include "platform/platform.h"

#endif /* ISH_H */
EOF

    log_success "Umbrella header created"
}

# ============================================================================
# Print Summary
# ============================================================================
print_summary() {
    echo ""
    echo "============================================================"
    echo -e "${GREEN}🎉 iSH-ARM64 Build Complete!${NC}"
    echo "============================================================"
    echo ""
    echo "Libraries:"
    ls -lh "$OUTPUT_LIBS"/*.a 2>/dev/null || echo "  (none)"
    echo ""
    echo "Headers:   $OUTPUT_INCLUDE/ish/"
    echo "Resources: $OUTPUT_RESOURCES/"
    echo ""
    echo "To integrate with Xcode:"
    echo "  1. Add libs/*.a to 'Link Binary With Libraries'"
    echo "  2. Add include/ to 'Header Search Paths'"
    echo "  3. Add resources/ to 'Copy Bundle Resources'"
    echo "  4. Link with: libsqlite3.tbd"
    echo ""
    echo "============================================================"
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo ""
    echo "============================================================"
    echo "  iSH-ARM64 Static Library Builder for iOS"
    echo "  Guest arch: arm64 (aarch64 Linux emulation)"
    echo "============================================================"
    echo ""

    if [ "$1" == "clean" ]; then
        clean_build
        exit 0
    fi

    # Check if ish directory exists
    if [ ! -d "$ISH_DIR" ]; then
        log_error "iSH directory not found at $ISH_DIR"
    fi

    check_prerequisites
    init_submodules
    # v6.1.4: 双架构交叉配置（arm64 + arm64e）
    for arch in $ARCHS; do
        if [ "$arch" == "arm64" ]; then
            setup_cross_compile "$arch" "$ISH_DIR/build-ios"
        else
            setup_cross_compile "$arch" "$ISH_DIR/build-ios-$arch"
        fi
    done
    build_ish
    copy_outputs
    create_umbrella_header
    print_summary
}

main "$@"
