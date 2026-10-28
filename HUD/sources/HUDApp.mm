//
//  HUDApp.mm
//  TrollAgent
//
//  TrollSpeed 改造：单可执行双模式的核心悬浮逻辑（照抄 TrollSpeed 正解）。
//  主 App 可执行（TrollStore 有效签名）的 main() 按 argv 分支调用：
//    -hud  -> HUDMainStart()  进悬浮模式（root persona 拉起后，无沙盒 + 系统
//                              entitlements 创建全局系统窗口 + 接收全局 HID 触摸）
//    -exit -> HUDExit()       杀悬浮进程（读 pid 文件）
//    -check-> HUDCheck()      查悬浮存活
//  这三个是 C 链接函数，供 Swift 主 App 的 main() 调用，避开 main 冲突。
//

#import <notify.h>
#import <mach-o/dyld.h>
#import <sys/utsname.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <dlfcn.h>
#import <string.h>
#import <limits.h>

#import "IOKit+SPI.h"
#import "HUDHelper.h"
#import "TSEventFetcher.h"
#import "BackboardServices.h"
#import "AXEventRepresentation.h"
#import "UIApplication+Private.h"
#import "HUDApp.h"

#define PID_PATH "/var/mobile/Library/Caches/trollagent.hud.pid"

static __used
NSString *mDeviceModel(void) {
    struct utsname systemInfo;
    uname(&systemInfo);
    return [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
}

static __used
void _HUDEventCallback(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event)
{
    static UIApplication *app = [UIApplication sharedApplication];
    log_debug(OS_LOG_DEFAULT, "_HUDEventCallback => %{public}@", event);

    if (@available(iOS 15.1, *)) {}
    else {
        [app _enqueueHIDEvent:event];
    }

    BOOL shouldUseAXEvent = YES;

    BOOL isExactly15 = NO;
    static NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
    if (version.majorVersion == 15 && version.minorVersion == 0 && version.patchVersion == 0) {
        NSString *deviceModel = mDeviceModel();
        if (![deviceModel hasPrefix:@"iPhone13,"] && ![deviceModel hasPrefix:@"iPhone14,"]) {
            isExactly15 = YES;
        }
    }

    if (@available(iOS 15.0, *)) {
        shouldUseAXEvent = !isExactly15;
    } else {
        shouldUseAXEvent = NO;
    }

    if (shouldUseAXEvent)
    {
        static Class AXEventRepresentationCls = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/AccessibilityUtilities.framework"] load];
            AXEventRepresentationCls = objc_getClass("AXEventRepresentation");
        });

        AXEventRepresentation *rep = [AXEventRepresentationCls representationWithHIDEvent:event hidStreamIdentifier:@"UIApplicationEvents"];

        dispatch_async(dispatch_get_main_queue(), ^(void) {
            static UIWindow *keyWindow = nil;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                keyWindow = [[app windows] firstObject];
#pragma clang diagnostic pop
            });

            UIView *keyView = [keyWindow hitTest:[rep location] withEvent:nil];

            UITouchPhase phase = UITouchPhaseEnded;
            if ([rep isTouchDown])
                phase = UITouchPhaseBegan;
            else if ([rep isMove])
                phase = UITouchPhaseMoved;
            else if ([rep isCancel])
                phase = UITouchPhaseCancelled;
            else if ([rep isLift] || [rep isInRange] || [rep isInRangeLift])
                phase = UITouchPhaseEnded;

            NSInteger pointerId = [[[[rep handInfo] paths] firstObject] pathIdentity];
            if (pointerId > 0)
                [TSEventFetcher receiveAXEventID:MIN(MAX(pointerId, 1), 98) atGlobalCoordinate:[rep location] withTouchPhase:phase inWindow:keyWindow onView:keyView];
        });
    }
}

// -exit：读 pid 文件杀掉 HUD 进程（主 App 关闭悬浮用）
// fix：pid 文件是全局可写路径（/var/mobile/Library/Caches），可能被篡改成任意 pid——
// 提权身份直接 kill 会变成"root 杀任意进程"攻击面。只允许 kill 本 HUD 二进制：
// 用 proc_pidpath 从内核读目标进程真实可执行路径，与当前进程路径比对，不匹配拒绝。
// dlopen libproc 运行时解析（与下方 HUDMainStart 清旧 HUD 同款，避免链接依赖）。
extern "C" void HUDExit(void)
{
    @autoreleasepool {
        NSString *pidPath = @(PID_PATH);
        // fix：pid 文件大小保护（内容仅几字节，≤64 字节）——防篡改成超大文件后整读 OOM
        NSString *pidString = nil;
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:pidPath error:nil];
        if (attr && [attr[NSFileSize] unsignedLongLongValue] <= 64) {
            pidString = [NSString stringWithContentsOfFile:pidPath
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
        }
        if (pidString)
        {
            pid_t pid = (pid_t)[pidString intValue];
            if (pid > 0) {
                typedef int (*ppath_fn)(pid_t, void *, uint32_t);
                void *proc_h = dlopen("/usr/lib/libproc.dylib", RTLD_LAZY);
                ppath_fn ppath = proc_h ? (ppath_fn)dlsym(proc_h, "proc_pidpath") : NULL;
                if (ppath) {
                    char selfPath[PATH_MAX] = {0};
                    char targetPath[PATH_MAX] = {0};
                    // proc_pidpath 返回写入字节数且不保证 NUL 结尾——用长度相等 + memcmp 比较，
                    // 避免 strcmp 在无 NUL 缓冲上越界读（fix 审计项）。
                    int selfLen = ppath(getpid(), selfPath, (uint32_t)sizeof(selfPath));
                    int targetLen = ppath(pid, targetPath, (uint32_t)sizeof(targetPath));
                    if (selfLen > 0 && selfLen == targetLen &&
                        memcmp(selfPath, targetPath, (size_t)selfLen) == 0) {
                        kill(pid, SIGKILL);
                        unlink([pidPath UTF8String]);
                    }
                }
                if (proc_h) dlclose(proc_h);
            }
        }
    }
}

// -check：返回 EXIT_FAILURE(存活) / EXIT_SUCCESS(未跑)
extern "C" int HUDCheck(void)
{
    @autoreleasepool {
        NSString *pidPath = @(PID_PATH);
        // fix：pid 文件加大小保护（内容仅几字节，≤64 字节）——防篡改成超大文件后整读 OOM
        NSString *pidString = nil;
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:pidPath error:nil];
        if (attr && [attr[NSFileSize] unsignedLongLongValue] <= 64) {
            pidString = [NSString stringWithContentsOfFile:pidPath
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
        }
        if (pidString)
        {
            pid_t pid = (pid_t)[pidString intValue];
            int alive = kill(pid, 0);
            return (alive == 0 ? EXIT_FAILURE : EXIT_SUCCESS);
        }
        return EXIT_SUCCESS;
    }
}

// 进 HUD 悬浮模式：不返回（内部 runloop）
extern "C" void HUDMainStart(void)
{
    @autoreleasepool
    {
        // v6.x Step2 诊断：每步写文件日志到 pid 同目录( Caches 已知可写，/var/mobile/Documents 可能被沙盒拒)，
        // 确证 mobile 不提权下 HUD 走到哪一步退出
        NSString *hudLogPath = @"/var/mobile/Library/Caches/hudapp.log";
        NSString *p = [NSString stringWithFormat:@"[HUD -hud] %@ step=enter\n", [NSDate date]];
        [p writeToFile:hudLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        log_debug(OS_LOG_DEFAULT, "HUD launched via -hud");

        pid_t pid = getpid();
        NSString *pidString = [NSString stringWithFormat:@"%d", pid];
        [pidString writeToFile:@(PID_PATH)
                    atomically:YES
                      encoding:NSUTF8StringEncoding
                         error:nil];

        // v6.0.8 根治叠加：HUD 进程是独立 root 进程，卸载 app 不杀它、旧 HUD 也不监听 exit 通知，
        // 所以"开关一次加一个角色"。这里 HUD（root 身份，有权杀同类）启动时枚举并杀掉所有旧 TrollAgentHUD，
        // 只留自己——无论旧 HUD 是否新版，都清干净。用 dlopen libproc + dlsym 避免链接依赖。
        {
            void *proc_h = dlopen("/usr/lib/libproc.dylib", RTLD_LAZY);
            if (proc_h) {
                typedef int (*plist_fn)(pid_t *, int);
                typedef int (*pname_fn)(pid_t, char *, int);
                plist_fn plist = (plist_fn)dlsym(proc_h, "proc_listallpids");
                pname_fn pname = (pname_fn)dlsym(proc_h, "proc_name");
                if (plist && pname) {
                    int cap = plist(NULL, 0);
                    if (cap > 0) {
                        pid_t *pids = (pid_t *)calloc((size_t)cap, sizeof(pid_t));
                        int n = plist(pids, (int)(cap * sizeof(pid_t)));
                        for (int i = 0; i < n && i < cap; i++) {
                            if (pids[i] <= 0 || pids[i] == pid) continue;
                            char nm[128] = {0};
                            if (pname(pids[i], nm, sizeof(nm)) > 0 && strstr(nm, "TrollAgentHUD") != NULL) {
                                kill(pids[i], SIGKILL);
                            }
                        }
                        free(pids);
                    }
                }
                dlclose(proc_h);
            }
        }

        [UIScreen initialize];
        CFRunLoopGetCurrent();
        p = [NSString stringWithFormat:@"[HUD -hud] step=before-GSInitialize pid=%d\n", pid];
        [p writeToFile:hudLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        GSInitialize();
        p = [NSString stringWithFormat:@"[HUD -hud] step=GSInitialize-ok\n"];
        [p writeToFile:hudLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        BKSDisplayServicesStart();
        UIApplicationInitialize();
        p = [NSString stringWithFormat:@"[HUD -hud] step=UIApplicationInitialize-ok\n"];
        [p writeToFile:hudLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        UIApplicationInstantiateSingleton(objc_getClass("HUDMainApplication"));
        p = [NSString stringWithFormat:@"[HUD -hud] step=InstantiateSingleton-ok\n"];
        [p writeToFile:hudLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        static id<UIApplicationDelegate> appDelegate = [[objc_getClass("HUDMainApplicationDelegate") alloc] init];
        [UIApplication.sharedApplication setDelegate:appDelegate];
        [UIApplication.sharedApplication _accessibilityInit];
        p = [NSString stringWithFormat:@"[HUD -hud] step=accessibilityInit-ok\n"];
        [p writeToFile:hudLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        [NSRunLoop currentRunLoop];
        BKSHIDEventRegisterEventCallback(_HUDEventCallback);
        p = [NSString stringWithFormat:@"[HUD -hud] step=BKSHIDEventRegister-ok\n"];
        [p writeToFile:hudLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        if (@available(iOS 15.0, *)) {
            GSEventInitialize(0);
            GSEventPushRunLoopMode(kCFRunLoopDefaultMode);
        }

        p = [NSString stringWithFormat:@"[HUD -hud] step=before-completeAndRunAsPlugin\n"];
        [p writeToFile:hudLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [UIApplication.sharedApplication __completeAndRunAsPlugin];

        // v6.0.8：监听退出通知——主 App 以 mobile 身份 kill 不掉 root 的 HUD 进程(EPERM)，
        // 导致"开关一次加一个角色"叠加。改为 HUD 自己监听 notify 后 _exit(0)（进程有权杀自己）。
        static int exitToken;
        notify_register_dispatch("com.trollagent.hud.exit", &exitToken, dispatch_get_main_queue(), ^(int t) {
            _exit(0);
        });

        CFRunLoopRun();
    }
}
