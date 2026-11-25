#import "PMActionSheet.h"
#import "PMTheme.h"

// 说明：本文件已按 2.0.0 精简。
// 移除了分享 / 提取 / 备份 / 改名 / deb / zip / 文件管理相关逻辑。
//
// 移除的直接原因：崩溃报告显示 CUIShapeEffectStack sharedCIContext 在
// render SF Symbol 时初始化 GLContext 失败，随后跳转到地址 0 触发 SIGSEGV。
// 其中 UIActivityViewController（分享）是主要触发点之一。
// 现在整个 App 不再使用任何 SF Symbol 或系统图标组件。

@implementation PMActionSheet

+ (void)presentForPlugin:(PMPluginItem *)item from:(UIViewController *)host {
    if (!item) return;
    UIViewController *base = host;
    if (!base) return;

    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"标识：%@\n", item.identifier ?: @"-"];
    [text appendFormat:@"用途：%@\n", [item subtitleText] ?: @"-"];
    if (item.package.length) {
        [text appendFormat:@"软件包：%@\n", item.package];
    }
    NSString *dylib = [item dylibName];
    if (dylib.length) {
        [text appendFormat:@"dylib：%@\n", dylib];
    }
    NSString *plist = [item plistName];
    if (plist.length) {
        [text appendFormat:@"plist：%@\n", plist];
    }
    [text appendFormat:@"状态：%@", item.enabled ? @"已开启" : @"已停用"];

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:item.identifier
                                            message:text
                                     preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(base) weakBase = base;
    [alert addAction:[UIAlertAction actionWithTitle:@"复制标识"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = item.identifier ?: @"";
        (void)weakBase;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [self presentAlert:alert from:base];
}

+ (void)presentAlert:(UIAlertController *)alert from:(UIViewController *)host {
    UIViewController *base = host;
    if (!base) base = [self topViewController];
    if (!base) return;

    // 若 base 自身正在 present 别的东西，退到它的 presenting
    while (base.presentedViewController) {
        base = base.presentingViewController ?: base;
        break;
    }
    [base presentViewController:alert animated:YES completion:nil];
}

+ (UIViewController *)topViewController {
    UIWindow *window = nil;

    // 1) Scene API。只有 Info.plist 配了 UIApplicationSceneManifest 时才有内容。
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { window = w; break; }
            }
            if (window) break;
        }
    }

    // 2) 回退到旧式 AppDelegate 窗口（本项目走这条）
    if (!window) {
        id<UIApplicationDelegate> del = UIApplication.sharedApplication.delegate;
        if ([del respondsToSelector:@selector(window)]) {
            window = [del window];
        }
    }

    // 3) 再回退
    if (!window) {
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.isKeyWindow) { window = w; break; }
        }
    }

    // 4) 最后兜底
    if (!window) {
        window = UIApplication.sharedApplication.windows.firstObject;
    }

    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

@end
