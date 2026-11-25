#import "PMAppDelegate.h"
#import "PMListViewController.h"
#import "PMTheme.h"

// 把未捕获异常写到磁盘，方便事后定位启动闪退
static void PMUncaughtExceptionHandler(NSException *exception) {
    @try {
        NSMutableString *text = [NSMutableString string];
        [text appendFormat:@"time: %@\n", [NSDate date]];
        [text appendFormat:@"name: %@\n", exception.name ?: @"?"];
        [text appendFormat:@"reason: %@\n", exception.reason ?: @"?"];
        [text appendString:@"callStack:\n"];
        for (NSNumber *addr in exception.callStackReturnAddresses) {
            [text appendFormat:@"  0x%llx\n", addr.unsignedLongLongValue];
        }
        [text appendString:@"symbols:\n"];
        for (NSString *line in exception.callStackSymbols) {
            [text appendFormat:@"  %@\n", line];
        }
        [text appendString:@"\n"];

        NSString *dir = @"/var/mobile/Library/Logs";
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        }
        NSString *path = [dir stringByAppendingPathComponent:@"PluginManager-crash.log"];
        NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
        if ([fm fileExistsAtPath:path]) {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            [fh seekToEndOfFile];
            [fh writeData:data];
            [fh closeFile];
        } else {
            [data writeToFile:path atomically:YES];
        }
    } @catch (NSException *inner) {
        (void)inner;
    }
}

@implementation PMAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSSetUncaughtExceptionHandler(&PMUncaughtExceptionHandler);

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];

    // 根控制器构造若出问题，兜底成一个纯色页面，至少不闪退
    UIViewController *root = nil;
    @try {
        root = [PMListViewController new];
    } @catch (NSException *ex) {
        UILabel *label = [UILabel new];
        label.numberOfLines = 0;
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont systemFontOfSize:14];
        label.text = [NSString stringWithFormat:@"初始化失败\n%@\n%@",
                      ex.name ?: @"", ex.reason ?: @""];
        UIViewController *fallback = [UIViewController new];
        fallback.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
        label.frame = fallback.view.bounds;
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [fallback.view addSubview:label];
        root = fallback;
    }

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];

    @try {
        UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
        [appearance configureWithDefaultBackground];
        appearance.backgroundColor = [UIColor systemGroupedBackgroundColor];
        nav.navigationBar.standardAppearance = appearance;
        nav.navigationBar.scrollEdgeAppearance = appearance;
        nav.navigationBar.compactAppearance = appearance;
    } @catch (NSException *ex) {
        (void)ex;
    }

    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
