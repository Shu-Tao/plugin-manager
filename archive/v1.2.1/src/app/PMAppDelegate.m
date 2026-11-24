#import "PMAppDelegate.h"
#import "PMListViewController.h"
#import "PMTheme.h"

@implementation PMAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];

    PMListViewController *root = [PMListViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];

    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithDefaultBackground];
    appearance.backgroundColor = [UIColor systemGroupedBackgroundColor];
    nav.navigationBar.standardAppearance = appearance;
    nav.navigationBar.scrollEdgeAppearance = appearance;
    nav.navigationBar.compactAppearance = appearance;

    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
