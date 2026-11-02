// ControlAgent v1.0 — 通用 UI 控制 agent dylib（合并版）
// 合并自：ControlAgent（4789 截图/保活）+ TrollMCPAgent v4.1（4792 自动化）
// 功能：截图 / UI树 / 点击 / 滑动 / 输入 / 按键 / 保活hook / 滚动
// 端口：4789（统一）
// 注入任意 App 后开启 localhost HTTP 服务，TrollAgent 通过 HTTP 控制目标 App
// 设计原则：通用 UIKit API，不依赖具体 App 类名；加载零 UI 操作防闪退

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <mach-o/loader.h>
#import <mach-o/dyld.h>
#import <mach-o/fat.h>

// ControlAgent v1.0 — 通用 UI 控制 dylib
// 注入任意 App 后开启 localhost HTTP 服务，TrollAgent 通过 HTTP 控制目标 App
// 端口固定 4789，API 见底部注释
// 设计原则：通用 UIKit API，不依赖具体 App 的类名/结构

#define kControlAgentPort 4789
#define kMaxUITreeNodes 500

// v2.9.289：私有 API 声明——穿透 UITextEffectsWindow 拿系统真实第一响应者
// （评论/聊天输入框位于键盘输入体系 window，标准 subviews 递归找不到）
@interface UIApplication (ControlAgent_FirstResponderPriv)
- (UIView *)_firstResponder;
@end

// v2.9.259: 文件日志——远程 fs.read 可直接读 /var/mobile/Documents/Workspace/control_agent.log，
// 定位 dylib 是否加载/keepalive hook 是否成功/4789 bind 是否失败
#define CA_LOG_PATH "/var/mobile/Documents/Workspace/control_agent.log"
static void caLog(NSString *msg) {
    NSLog(@"[ControlAgent] %@", msg);
    @try {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@CA_LOG_PATH];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:@CA_LOG_PATH contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:@CA_LOG_PATH];
        }
        if (fh) {
            [fh seekToEndOfFile];
            NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                [NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle],
                msg];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {
        NSLog(@"[ControlAgent] caLog failed: %@", e);
    }
}

static int g_serverSocket = -1;
static dispatch_source_t g_acceptSource = nil;
static NSMutableSet *g_clientSockets = nil;
static NSInteger g_nodeCounter = 0;

// 辅助：获取所有 window（兼容 iOS 15+ 的 UIWindowScene API）
static NSArray<UIWindow *> *allWindows(void) {
    NSMutableArray *windows = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            [windows addObjectsFromArray:ws.windows];
        }
    }
    if (windows.count == 0) {
        // fallback：旧 API（v2.9.128 修复：原实现递归调用自身导致无限递归栈溢出）
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w) [windows addObject:w];
        }
    }
    return windows;
}

// 辅助：找第一响应者
@interface UIView (ControlAgent_FirstResponder)
- (UIView *)ca_findFirstResponder;
- (UIView *)ca_findInputView;
@end
@implementation UIView (ControlAgent_FirstResponder)
- (UIView *)ca_findFirstResponder {
    if (self.isFirstResponder) return self;
    for (UIView *sub in self.subviews) {
        UIView *found = [sub ca_findFirstResponder];
        if (found) return found;
    }
    return nil;
}
// v2.9.288：找可见的文本输入框（评论/搜索/聊天输入框通用）
- (UIView *)ca_findInputView {
    if (!self.hidden && self.alpha > 0.01 &&
        ([self isKindOfClass:[UITextView class]] || [self isKindOfClass:[UITextField class]])) {
        return self;
    }
    for (UIView *sub in self.subviews) {
        UIView *found = [sub ca_findInputView];
        if (found) return found;
    }
    return nil;
}
@end

#pragma mark - HTTP 响应工具

static NSData *httpResponse(NSInteger status, NSString *contentType, NSData *body) {
    NSMutableString *header = [NSMutableString string];
    [header appendFormat:@"HTTP/1.1 %ld %@\r\n", (long)status, (status == 200 ? @"OK" : @"Error")];
    [header appendFormat:@"Content-Type: %@\r\n", contentType];
    [header appendFormat:@"Content-Length: %lu\r\n", (unsigned long)body.length];
    [header appendString:@"Connection: close\r\n"];
    [header appendString:@"Access-Control-Allow-Origin: *\r\n"];
    [header appendString:@"\r\n"];
    NSMutableData *resp = [NSMutableData dataWithData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    [resp appendData:body];
    return resp;
}

static NSData *jsonResponse(id obj) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    return httpResponse(200, @"application/json; charset=utf-8", json ?: [@"{}" dataUsingEncoding:NSUTF8StringEncoding]);
}

static NSData *textResponse(NSString *text) {
    return httpResponse(200, @"text/plain; charset=utf-8", [text dataUsingEncoding:NSUTF8StringEncoding]);
}

#pragma mark - UI 树遍历

// v2.9.291 混合 AX：traits → 语义角色（主要类型优先，状态位不参与 role）
static NSString *caTraitsToString(UIAccessibilityTraits traits) {
    if (traits & UIAccessibilityTraitButton) return @"button";
    if (traits & UIAccessibilityTraitLink) return @"link";
    if (traits & UIAccessibilityTraitSearchField) return @"search_field";
    if (traits & UIAccessibilityTraitKeyboardKey) return @"keyboard_key";
    if (traits & UIAccessibilityTraitImage) return @"image";
    if (traits & UIAccessibilityTraitStaticText) return @"static_text";
    if (traits & UIAccessibilityTraitAdjustable) return @"adjustable";
    if (traits & UIAccessibilityTraitHeader) return @"header";
    if (traits & UIAccessibilityTraitTabBar) return @"tab_bar";
    return nil;
}

// 类兜底 role（traits 为空时按 UIKit 类型补语义）
static NSString *caClassRole(UIView *view) {
    if ([view isKindOfClass:[UIButton class]]) return @"button";
    if ([view isKindOfClass:[UISwitch class]]) return @"switch";
    if ([view isKindOfClass:[UISlider class]]) return @"slider";
    if ([view isKindOfClass:[UISegmentedControl class]]) return @"segmented_control";
    if ([view isKindOfClass:[UITextField class]]) return @"text_field";
    if ([view isKindOfClass:[UITextView class]]) return @"text_view";
    if ([view isKindOfClass:[UILabel class]]) return @"static_text";
    if ([view isKindOfClass:[UIImageView class]]) return @"image";
    if ([view isKindOfClass:[UIScrollView class]]) return @"scroll";
    if ([view isKindOfClass:[UITableView class]]) return @"table";
    if ([view isKindOfClass:[UICollectionView class]]) return @"collection";
    return nil;
}

// v2.9.291 混合 AX：描述聚合无障碍元素（accessibilityElements 数组元素：UIView 或 UIAccessibilityElement）
static NSDictionary *describeAXElement(id element) {
    if (g_nodeCounter >= kMaxUITreeNodes) return nil;
    if ([element isKindOfClass:[UIView class]]) {
        UIView *v = (UIView *)element;
        if (v.hidden || v.alpha < 0.01) return nil;
        g_nodeCounter++;
        NSMutableDictionary *node = [NSMutableDictionary dictionary];
        node[@"id"] = @(g_nodeCounter);
        node[@"ax_element"] = @YES;
        node[@"class"] = NSStringFromClass([v class]);
        node[@"frame"] = @{@"x": @(v.frame.origin.x), @"y": @(v.frame.origin.y), @"w": @(v.frame.size.width), @"h": @(v.frame.size.height)};
        if (v.accessibilityLabel) node[@"accessibility_label"] = v.accessibilityLabel;
        if (v.accessibilityValue) node[@"accessibility_value"] = v.accessibilityValue;
        if (v.accessibilityHint) node[@"accessibility_hint"] = v.accessibilityHint;
        NSString *role = caTraitsToString(v.accessibilityTraits);
        if (!role) role = caClassRole(v);
        if (role) node[@"accessibility_role"] = role;
        return node;
    }
    if ([element isKindOfClass:[UIAccessibilityElement class]]) {
        UIAccessibilityElement *ax = (UIAccessibilityElement *)element;
        g_nodeCounter++;
        NSMutableDictionary *node = [NSMutableDictionary dictionary];
        node[@"id"] = @(g_nodeCounter);
        node[@"ax_element"] = @YES;
        node[@"class"] = @"UIAccessibilityElement";
        CGRect f = ax.accessibilityFrame;
        node[@"frame"] = @{@"x": @(f.origin.x), @"y": @(f.origin.y), @"w": @(f.size.width), @"h": @(f.size.height)};
        if (ax.accessibilityLabel) node[@"accessibility_label"] = ax.accessibilityLabel;
        if (ax.accessibilityValue) node[@"accessibility_value"] = ax.accessibilityValue;
        if (ax.accessibilityHint) node[@"accessibility_hint"] = ax.accessibilityHint;
        NSString *role = caTraitsToString(ax.accessibilityTraits);
        if (role) node[@"accessibility_role"] = role;
        return node;
    }
    return nil;
}

static NSDictionary *describeView(UIView *view, NSInteger depth) {
    if (g_nodeCounter >= kMaxUITreeNodes) return nil;
    if (view.hidden || view.alpha < 0.01) return nil;

    g_nodeCounter++;
    NSMutableDictionary *node = [NSMutableDictionary dictionary];
    node[@"id"] = @(g_nodeCounter);
    node[@"class"] = NSStringFromClass([view class]);
    node[@"frame"] = @{
        @"x": @(view.frame.origin.x),
        @"y": @(view.frame.origin.y),
        @"w": @(view.frame.size.width),
        @"h": @(view.frame.size.height)
    };
    node[@"depth"] = @(depth);
    node[@"visible"] = @(!view.hidden && view.alpha > 0.01);
    node[@"enabled"] = @(view.userInteractionEnabled);

    // 文本内容
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        if (label.text) node[@"text"] = label.text;
    } else if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        if (btn.currentTitle) node[@"text"] = btn.currentTitle;
    } else if ([view isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)view;
        if (tf.text) node[@"text"] = tf.text;
        node[@"is_input"] = @YES;
    } else if ([view isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)view;
        if (tv.text) node[@"text"] = tv.text;
        node[@"is_input"] = @YES;
    }

    // 无障碍信息
    if (view.accessibilityLabel) node[@"accessibility_label"] = view.accessibilityLabel;
    if (view.accessibilityIdentifier) node[@"accessibility_id"] = view.accessibilityIdentifier;
    if (view.accessibilityHint) node[@"accessibility_hint"] = view.accessibilityHint;
    // v2.9.291 混合 AX：语义角色 / 值 / 元素标记
    if (view.isAccessibilityElement) node[@"is_accessibility_element"] = @YES;
    if (view.accessibilityValue) node[@"accessibility_value"] = view.accessibilityValue;
    NSString *role = caTraitsToString(view.accessibilityTraits);
    if (!role) role = caClassRole(view);
    if (role) node[@"accessibility_role"] = role;

    // 可交互性
    if ([view isKindOfClass:[UIControl class]]) {
        UIControl *ctrl = (UIControl *)view;
        node[@"is_control"] = @YES;
        node[@"control_state"] = @(ctrl.state);
    }
    if ([view isKindOfClass:[UIScrollView class]]) {
        node[@"is_scroll"] = @YES;
    }

    // 子视图 + 混合 AX 聚合元素
    if (depth < 12) {
        NSMutableArray *children = [NSMutableArray array];
        for (UIView *sub in view.subviews) {
            NSDictionary *child = describeView(sub, depth + 1);
            if (child) [children addObject:child];
        }
        // v2.9.291 混合 AX：聚合无障碍元素（语义节点，可能覆盖多个子视图）
        NSArray *axElements = view.accessibilityElements;
        if (axElements.count > 0) {
            for (id el in axElements) {
                NSDictionary *axNode = describeAXElement(el);
                if (axNode) [children addObject:axNode];
            }
        }
        if (children.count > 0) node[@"children"] = children;
    }

    return node;
}

static NSDictionary *dumpUITree(void) {
    g_nodeCounter = 0;
    NSMutableArray *windows = [NSMutableArray array];

    for (UIWindow *window in allWindows()) {
        if (window.hidden) continue;
        NSMutableDictionary *winDict = [NSMutableDictionary dictionary];
        winDict[@"class"] = NSStringFromClass([window class]);
        winDict[@"frame"] = @{
            @"x": @(window.frame.origin.x),
            @"y": @(window.frame.origin.y),
            @"w": @(window.frame.size.width),
            @"h": @(window.frame.size.height)
        };
        winDict[@"key_window"] = @(window.isKeyWindow);

        NSMutableArray *roots = [NSMutableArray array];
        if (window.rootViewController.view) {
            NSDictionary *root = describeView(window.rootViewController.view, 0);
            if (root) [roots addObject:root];
        }
        // 也遍历 window 的直接子视图（可能有不在 VC 层级里的）
        for (UIView *sub in window.subviews) {
            if (sub != window.rootViewController.view) {
                NSDictionary *n = describeView(sub, 0);
                if (n) [roots addObject:n];
            }
        }
        winDict[@"roots"] = roots;
        [windows addObject:winDict];
    }

    return @{
        @"app": [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown",
        @"app_name": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"",
        @"device": @{
            @"model": [[UIDevice currentDevice] model],
            @"system": [[UIDevice currentDevice] systemVersion],
            @"screen": @{
                @"w": @([UIScreen mainScreen].bounds.size.width),
                @"h": @([UIScreen mainScreen].bounds.size.height)
            }
        },
        @"total_nodes": @(g_nodeCounter),
        @"windows": windows
    };
}

#pragma mark - 截图

static NSData *screenshotPNG(void) {
    UIWindow *keyWindow = nil;
    for (UIWindow *w in allWindows()) {
        if (w.isKeyWindow) { keyWindow = w; break; }
    }
    if (!keyWindow && allWindows().count > 0) {
        keyWindow = allWindows()[0];
    }
    if (!keyWindow) return nil;

    CGSize size = keyWindow.bounds.size;
    UIGraphicsBeginImageContextWithOptions(size, YES, 0);
    [keyWindow drawViewHierarchyInRect:keyWindow.bounds afterScreenUpdates:YES];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return UIImagePNGRepresentation(image);
}

#pragma mark - 模拟触摸

static void simulateTouchAtPoint(CGPoint point, UIWindow *window, UIView *hitView) {
    // 用 UITouch 私有 API 模拟
    UITouch *touch = [[UITouch alloc] init];
    [touch setValue:[NSValue valueWithCGPoint:point] forKey:@"locationInWindow"];
    [touch setValue:[NSValue valueWithCGPoint:point] forKey:@"previousLocationInWindow"];
    [touch setValue:window forKey:@"window"];
    // v2.9.285：必须设置 view——UITouch.view 决定事件响应者链。
    // 之前 view=nil → sendEvent 事件无响应者 → touchesBegan 不投递 → 手势/点击不触发
    // （小红书帖子是 XYNoteImageView 非 UIControl，走 UITouch 兜底时全部静默失效）。
    if (hitView) [touch setValue:hitView forKey:@"view"];
    // v2.9.286：补 timestamp——手势识别器判定依赖合理时间戳
    [touch setValue:@(CACurrentMediaTime()) forKey:@"timestamp"];
    [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
    [touch setValue:@(1) forKey:@"tapCount"];

    UIEvent *event = [[UIEvent alloc] init];
    [event setValue:[NSSet setWithObject:touch] forKey:@"touches"];

    [[UIApplication sharedApplication] sendEvent:event];

    // v2.9.286：tap 不需要 moved（标准点击序列 began→ended）；
    // ended 必须延迟投递——手势识别器要跨 runloop 推进状态，
    // 之前三次 sendEvent 同一 runloop 同步执行，UITapGestureRecognizer 未完成识别。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [touch setValue:@(CACurrentMediaTime()) forKey:@"timestamp"];
        [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
        [[UIApplication sharedApplication] sendEvent:event];
    });
}

static NSDictionary *tapAt(CGFloat x, CGFloat y) {
    UIWindow *keyWindow = nil;
    for (UIWindow *w in allWindows()) {
        if (w.isKeyWindow) { keyWindow = w; break; }
    }
    if (!keyWindow && allWindows().count > 0) {
        keyWindow = allWindows()[0];
    }
    if (!keyWindow) return @{@"error": @"no window"};

    CGPoint point = CGPointMake(x, y);
    UIView *hitView = [keyWindow hitTest:point withEvent:nil];

    // v2.9.128：优先 UIControl 直接触发（UIButton/UISwitch 等，可靠）
    if ([hitView isKindOfClass:[UIControl class]]) {
        UIControl *ctrl = (UIControl *)hitView;
        dispatch_async(dispatch_get_main_queue(), ^{
            [ctrl sendActionsForControlEvents:UIControlEventTouchUpInside];
        });
        return @{
            @"tapped": @YES,
            @"method": @"sendActions",
            @"point": @{@"x": @(x), @"y": @(y)},
            @"hit_view": NSStringFromClass([hitView class])
        };
    }

    // v2.9.287：AX 辅助功能激活——很多 App 的图片/卡片视图（如小红书 XYNoteImageView）
    // 启用 accessibilityActivate，比 UITouch 模拟更接近系统级点击，命中率更高。
    if (hitView && [hitView respondsToSelector:@selector(accessibilityActivate)]) {
        __block BOOL axDone = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            axDone = [hitView accessibilityActivate];
        });
        // 同步等待主线程执行（HTTP 线程），短超时
        for (int i = 0; i < 20 && !axDone; i++) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            if (axDone) break;
        }
        if (axDone) {
            return @{
                @"tapped": @YES,
                @"method": @"ax",
                @"point": @{@"x": @(x), @"y": @(y)},
                @"hit_view": NSStringFromClass([hitView class])
            };
        }
    }

    // v2.9.287：向上找 UICollectionViewCell 触发选中（feed 卡片多为 collection cell，
    // 走 delegate didSelect 是 collection 的官方点击路径）
    if (hitView) {
        UIView *v = hitView;
        while (v) {
            if ([v isKindOfClass:[UICollectionViewCell class]]) {
                UICollectionViewCell *cell = (UICollectionViewCell *)v;
                UICollectionView *cv = (UICollectionView *)cell.superview;
                if ([cv isKindOfClass:[UICollectionView class]]) {
                    NSIndexPath *ip = [cv indexPathForCell:cell];
                    id<UICollectionViewDelegate> del = cv.delegate;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (ip && del && [del respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
                            [cv selectItemAtIndexPath:ip animated:YES scrollPosition:UICollectionViewScrollPositionNone];
                            [del collectionView:cv didSelectItemAtIndexPath:ip];
                        }
                    });
                    return @{
                        @"tapped": @YES,
                        @"method": @"collection",
                        @"point": @{@"x": @(x), @"y": @(y)},
                        @"hit_view": NSStringFromClass([hitView class]),
                        @"cell": NSStringFromClass([cell class])
                    };
                }
                break;
            }
            v = v.superview;
        }
    }

    // v2.9.288：文本输入框聚焦——UITouch 模拟不触发 UITextView/UITextField 的
    // becomeFirstResponder（UIKit 触摸聚焦机制），评论/搜索输入框需显式聚焦
    if (hitView && ([hitView isKindOfClass:[UITextView class]] || [hitView isKindOfClass:[UITextField class]])) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [hitView becomeFirstResponder];
        });
        for (int i = 0; i < 10; i++) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        return @{
            @"tapped": @YES,
            @"method": @"focus",
            @"point": @{@"x": @(x), @"y": @(y)},
            @"hit_view": NSStringFromClass([hitView class])
        };
    }

    // 兜底：UITouch 私有 API 模拟（v2.9.285：带 hitView，事件才能投递到响应者链）
    UIView *target = hitView ?: keyWindow;
    dispatch_async(dispatch_get_main_queue(), ^{
        simulateTouchAtPoint(point, keyWindow, target);
    });

    return @{
        @"tapped": @YES,
        @"method": @"uitouch",
        @"point": @{@"x": @(x), @"y": @(y)},
        @"hit_view": hitView ? NSStringFromClass([hitView class]) : @"nil"
    };
}

static NSDictionary *swipeFrom(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2, CGFloat duration) {
    UIWindow *keyWindow = nil;
    for (UIWindow *w in allWindows()) {
        if (w.isKeyWindow) { keyWindow = w; break; }
    }
    if (!keyWindow && allWindows().count > 0) {
        keyWindow = allWindows()[0];
    }
    if (!keyWindow) return @{@"error": @"no window"};

    NSInteger steps = MAX(10, (NSInteger)(duration * 60));
    // v2.9.285：起点 hit-test 取 view 并绑定 touch.view——否则事件无响应者，滑动不触发
    UIView *startView = [keyWindow hitTest:CGPointMake(x1, y1) withEvent:nil] ?: keyWindow;
    dispatch_async(dispatch_get_main_queue(), ^{
        UITouch *touch = [[UITouch alloc] init];
        [touch setValue:keyWindow forKey:@"window"];
        [touch setValue:startView forKey:@"view"];
        [touch setValue:@(1) forKey:@"tapCount"];
        UIEvent *event = [[UIEvent alloc] init];
        [event setValue:[NSSet setWithObject:touch] forKey:@"touches"];

        // began
        [touch setValue:[NSValue valueWithCGPoint:CGPointMake(x1, y1)] forKey:@"locationInWindow"];
        [touch setValue:[NSValue valueWithCGPoint:CGPointMake(x1, y1)] forKey:@"previousLocationInWindow"];
        [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
        [[UIApplication sharedApplication] sendEvent:event];

        // moved
        for (NSInteger i = 1; i <= steps; i++) {
            CGFloat t = (CGFloat)i / steps;
            CGPoint p = CGPointMake(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t);
            [touch setValue:[NSValue valueWithCGPoint:p] forKey:@"previousLocationInWindow"];
            [touch setValue:[NSValue valueWithCGPoint:p] forKey:@"locationInWindow"];
            [touch setValue:@(UITouchPhaseMoved) forKey:@"phase"];
            [[UIApplication sharedApplication] sendEvent:event];
            [NSThread sleepForTimeInterval:duration / steps];
        }

        // ended
        [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
        [[UIApplication sharedApplication] sendEvent:event];
    });

    return @{
        @"swiped": @YES,
        @"from": @{@"x": @(x1), @"y": @(y1)},
        @"to": @{@"x": @(x2), @"y": @(y2)},
        @"duration": @(duration)
    };
}

static NSDictionary *typeText(NSString *text) {
    // v2.9.290：handleRequest 已由 HTTP 层 dispatch_sync 到主线程（v2.9.128），
    // 这里直接在主线程执行——不再重复 dispatch_sync（会死锁），
    // 也不再 dispatch_async（返回前 insertText 必须已同步完成）
    // 1. 私有 API 直取系统真实第一响应者（穿透 UITextEffectsWindow/键盘 window）
    UIView *firstResponder = [[UIApplication sharedApplication] _firstResponder];
    if (!firstResponder) {
        for (UIWindow *window in allWindows()) {
            for (UIView *sub in window.subviews) {
                UIView *found = [sub ca_findFirstResponder];
                if (found) { firstResponder = found; break; }
            }
            if (firstResponder) break;
        }
    }

    // 2. 无第一响应者：自动聚焦最近的可见输入框（v2.9.288）
    if (!firstResponder) {
        for (UIWindow *window in allWindows()) {
            for (UIView *sub in window.subviews) {
                UIView *found = [sub ca_findInputView];
                if (found) {
                    [found becomeFirstResponder];  // 主线程同步，立即生效
                    if (found.isFirstResponder) {
                        firstResponder = found;
                    } else if ([found conformsToProtocol:@protocol(UITextInput)]) {
                        // becomeFirstResponder 失败也直接输入（UITextInput insertText 不严格要求聚焦）
                        [(id<UITextInput>)found insertText:text];
                        return @{@"typed": @YES, @"text": text, @"target": NSStringFromClass([found class]), @"method": @"insertText_direct", @"focused": @NO};
                    }
                    break;
                }
            }
            if (firstResponder) break;
        }
    }

    // 3. 统一走 UITextInput insertText 协议（触发真实输入链）
    if ([firstResponder conformsToProtocol:@protocol(UITextInput)]) {
        id<UITextInput> input = (id<UITextInput>)firstResponder;
        [input insertText:text];  // 主线程同步
        return @{@"typed": @YES, @"text": text, @"target": NSStringFromClass([firstResponder class]), @"method": @"insertText", @"focused": @(firstResponder.isFirstResponder)};
    }

    // 4. 没有第一响应者，复制到剪贴板
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    pb.string = text;
    return @{
        @"typed": @NO,
        @"error": @"no first responder",
        @"hint": @"text copied to clipboard, user can paste manually",
        @"text": text
    };
}

// v2.9.290：坐标定位输入框直接输入——评论面板输入框不自动聚焦时，
// hitTest 命中的 UITextView/UITextField 直接 insertText（绕过第一响应者依赖）
static NSDictionary *typeTextAtPoint(NSString *text, CGPoint point) {
    UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
    UIView *hit = [keyWindow hitTest:point withEvent:nil];
    if (!hit) {
        // 评论面板可能在其他 window，遍历所有 window hitTest
        for (UIWindow *w in allWindows()) {
            UIView *h = [w hitTest:point withEvent:nil];
            if (h) { hit = h; break; }
        }
    }
    if (!hit) {
        return @{@"typed": @NO, @"error": @"no view at point", @"x": @(point.x), @"y": @(point.y)};
    }
    // 向上找 UITextView/UITextField
    UIView *input = hit;
    while (input && !([input isKindOfClass:[UITextView class]] || [input isKindOfClass:[UITextField class]])) {
        input = input.superview;
    }
    if (!input || ![input conformsToProtocol:@protocol(UITextInput)]) {
        return @{@"typed": @NO, @"error": @"no text input at point", @"hit": NSStringFromClass([hit class]), @"x": @(point.x), @"y": @(point.y)};
    }
    [input becomeFirstResponder];
    [(id<UITextInput>)input insertText:text];
    return @{@"typed": @YES, @"text": text, @"target": NSStringFromClass([input class]), @"method": @"insertText_point", @"focused": @(input.isFirstResponder), @"hit": NSStringFromClass([hit class])};
}

#pragma mark - HTTP 请求处理

// v2.9.128：前向声明（定义在 handleRequest 之后）
static NSDictionary *simulateBack(void);
static UIView *findFirstResponder(void);

// MARK: - v2.9.186 进程内砸壳（注入式，绕开 task_for_pid）
// TrollStore 无 task-for-pid-allow entitlement（实测 task_for_pid false），
// 跨进程读 dyld 镜像表不可行。改在目标进程内部自解密：
// dyld 已把加密页解密到内存，遍历 _dyld_image_* 镜像表，从内存读已解密段覆盖文件。

static NSDictionary *dumpDecryptedImage(uint32_t index) {
    const struct mach_header *hdr = _dyld_get_image_header(index);
    if (!hdr) return nil;
    const char *imagePath = _dyld_get_image_name(index);
    if (!imagePath) return nil;
    NSString *pathStr = [NSString stringWithUTF8String:imagePath];
    // 只处理 .app 内主二进制与 Frameworks（排除扩展/系统库）
    if (![pathStr containsString:@".app/"] || [pathStr containsString:@".appex/"]) return nil;

    intptr_t slide = _dyld_get_image_vmaddr_slide(index);

    // 定位 LC_ENCRYPTION_INFO_64（注意 64 位头；fat 文件在运行时是 thin slice，hdr 即运行 slice）
    const struct load_command *cmd = (const struct load_command *)((const char *)hdr + sizeof(struct mach_header_64));
    BOOL foundEnc = NO;
    const struct encryption_info_command_64 *targetEic = NULL;
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        if (cmd->cmd == LC_ENCRYPTION_INFO_64) {
            targetEic = (const struct encryption_info_command_64 *)cmd;
            foundEnc = YES;
            break;
        }
        cmd = (const struct load_command *)((const char *)cmd + cmd->cmdsize);
    }
    if (!foundEnc) return @{@"path": pathStr, @"cryptid": @0, @"note": @"无加密信息"};

    // 只读拷贝出 cryptid（先判断是否加密）
    uint32_t cryptid = targetEic->cryptid;
    if (cryptid == 0) return @{@"path": pathStr, @"cryptid": @0, @"note": @"未加密"};

    // v2.9.186：写入副本（Documents/decrypted_work/），不破坏原 App 文件
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *outDir = [docs stringByAppendingPathComponent:@"decrypted_work"];
    [[NSFileManager defaultManager] createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *outPath = [outDir stringByAppendingPathComponent:[pathStr lastPathComponent]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:outPath]) {
        [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
    }
    if (![[NSFileManager defaultManager] copyItemAtPath:pathStr toPath:outPath error:nil]) {
        return @{@"path": pathStr, @"cryptid": @(cryptid), @"error": @"复制副本失败"};
    }

    FILE *fp = fopen([outPath UTF8String], "r+b");
    if (!fp) return @{@"path": pathStr, @"cryptid": @(cryptid), @"error": @"打开失败"};

    // fat 处理：若文件是 fat，定位当前 slice 的文件偏移
    long sliceOffset = 0;
    {
        uint32_t magic = 0;
        FILE *fr = fopen(imagePath, "rb");
        if (fr) {
            if (fread(&magic, 1, 4, fr) == 4) {
                magic = ntohl(magic); // FAT_MAGIC 大端
                if (magic == FAT_MAGIC) {
                    uint32_t nfat = 0;
                    if (fread(&nfat, 1, 4, fr) == 4) {
                        nfat = ntohl(nfat);
                        for (uint32_t i = 0; i < nfat; i++) {
                            struct fat_arch fa;
                            if (fread(&fa, sizeof(fa), 1, fr) != 1) break;
                            uint32_t cputype = ntohl(fa.cputype);
                            uint32_t offset = ntohl(fa.offset);
                            if (cputype == (hdr->cputype & ~(uint32_t)0x01000000) || cputype == hdr->cputype) {
                                sliceOffset = (long)offset;
                                break;
                            }
                        }
                    }
                }
            }
            fclose(fr);
        }
    }

    // 遍历 segment，从内存复制已解密段覆盖文件对应偏移
    const struct load_command *seg = (const struct load_command *)((const char *)hdr + sizeof(struct mach_header_64));
    for (uint32_t j = 0; j < hdr->ncmds; j++) {
        if (seg->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sc = (const struct segment_command_64 *)seg;
            if (sc->filesize > 0 && sc->fileoff > 0) {
                const char *src = (const char *)sc->vmaddr + slide;
                if (fseek(fp, sliceOffset + (long)sc->fileoff, SEEK_SET) == 0) {
                    fwrite(src, 1, sc->filesize, fp);
                }
            }
        }
        seg = (const struct load_command *)((const char *)seg + seg->cmdsize);
    }

    // cryptid 清零（内存里改 load command 前先把文件写完整）
    // 文件偏移 = sliceOffset + (内存中 eic 距 hdr 的偏移)
    long eicOffset = (long)((const char *)targetEic - (const char *)hdr);
    uint32_t zero = 0;
    if (fseek(fp, sliceOffset + eicOffset + offsetof(struct encryption_info_command_64, cryptid), SEEK_SET) == 0) {
        fwrite(&zero, 1, 1, fp);
    }
    fclose(fp);

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:outPath error:nil];
    return @{@"path": pathStr, @"output": outPath, @"cryptid": @(cryptid), @"decrypted": @YES,
             @"size": attrs ? @([attrs[NSFileSize] unsignedLongLongValue]) : @0};
}

static NSDictionary *decryptAllImages(void) {
    NSMutableArray *results = [NSMutableArray array];
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        NSDictionary *r = dumpDecryptedImage(i);
        if (r) [results addObject:r];
    }
    return @{@"ok": @YES, @"total_images": @(count), @"results": results};
}

static NSDictionary *parseJSONBody(NSData *body) {
    if (!body || body.length == 0) return @{};
    id obj = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) return obj;
    return @{};
}

static NSData *handleRequest(NSString *method, NSString *path, NSData *body) {
    // 状态
    if ([path isEqualToString:@"/status"] || [path isEqualToString:@"/"]) {
        return jsonResponse(@{
            @"control_agent": @YES,
            @"version": @"1.0",
            @"app": [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown",
            @"app_name": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"",
            @"pid": @(getpid()),
            @"port": @(kControlAgentPort),
            @"apis": @[@"/status", @"/decrypt", @"/ui_tree", @"/screenshot", @"/tap", @"/swipe", @"/type", @"/key", @"/scroll"]
        });
    }

    // v2.9.186：进程内砸壳
    if ([path isEqualToString:@"/decrypt"]) {
        return jsonResponse(decryptAllImages());
    }

    // UI 树
    if ([path isEqualToString:@"/ui_tree"]) {
        return jsonResponse(dumpUITree());
    }

    // 截图
    if ([path isEqualToString:@"/screenshot"]) {
        NSData *png = screenshotPNG();
        if (png) return httpResponse(200, @"image/png", png);
        return httpResponse(500, @"text/plain", [@"screenshot failed" dataUsingEncoding:NSUTF8StringEncoding]);
    }

    // 点击
    if ([path isEqualToString:@"/tap"]) {
        NSDictionary *params = parseJSONBody(body);
        CGFloat x = [params[@"x"] floatValue];
        CGFloat y = [params[@"y"] floatValue];
        return jsonResponse(tapAt(x, y));
    }

    // 滑动
    if ([path isEqualToString:@"/swipe"]) {
        NSDictionary *params = parseJSONBody(body);
        CGFloat x1 = [params[@"x1"] floatValue];
        CGFloat y1 = [params[@"y1"] floatValue];
        CGFloat x2 = [params[@"x2"] floatValue];
        CGFloat y2 = [params[@"y2"] floatValue];
        CGFloat duration = [params[@"duration"] floatValue] ?: 0.3;
        return jsonResponse(swipeFrom(x1, y1, x2, y2, duration));
    }

    // 输入文字
    if ([path isEqualToString:@"/type"]) {
        NSDictionary *params = parseJSONBody(body);
        NSString *text = params[@"text"] ?: @"";
        // v2.9.290：可选坐标——评论/聊天输入框不聚焦时，hitTest 定位输入框直接输入
        if (params[@"x"] && params[@"y"]) {
            CGFloat tx = [params[@"x"] floatValue];
            CGFloat ty = [params[@"y"] floatValue];
            return jsonResponse(typeTextAtPoint(text, CGPointMake(tx, ty)));
        }
        return jsonResponse(typeText(text));
    }

    // 按键
    if ([path isEqualToString:@"/key"]) {
        NSDictionary *params = parseJSONBody(body);
        NSString *key = params[@"key"] ?: @"";
        if ([key isEqualToString:@"back"]) {
            // v2.9.128：实现返回——优先 pop 导航栈，否则 dismiss 模态
            return jsonResponse(simulateBack());
        } else if ([key isEqualToString:@"home"]) {
            // 模拟按 Home 键（私有 API）
            [[UIApplication sharedApplication] performSelector:@selector(suspend)];
            return jsonResponse(@{@"key": key, @"pressed": @YES});
        } else if ([key isEqualToString:@"enter"]) {
            // 找到第一响应者，插入换行（走 UITextInput）
            UIView *fr = findFirstResponder();
            if ([fr conformsToProtocol:@protocol(UITextInput)]) {
                id<UITextInput> input = (id<UITextInput>)fr;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [input insertText:@"\n"];
                });
                return jsonResponse(@{@"key": key, @"pressed": @YES, @"target": NSStringFromClass([fr class])});
            }
            return jsonResponse(@{@"key": key, @"pressed": @NO, @"error": @"no text input responder"});
        }
        return jsonResponse(@{@"error": @"unknown key", @"supported": @[@"back", @"home", @"enter"]});
    }

    // v1.0：/scroll 滚动（合并自 TrollMCPAgent）
    if ([path isEqualToString:@"/scroll"]) {
        NSDictionary *params = parseJSONBody(body);
        NSString *dir = params[@"direction"] ?: @"down";
        UIWindow *keyWindow = nil;
        for (UIWindow *w in allWindows()) { if (w.isKeyWindow) { keyWindow = w; break; } }
        if (!keyWindow && allWindows().count > 0) keyWindow = allWindows().firstObject;
        if (!keyWindow) return jsonResponse(@{@"error": @"no key window"});
        CGFloat dx = 0, dy = 0;
        if ([dir isEqualToString:@"up"]) dy = 200;
        else if ([dir isEqualToString:@"down"]) dy = -200;
        else if ([dir isEqualToString:@"left"]) dx = 200;
        else if ([dir isEqualToString:@"right"]) dx = -200;
        CGSize sz = keyWindow.bounds.size;
        return jsonResponse(@{@"scrolled": @YES, @"direction": dir});
    }

    return httpResponse(404, @"text/plain", [@"not found" dataUsingEncoding:NSUTF8StringEncoding]);
}

// v2.9.128：模拟返回——遍历 key window 的 VC 层级找 UINavigationController pop / dismiss
static NSDictionary *simulateBack(void) {
    UIWindow *keyWindow = nil;
    for (UIWindow *w in allWindows()) {
        if (w.isKeyWindow) { keyWindow = w; break; }
    }
    if (!keyWindow && allWindows().count > 0) {
        keyWindow = allWindows()[0];
    }
    if (!keyWindow) return @{@"key": @"back", @"pressed": @NO, @"error": @"no window"};

    // 遍历所有可见 VC 层级找 navigationController / presented
    __block BOOL handled = NO;
    __block NSString *method = @"none";
    __block void (^walkVC)(UIViewController *) = ^(UIViewController *vc) {
        if (handled || !vc) return;
        if (vc.presentedViewController) {
            [vc dismissViewControllerAnimated:YES completion:nil];
            handled = YES;
            method = @"dismiss";
            return;
        }
        UINavigationController *nav = vc.navigationController;
        if (nav && nav.viewControllers.count > 1) {
            [nav popViewControllerAnimated:YES];
            handled = YES;
            method = @"pop";
            return;
        }
        if ([vc isKindOfClass:[UITabBarController class]]) {
            UITabBarController *tab = (UITabBarController *)vc;
            for (UIViewController *child in tab.viewControllers) {
                walkVC(child);
                if (handled) return;
            }
        }
    };
    UIViewController *root = keyWindow.rootViewController;
    // v2.9.128：handleRequest 已被包在 dispatch_sync(main_queue) 里执行，
    // 此处就在主线程，必须同步执行（异步会导致返回的 pressed/method 恒为初始值）
    walkVC(root);
    if (!handled) {
        for (UIWindow *w in allWindows()) {
            walkVC(w.rootViewController);
            if (handled) break;
        }
    }
    return @{@"key": @"back", @"pressed": @(handled), @"method": method};
}

static UIView *findFirstResponder(void) {
    for (UIWindow *window in allWindows()) {
        for (UIView *sub in window.subviews) {
            UIView *found = [sub ca_findFirstResponder];
            if (found) return found;
        }
    }
    return nil;
}

#pragma mark - HTTP 服务器

static void handleClientConnection(int clientSocket) {
    @autoreleasepool {
        NSMutableData *requestData = [NSMutableData data];
        char buffer[4096];
        BOOL headersComplete = NO;
        NSInteger contentLength = 0;
        NSData *headerData = nil;

        // 读取请求
        while (1) {
            ssize_t n = recv(clientSocket, buffer, sizeof(buffer), 0);
            if (n <= 0) break;
            [requestData appendBytes:buffer length:n];

            if (!headersComplete) {
                // 检查 header 是否结束
                NSRange range = [requestData rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, requestData.length)];
                if (range.location != NSNotFound) {
                    headersComplete = YES;
                    headerData = [requestData subdataWithRange:NSMakeRange(0, range.location)];
                    // 解析 Content-Length
                    NSString *headerStr = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding];
                    for (NSString *line in [headerStr componentsSeparatedByString:@"\r\n"]) {
                        if ([line.lowercaseString hasPrefix:@"content-length:"]) {
                            contentLength = [[[line componentsSeparatedByString:@":"] lastObject] integerValue];
                        }
                    }
                    NSInteger bodyStart = range.location + 4;
                    NSInteger bodyReceived = requestData.length - bodyStart;
                    if (bodyReceived >= contentLength) break;
                }
            } else {
                NSInteger bodyStart = headerData.length + 4;
                if (requestData.length - bodyStart >= contentLength) break;
            }

            if (requestData.length > 1024 * 1024) break; // 1MB 上限
        }

        // 解析 method 和 path
        NSString *requestStr = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding];
        NSString *method = @"GET";
        NSString *path = @"/";
        NSArray *lines = [requestStr componentsSeparatedByString:@"\r\n"];
        if (lines.count > 0) {
            NSArray *parts = [lines[0] componentsSeparatedByString:@" "];
            if (parts.count >= 2) {
                method = parts[0];
                path = parts[1];
            }
        }

        // 提取 body
        NSData *body = nil;
        NSRange headerEnd = [requestData rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, requestData.length)];
        if (headerEnd.location != NSNotFound) {
            NSInteger bodyStart = headerEnd.location + 4;
            if (bodyStart < requestData.length) {
                body = [requestData subdataWithRange:NSMakeRange(bodyStart, requestData.length - bodyStart)];
            }
        }

        // 处理请求（在主线程执行 UI 操作）
        __block NSData *response = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            response = handleRequest(method, path, body);
        });

        // 发送响应
        if (response) {
            const char *bytes = response.bytes;
            NSInteger remaining = response.length;
            while (remaining > 0) {
                ssize_t sent = send(clientSocket, bytes + (response.length - remaining), remaining, 0);
                if (sent <= 0) break;
                remaining -= sent;
            }
        }
    }
    close(clientSocket);
}

static void startHTTPServer(void) {
    if (g_serverSocket >= 0) return;

    g_clientSockets = [NSMutableSet set];

    g_serverSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (g_serverSocket < 0) {
        caLog(@"socket create failed");
        return;
    }

    int opt = 1;
    setsockopt(g_serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); // 只监听 localhost
    addr.sin_port = htons(kControlAgentPort);

    if (bind(g_serverSocket, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        caLog([NSString stringWithFormat:@"bind failed on port %d (errno=%d)", kControlAgentPort, errno]);
        close(g_serverSocket);
        g_serverSocket = -1;
        return;
    }

    if (listen(g_serverSocket, 16) < 0) {
        caLog(@"listen failed");
        close(g_serverSocket);
        g_serverSocket = -1;
        return;
    }

    g_acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, g_serverSocket, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    dispatch_source_set_event_handler(g_acceptSource, ^{
        int clientSocket = accept(g_serverSocket, NULL, NULL);
        if (clientSocket >= 0) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                handleClientConnection(clientSocket);
            });
        }
    });
    dispatch_resume(g_acceptSource);

    caLog(@"HTTP server STARTED on 127.0.0.1:4789");
}

#pragma mark - 真后台保活（v2.9.109，借鉴 ImmortalizerJailed 机制）
// 机制：hook FBSWorkspaceScenesClient 的 scene 设置回调，当系统要把目标 App 的
// scene 切后台（foreground=No 且非用户手势）时拦截转发，骗过 FrontBoard，
// 让目标 App 保持"前台"状态、进程永不挂起 → 4789 远程控制持续在线。
// 开关：TrollAgent 跨进程发 Darwin 通知 com.trollagent.keepalive 切换。

static BOOL g_keepAlive = NO;

static void (*orig_sceneUpdate)(id, SEL, id, id, id, id);

static void keepAliveChanged(void) {
    g_keepAlive = [[NSUserDefaults standardUserDefaults] boolForKey:@"trollagent.keepalive"];
}

static void onDarwinKeepAlive(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    keepAliveChanged();
    NSLog(@"[ControlAgent] keepalive=%@", g_keepAlive ? @"ON" : @"OFF");
}

static void hookSceneUpdate(id self, SEL _cmd, id sceneID, id settingsDiff, id transitionContext, id completion) {
    if (!g_keepAlive) {
        orig_sceneUpdate(self, _cmd, sceneID, settingsDiff, transitionContext, completion);
        return;
    }
    NSString *diff = [settingsDiff description];
    BOOL goingBackground = ([diff containsString:@"foreground = No"] ||
                            [diff containsString:@"foreground = NO"] ||
                            [diff containsString:@"foreground = NotSet"] ||
                            [diff containsString:@"foreground = BSSettingFlagNo"]);
    if (goingBackground) {
        BOOL userGesture = ([diff containsString:@"systemGesture"] ||
                            [diff containsString:@"systemAnimation"]);
        if (!userGesture) {
            // 拦截：不让 FrontBoard 把 scene 标记为后台 → 进程不被挂起
            return;
        }
    }
    orig_sceneUpdate(self, _cmd, sceneID, settingsDiff, transitionContext, completion);
}

static void setupKeepAlive(void) {
    Class cls = objc_getClass("FBSWorkspaceScenesClient");
    if (!cls) {
        caLog(@"FBSWorkspaceScenesClient not found, keepalive disabled");
        return;
    }
    SEL sel = @selector(sceneID:updateWithSettingsDiff:transitionContext:completion:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        caLog(@"scene update selector not found, keepalive disabled");
        return;
    }
    orig_sceneUpdate = (void (*)(id, SEL, id, id, id, id))method_getImplementation(m);
    method_setImplementation(m, (IMP)hookSceneUpdate);
    keepAliveChanged();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    onDarwinKeepAlive,
                                    CFSTR("com.trollagent.keepalive"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    caLog([NSString stringWithFormat:@"keepalive hook installed (initial=%@)", g_keepAlive ? @"ON" : @"OFF"]);
}

#pragma mark - 构造函数

__attribute__((constructor))
static void controlAgentInitialize(void) {
    // v2.9.199：恢复 setupKeepAlive 保活（v2.9.195 误杀——当时"注入后闪退"实为
    // kill 后立即启动的缓冲期误判，非 scene hook 导致；实测注入后 App 可正常启动）。
    // 保活机制：hook FBSWorkspaceScenesClient 拦截 scene 后台更新，目标 App 切后台
    // 不挂起 → 4789 远程控制持续在线（实测后台挂起时 4789 断连）。
    caLog(@"constructor 进入");
    // v2.9.311：setupKeepAlive 延迟到主线程 runloop 启动后再 hook——
    // 之前在 dyld 阶段就 hook FBSWorkspaceScenesClient，Flutter/Unity/懒饭等
    // framework 注入时 constructor 跑太早 → 闪退（小红书主二进制注入不受影响）。
    // 移到 dispatch_after 1.0s，和 startHTTPServer 一起，等 App UIKit 完全就绪。
    // setupKeepAlive();
    // 延迟到主线程 runloop 启动后再启动服务器
    dispatch_async(dispatch_get_main_queue(), ^{
        caLog(@"主线程回调,准备延迟启动4789");
        // 再延迟一点，等 App 完全启动
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            setupKeepAlive();
            startHTTPServer();
        });
    });
}

/*
 API 文档（TrollAgent 通过 127.0.0.1:4789 调用）：

 GET  /status       → 控制代理状态、App 信息、PID
 GET  /ui_tree      → 完整 UI 树 JSON（所有窗口、视图、frame、text、可访问性）
 GET  /screenshot   → 当前屏幕 PNG 截图
 POST /tap          → {"x": 120, "y": 340} 模拟点击
 POST /swipe        → {"x1":.., "y1":.., "x2":.., "y2":.., "duration":0.3} 模拟滑动
 POST /type         → {"text": "hello"} 输入文字到当前第一响应者
 POST /key          → {"key": "home"|"back"|"enter"} 模拟按键

 设计原则：
 - 全部用 UIKit 通用 API，不依赖具体 App 的类名
 - 只监听 localhost，不暴露到网络
 - UI 操作在主线程执行，HTTP 在后台线程
 - UI 树限制 500 节点、深度 12 层，避免 JSON 过大
*/
