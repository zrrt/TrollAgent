// CISH — TrollRuntime 统一环境 C 包装层（TrollAgent 专用，串行执行语义）
// v6.6.0: 核心切换 rcarmo/ios-linuxkit Asbestos（ARM64 内核）；
// v7.0.3 起 -Djit=true 恢复 JIT（+jit-fallback.patch 运行时回退纯解释器）；
// v7.0.4 起 ptrace(PT_ATTACHEXC) 自开 JIT 授权并保持 attach（免 TrollStore URL 闪切），troll_jit_probe() 实测授权。
//         参考其 App 集成（app/ISHKernel.m/ISHShellExecutor.m 同源设计，本文件独立重写）。
// 编译宏（由 meson/SPM 提供）：-DGUEST_ARM64=1 -DISH_INTERNAL

#include "wrapper.h"

#include <sys/mman.h>   // v7.0.4.3: troll_jit_probe() 的 mmap/munmap/MAP_JIT
#include "ish/kernel/init.h"
#include "ish/kernel/task.h"
#include "ish/kernel/calls.h"
#include "ish/kernel/fs.h"
#include "ish/kernel/signal.h"
#include "ish/kernel/memory.h"
#include "ish/kernel/errno.h"
#include "ish/util/sync.h"   // lock/unlock（pids_lock 配套）
#include "ish/fs/fd.h"
#include "ish/fs/stat.h"
#include "ish/fs/path.h"   // AT_PWD
#include "ish/fs/tty.h"
#include "ish/fs/fake.h"
#include "ish/fs/real.h"
#include "ish/fs/poll.h"
#include "ish/fs/dev.h"
#include "ish/fs/devices.h"
#include "ish/emu/cpu.h"
#include "ish/platform/platform.h"
#include "ish/misc.h"
#include "ish/debug.h"

#include <pthread.h>
#include <stdatomic.h>
#include <sys/stat.h>   // S_IFCHR/S_IFDIR/S_IFREG（host 宏，值与 Linux guest 一致）
#include <fcntl.h>      // O_RDONLY
#include <unistd.h>     // dup/open

// 退出通知钩子（iSH 全局）：guest 进程退出时被调
extern void (*exit_hook)(struct task *task, int code);

static atomic_int g_booted = 0;

// v7.0.4: ptrace 自开 JIT——TrollStore 的 JIT 开关本质是 ptrace(PT_ATTACHEXC) 让内核
// 放行可执行映射（持续进程生命周期）。App 内直接对主进程 attach，等同手动开 JIT 且免闪切。
// fix7.0.4.1: **不 detach**——实证 detach 后 JIT 授权失效：cpu_run_to_interrupt 执行 JIT 块
// 触发 SIGBUS(10)。TrollStore 手动开 JIT（v7.0.3 真机 29/29 全通）即保持 attach 状态。
// 注意：iOS ptrace 无权限时返回 EPERM——Swift 侧检测负值后 fallback apple-magnifier URL。
extern int ptrace(int request, pid_t pid, void *addr, int data);
int troll_self_enable_jit(void) {
#ifdef __APPLE__
    pid_t pid = getpid();
    int r = ptrace(16 /* PT_ATTACHEXC */, pid, 0, 0);  // 16 = PT_ATTACHEXC（Darwin）
    if (r != 0) return -1;
    usleep(100 * 1000);  // 100ms——TrollStore jit.m 同款等待 attach 生效
    // 关键：保持 attach（不 detach）——JIT 授权随 attach 会话持续到进程结束
    return 0;
#else
    return -1;
#endif
}

// v7.0.4.3: JIT 有效性探测——mmap(MAP_JIT) 实测内核是否已放行可执行内存。
// self-attach 可能返回 0 但内核未放行（Husk 文档：进程不能同步调试自己）。
// 探测准确反映真实授权：无授权时 MAP_JIT mmap 返回 EINVAL/EPERM → probe=0 → Swift 调 TrollStore URL。
// 探测成功（probe=1）→ 无需 URL，免每次启动闪切。
int troll_jit_probe(void) {
#ifdef __APPLE__
    void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (p == MAP_FAILED) return 0;
    ((volatile uint8_t *)p)[0] = 0xC3;  // 写一字节验证可写（JIT 授权下才允许）
    // 不调用 __builtin___clear_cache（macOS 交叉 iOS 无内建实现，且 probe 不执行代码，无需清指令缓存）
    munmap(p, 4096);
    return 1;
#else
    return 0;
#endif
}

// 通知管道写端（串行：一次只有一个在跑的命令会收到退出通知）
static pthread_mutex_t g_notify_mtx = PTHREAD_MUTEX_INITIALIZER;
static int g_notify_fd = -1;
static pid_t_ g_notify_pid = -1;

// 只通知 spawn 的主进程退出（防 guest 内子进程先退导致通知错序/提前 close）
static void cish_exit_hook(struct task *task, int code) {
    if (task == NULL) return;
    int32_t pid = (int32_t)task->pid;
    int32_t rc = (int32_t)code;
    pthread_mutex_lock(&g_notify_mtx);
    int fd = g_notify_fd;
    if (fd >= 0 && task->pid == g_notify_pid) {
        // 写 8 字节 (pid, code)。管道满等罕见；一次只写 8 字节不会阻塞
        ssize_t wr = write(fd, &pid, 4);
        if (wr == 4) {
            wr = write(fd, &rc, 4);
        }
        // 写完即关：Swift 侧读满 8 字节即完成，无需 EOF；不关会泄漏 fd
        close(fd);
        g_notify_fd = -1;
        g_notify_pid = -1;
    }
    pthread_mutex_unlock(&g_notify_mtx);
}

int cish_is_booted(void) {
    return atomic_load(&g_booted);
}

// bind mount 表锁（与 g_booted 无关，bind 可动态增删）
static pthread_mutex_t g_bind_mtx = PTHREAD_MUTEX_INITIALIZER;

int cish_bind_mount(const char *linux_path, const char *host_path, int read_only) {
    if (!atomic_load(&g_booted)) return -1000;
    if (linux_path == NULL || host_path == NULL) return -1002;
    pthread_mutex_lock(&g_bind_mtx);
    int rc = fakefs_bind_mount(linux_path, host_path, read_only != 0);
    pthread_mutex_unlock(&g_bind_mtx);
    return rc;
}

int cish_bind_unmount(const char *linux_path) {
    if (!atomic_load(&g_booted)) return -1000;
    if (linux_path == NULL) return -1002;
    pthread_mutex_lock(&g_bind_mtx);
    int rc = fakefs_bind_unmount(linux_path);
    pthread_mutex_unlock(&g_bind_mtx);
    return rc;
}

int cish_boot(const char *data_path) {
    if (atomic_load(&g_booted)) return 0;
    if (data_path == NULL) return -1001;

    int err = mount_root(&fakefs, (char *)data_path);
    if (err < 0) return err;

    err = become_first_process();
    if (err < 0) return err;
    current->thread = pthread_self();

    // 设备节点（OpenMinis ISHKernel 同款）
    generic_mkdirat(AT_PWD, "/dev", 0755);
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);
    generic_mknodat(AT_PWD, "/dev/tty1", S_IFCHR | 0666, dev_make(TTY_CONSOLE_MAJOR, 1));
    generic_mknodat(AT_PWD, "/dev/tty2", S_IFCHR | 0666, dev_make(TTY_CONSOLE_MAJOR, 2));
    generic_mknodat(AT_PWD, "/dev/tty", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR));
    generic_mknodat(AT_PWD, "/dev/console", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR));
    generic_mknodat(AT_PWD, "/dev/ptmx", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR));
    generic_mknodat(AT_PWD, "/dev/null", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_NULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/zero", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
    generic_mknodat(AT_PWD, "/dev/full", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_FULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/random", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_RANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/urandom", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));

    int e2 = do_mount(&procfs, "proc", "/proc", "", 0);
    (void)e2;

    // v3.7.1：bind mount 默认关闭（恢复纯 boot）。
    // 原因（OpenMinis 老引擎）：fakefs_bind_mount 在 boot 中途写 meta.db 会污染权限记录，
    // 导致后续 exec 读到无执行位（rc=-13 EACCES）。bind 能力保留在显式按需挂载。
    // v6.6.0-fix23 审计（rcarmo 新引擎 fs/fake.c——已修老坑）：
    //   - 挂载动作只写挂载点 top_mode（read_only?0555:0755），不再递归污染子树权限
    //   - 访问 bind 路径按需探测宿主 stat 建正确 inode（bind_mount_ensure_inode——目录 0755/文件 0644）
    //   - 只读强制用代码检查（is_under_readonly_bind_mount——root 绕过 DAC 也 EROFS）
    // 结论：新引擎 bind mount 可安全启用；v3.7.1 默认关闭的决策待真机最终确认后放开。
    // v3.7.2：iSH 内核 patch —— meta.db 缺失/空时 sqlite3_open_v2 加 CREATE 并注入初始
    // schema（paths/stats/meta），boot 不再 rc=-22，可自动重建干净 meta.db（无需手动恢复）。

    exit_hook = cish_exit_hook;
    atomic_store(&g_booted, 1);
    return 0;
}

long cish_spawn(const char *path, const char *argv_buf, const char *envp_buf,
                int argc, int stdin_fd, int out_fd, int err_fd, int notify_fd) {
    if (!atomic_load(&g_booted)) return -1000;
    if (path == NULL || argv_buf == NULL || argc <= 0) return -1002;

    struct task *saved_current = current;
    int err = become_new_init_child();
    if (err < 0) {
        current = saved_current;
        return err;
    }
    struct task *task = current;

    // stdio 管道接线（OpenMinis 同款：adhoc fd 包 host fd）
    if (stdin_fd >= 0) {
        struct fd *f = adhoc_fd_create(&realfs_fdops);
        if (f != NULL) {
            int real = dup(stdin_fd);
            if (real >= 0) { f->real_fd = real; task->files->files[0] = f; }
        }
    } else {
        struct fd *f = adhoc_fd_create(&realfs_fdops);
        if (f != NULL) {
            int real = open("/dev/null", O_RDONLY);
            if (real >= 0) { f->real_fd = real; task->files->files[0] = f; }
        }
    }
    if (out_fd >= 0) {
        struct fd *f = adhoc_fd_create(&realfs_fdops);
        if (f != NULL) {
            int real = dup(out_fd);
            if (real >= 0) { f->real_fd = real; task->files->files[1] = f; }
        }
    }
    if (err_fd >= 0) {
        struct fd *f = adhoc_fd_create(&realfs_fdops);
        if (f != NULL) {
            int real = dup(err_fd);
            if (real >= 0) { f->real_fd = real; task->files->files[2] = f; }
        }
    }

    // 注册通知管道（串行）：dup 保持写端存活（Swift 会关闭原 fd）；主进程 pid 稍后记录
    pthread_mutex_lock(&g_notify_mtx);
    if (notify_fd >= 0) {
        g_notify_fd = dup(notify_fd);
    }
    pthread_mutex_unlock(&g_notify_mtx);

    const char *env = envp_buf != NULL ? envp_buf : "";
    err = do_execve(path, argc, (char *)argv_buf, (char *)env);
    if (err < 0) {
        pthread_mutex_lock(&g_notify_mtx);
        if (g_notify_fd >= 0) { close(g_notify_fd); g_notify_fd = -1; }
        pthread_mutex_unlock(&g_notify_mtx);
        current = saved_current;
        return err;
    }

    pthread_mutex_lock(&g_notify_mtx);
    g_notify_pid = task->pid;
    pthread_mutex_unlock(&g_notify_mtx);

    long pid = (long)task->pid;
    task_start(task);
    current = saved_current;
    return pid;
}

int cish_kill(long pid, int sig) {
    if (pid <= 1) return -1;
    struct siginfo_ info = SIGINFO_NIL;
    lock(&pids_lock);
    struct task *t = pid_get_task((dword_t)pid);
    if (t != NULL) {
        send_signal(t, (dword_t)sig, info);
    }
    unlock(&pids_lock);
    return t != NULL ? 0 : -1;
}

// OpenMinis 同款：t->parent 链上溯找 rootPid（busybox ash 有时 setpgid 起新组，
// 仅 pgid 匹配会漏杀 sleep 等孙进程）
static int task_is_descendant_of(struct task *t, pid_t_ root_pid) {
    int hops = 0;
    while (t != NULL && hops < MAX_PID) {
        if (t->pid == root_pid) return 1;
        t = t->parent;
        hops++;
    }
    return 0;
}

/// 清掉命令进程组：匹配 pgid 或根 pid 的后代，统一发 sig。
/// pid<=1 拒绝（pid 1 是 init，扫根于 init 会误杀整个内核）。
/// 调用方（Swift）先 SIGTERM 再 SIGKILL（OpenMinis 语义）。
int cish_killpg(long pid, int sig) {
    if (pid <= 1) return -1;
    struct siginfo_ info = SIGINFO_NIL;
    lock(&pids_lock);
    struct task *rootTask = pid_get_task((dword_t)pid);
    pid_t_ pgid = 0;
    if (rootTask != NULL) {
        pgid = rootTask->group->pgid;
        for (int i = 2; i < MAX_PID; i++) {
            struct task *t = pid_get_task(i);
            if (t == NULL) continue;
            int byPgid = (pgid != 0 && t->group->pgid == pgid);
            int byAncestry = task_is_descendant_of(t, (pid_t_)pid);
            if (byPgid || byAncestry) {
                send_signal(t, (dword_t)sig, info);
            }
        }
    }
    unlock(&pids_lock);
    return rootTask != NULL ? 0 : -1;
}
