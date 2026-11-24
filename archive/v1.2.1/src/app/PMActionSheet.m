#import "PMActionSheet.h"
#import "PMHelperClient.h"
#import "PMTheme.h"
#import "PMToast.h"

// ---------------------------------------------------------------------------
// 一个可达的按钮模型
// ---------------------------------------------------------------------------
@interface PMActionItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic, strong) UIColor *tint;
@property (nonatomic, assign) BOOL destructive;
@property (nonatomic, copy) void (^handler)(void);
+ (instancetype)item:(NSString *)title symbol:(NSString *)symbol tint:(UIColor *)tint
         destructive:(BOOL)destructive handler:(void (^)(void))handler;
@end

@implementation PMActionItem
+ (instancetype)item:(NSString *)title symbol:(NSString *)symbol tint:(UIColor *)tint
         destructive:(BOOL)destructive handler:(void (^)(void))handler {
    PMActionItem *i = [PMActionItem new];
    i.title = title;
    i.symbol = symbol;
    i.tint = tint ?: [PMTheme accent];
    i.destructive = destructive;
    i.handler = handler;
    return i;
}
@end

// ---------------------------------------------------------------------------
// 按钮视图
// ---------------------------------------------------------------------------
@interface PMActionButton : UIControl
@property (nonatomic, strong) UIView *iconBox;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) PMActionItem *item;
- (void)setBusy:(BOOL)busy;
@end

@implementation PMActionButton

- (instancetype)initWithItem:(PMActionItem *)item {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _item = item;
    self.translatesAutoresizingMaskIntoConstraints = NO;

    _iconBox = [UIView new];
    _iconBox.translatesAutoresizingMaskIntoConstraints = NO;
    _iconBox.layer.cornerRadius = 15;
    _iconBox.layer.cornerCurve = kCACornerCurveContinuous;
    _iconBox.userInteractionEnabled = NO;
    _iconBox.backgroundColor = [item.tint colorWithAlphaComponent:0.14];
    [self addSubview:_iconBox];

    _iconView = [UIImageView new];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.tintColor = item.tint;
    _iconView.image = [UIImage systemImageNamed:item.symbol];
    [_iconBox addSubview:_iconView];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.hidesWhenStopped = YES;
    [self addSubview:_spinner];

    _titleLabel = [UILabel new];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.text = item.title;
    _titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.numberOfLines = 2;
    _titleLabel.textColor = item.destructive ? [PMTheme danger] : [UIColor labelColor];
    [self addSubview:_titleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_iconBox.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_iconBox.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_iconBox.widthAnchor constraintEqualToConstant:54],
        [_iconBox.heightAnchor constraintEqualToConstant:54],

        [_iconView.centerXAnchor constraintEqualToAnchor:_iconBox.centerXAnchor],
        [_iconView.centerYAnchor constraintEqualToAnchor:_iconBox.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:26],
        [_iconView.heightAnchor constraintEqualToConstant:26],

        [_spinner.centerXAnchor constraintEqualToAnchor:_iconBox.centerXAnchor],
        [_spinner.centerYAnchor constraintEqualToAnchor:_iconBox.centerYAnchor],

        [_titleLabel.topAnchor constraintEqualToAnchor:_iconBox.bottomAnchor constant:7],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-2],
        [_titleLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    return self;
}

- (void)setBusy:(BOOL)busy {
    self.userInteractionEnabled = !busy;
    self.alpha = busy ? 0.6 : 1.0;
    if (busy) {
        [_spinner startAnimating];
        _iconView.hidden = YES;
    } else {
        [_spinner stopAnimating];
        _iconView.hidden = NO;
    }
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.12 animations:^{
        self.iconBox.transform = highlighted ? CGAffineTransformMakeScale(0.92, 0.92) : CGAffineTransformIdentity;
        self.alpha = highlighted ? 0.75 : 1.0;
    }];
}

@end

// ---------------------------------------------------------------------------
// 底部面板控制器
// ---------------------------------------------------------------------------
#define PM_MAX_COLUMNS 3

@interface PMSheetController : UIViewController
@property (nonatomic, copy) NSString *headerTitle;
@property (nonatomic, copy) NSString *headerSubtitle;
@property (nonatomic, strong) UIColor *headerColor;
@property (nonatomic, strong) NSString *headerInitial;
@property (nonatomic, copy) NSArray<PMActionItem *> *items;
@property (nonatomic, copy, nullable) void (^onDismiss)(void);
@end

@implementation PMSheetController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];

    // 顶部 grabber
    UIView *grabber = [UIView new];
    grabber.translatesAutoresizingMaskIntoConstraints = NO;
    grabber.backgroundColor = [UIColor tertiaryLabelColor];
    grabber.layer.cornerRadius = 2.5;
    [self.view addSubview:grabber];

    // 头部
    UIView *badge = [UIView new];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.backgroundColor = self.headerColor;
    badge.layer.cornerRadius = 11;
    badge.layer.cornerCurve = kCACornerCurveContinuous;
    [self.view addSubview:badge];

    UILabel *initial = [UILabel new];
    initial.translatesAutoresizingMaskIntoConstraints = NO;
    initial.text = self.headerInitial;
    initial.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    initial.textColor = [UIColor whiteColor];
    initial.textAlignment = NSTextAlignmentCenter;
    [badge addSubview:initial];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = self.headerTitle;
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.numberOfLines = 1;
    title.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.view addSubview:title];

    UILabel *subtitle = [UILabel new];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = self.headerSubtitle;
    subtitle.font = [UIFont systemFontOfSize:12.5];
    subtitle.textColor = [PMTheme secondaryText];
    subtitle.numberOfLines = 2;
    [self.view addSubview:subtitle];

    // 按钮网格
    UIStackView *grid = [[UIStackView alloc] init];
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    grid.axis = UILayoutConstraintAxisVertical;
    grid.spacing = 18;
    grid.alignment = UIStackViewAlignmentFill;
    [self.view addSubview:grid];

    NSMutableArray<PMActionButton *> *buttons = [NSMutableArray array];
    NSUInteger idx = 0;
    while (idx < self.items.count) {
        NSMutableArray<PMActionButton *> *row = [NSMutableArray array];
        for (int col = 0; col < PM_MAX_COLUMNS; col++) {
            if (idx >= self.items.count) break;
            PMActionButton *b = [[PMActionButton alloc] initWithItem:self.items[idx]];
            [b addTarget:self action:@selector(buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
            [row addObject:b];
            [buttons addObject:b];
            idx++;
        }
        UIStackView *rowStack = [[UIStackView alloc] initWithArrangedSubviews:row];
        rowStack.axis = UILayoutConstraintAxisHorizontal;
        rowStack.distribution = UIStackViewDistributionFillEqually;
        rowStack.spacing = 8;
        [grid addArrangedSubview:rowStack];
    }

    // 关闭条
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [close addTarget:self action:@selector(dismissSelf) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [grabber.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8],
        [grabber.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [grabber.widthAnchor constraintEqualToConstant:36],
        [grabber.heightAnchor constraintEqualToConstant:5],

        [badge.topAnchor constraintEqualToAnchor:grabber.bottomAnchor constant:20],
        [badge.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [badge.widthAnchor constraintEqualToConstant:40],
        [badge.heightAnchor constraintEqualToConstant:40],

        [initial.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
        [initial.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],

        [title.leadingAnchor constraintEqualToAnchor:badge.trailingAnchor constant:12],
        [title.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [title.topAnchor constraintEqualToAnchor:badge.topAnchor],

        [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [subtitle.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],

        [grid.topAnchor constraintEqualToAnchor:badge.bottomAnchor constant:22],
        [grid.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [grid.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

        [close.topAnchor constraintEqualToAnchor:grid.bottomAnchor constant:20],
        [close.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [close.heightAnchor constraintEqualToConstant:44],
        [close.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
    ]];

    // 下滑关闭
    UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(dismissSelf)];
    swipe.direction = UISwipeGestureRecognizerDirectionDown;
    [self.view addGestureRecognizer:swipe];
}

- (void)buttonTapped:(PMActionButton *)sender {
    if (!sender.item.handler) return;
    [sender setBusy:YES];
    __weak typeof(self) weakSelf = self;
    sender.item.handler();
    // 操作是异步的；给 1.2 秒反馈后恢复，避免用户重复点
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [sender setBusy:NO];
        (void)weakSelf;
    });
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.onDismiss) self.onDismiss();
    }];
}

@end

// ---------------------------------------------------------------------------
// 自定义弹出（底部升起，圆角，自适应高度）
// ---------------------------------------------------------------------------
@interface PMSheetPresentation : UIPresentationController
@property (nonatomic, strong) UIView *dimming;
@end

@implementation PMSheetPresentation

- (void)presentationTransitionWillBegin {
    UIView *container = self.containerView;
    if (!container) return;
    _dimming = [[UIView alloc] initWithFrame:container.bounds];
    _dimming.backgroundColor = [UIColor colorWithWhite:0 alpha:0.42];
    _dimming.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _dimming.alpha = 0;
    [container addSubview:_dimming];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dimmingTapped)];
    [_dimming addGestureRecognizer:tap];

    [self.presentedViewController.transitionCoordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
        self.dimming.alpha = 1;
    } completion:nil];
}

- (void)containerViewWillLayoutSubviews {
    [super containerViewWillLayoutSubviews];
    CGRect bounds = self.containerView.bounds;
    CGFloat height = [self.presentedViewController preferredContentSize].height;
    if (height <= 0) height = bounds.size.height * 0.55;
    self.presentedView.frame = CGRectMake(0, bounds.size.height - height, bounds.size.width, height);
    self.presentedView.layer.cornerRadius = 22;
    self.presentedView.layer.cornerCurve = kCACornerCurveContinuous;
    self.presentedView.layer.masksToBounds = YES;
}

- (CGRect)frameOfPresentedViewInContainerView {
    CGRect bounds = self.containerView.bounds;
    CGFloat height = [self.presentedViewController preferredContentSize].height;
    if (height <= 0) height = bounds.size.height * 0.55;
    return CGRectMake(0, bounds.size.height - height, bounds.size.width, height);
}

- (void)dimmingTapped {
    [self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

@end

@interface PMSheetTransition : NSObject <UIViewControllerAnimatedTransitioning>
@property (nonatomic, assign) BOOL presenting;
@end

@implementation PMSheetTransition
- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning>)ctx { return 0.32; }
- (void)animateTransition:(id<UIViewControllerContextTransitioning>)ctx {
    UIView *container = [ctx containerView];
    if (self.presenting) {
        UIView *to = [ctx viewForKey:UITransitionContextToViewKey];
        CGRect final = [ctx finalFrameForViewController:[ctx viewControllerForKey:UITransitionContextToViewControllerKey]];
        to.frame = CGRectOffset(final, 0, final.size.height);
        [container addSubview:to];
        [UIView animateWithDuration:0.34 delay:0 usingSpringWithDamping:0.88 initialSpringVelocity:0.4
                            options:UIViewAnimationOptionCurveEaseOut animations:^{
            to.frame = final;
        } completion:^(BOOL done) {
            [ctx completeTransition:done];
        }];
    } else {
        UIView *from = [ctx viewForKey:UITransitionContextFromViewKey];
        [UIView animateWithDuration:0.24 animations:^{
            from.frame = CGRectOffset(from.frame, 0, from.frame.size.height);
        } completion:^(BOOL done) {
            [ctx completeTransition:done];
        }];
    }
}
@end

@interface PMSheetDelegate : NSObject <UIViewControllerTransitioningDelegate>
@end

@implementation PMSheetDelegate
- (UIPresentationController *)presentationControllerForPresentedViewController:(UIViewController *)presented
                                                      presentingViewController:(UIViewController *)presenting
                                                          sourceViewController:(UIViewController *)source {
    return [[PMSheetPresentation alloc] initWithPresentedViewController:presented presentingViewController:presenting];
}
- (id<UIViewControllerAnimatedTransitioning>)animationControllerForPresentedController:(UIViewController *)presented
                                                                  presentingController:(UIViewController *)presenting
                                                                      sourceController:(UIViewController *)source {
    PMSheetTransition *t = [PMSheetTransition new];
    t.presenting = YES;
    return t;
}
- (id<UIViewControllerAnimatedTransitioning>)animationControllerForDismissedController:(UIViewController *)dismissed {
    PMSheetTransition *t = [PMSheetTransition new];
    t.presenting = NO;
    return t;
}
@end

// 保持 delegate 存活
static NSMutableArray<PMSheetDelegate *> *gSheetDelegates = nil;

// ---------------------------------------------------------------------------
// 对外
// ---------------------------------------------------------------------------
@implementation PMActionSheet

+ (void)presentController:(PMSheetController *)vc from:(UIViewController *)host {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gSheetDelegates = [NSMutableArray array]; });

    PMSheetDelegate *delegate = [PMSheetDelegate new];
    [gSheetDelegates addObject:delegate];
    vc.modalPresentationStyle = UIModalPresentationCustom;
    vc.transitioningDelegate = delegate;

    // 预估高度：头部 ~100 + 每行 ~92 + 关闭条 64
    NSUInteger rows = (vc.items.count + PM_MAX_COLUMNS - 1) / PM_MAX_COLUMNS;
    CGFloat height = 110 + rows * 92 + 20 + 64;
    CGFloat maxHeight = host.view.bounds.size.height * 0.82;
    vc.preferredContentSize = CGSizeMake(host.view.bounds.size.width, MIN(height, maxHeight));

    [host presentViewController:vc animated:YES completion:nil];
}

+ (PMActionItem *)shareItemForPaths:(NSArray<NSString *> *)paths {

    return [PMActionItem item:@"分享" symbol:@"square.and.arrow.up"
                         tint:[PMTheme accent] destructive:NO
                      handler:^{
        NSMutableArray *urls = [NSMutableArray array];
        for (NSString *p in paths) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
                [urls addObject:[NSURL fileURLWithPath:p]];
            }
        }
        if (urls.count == 0) return;
        UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:urls applicationActivities:nil];
        UIViewController *top = [PMActionSheet topViewController];
        av.popoverPresentationController.sourceView = top.view;
        av.popoverPresentationController.sourceRect = CGRectMake(top.view.bounds.size.width / 2,
                                                                  top.view.bounds.size.height - 60, 1, 1);
        [top presentViewController:av animated:YES completion:nil];
    }];
}

+ (UIViewController *)topViewController {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) { window = w; break; }
        }
        if (window) break;
    }
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

+ (void)presentForPlugin:(PMPluginItem *)item
                    from:(UIViewController *)host
               onRefresh:(void (^)(void))onRefresh {
    PMSheetController *vc = [PMSheetController new];
    vc.headerTitle = item.identifier;
    vc.headerSubtitle = [item subtitleText];
    vc.headerColor = [PMTheme colorForIdentifier:item.identifier];
    vc.headerInitial = [PMTheme initialForIdentifier:item.identifier];

    NSMutableArray<PMActionItem *> *items = [NSMutableArray array];
    __weak typeof(host) weakHost = host;

    // 分享 dylib + plist
    [items addObject:[PMActionItem item:@"分享" symbol:@"square.and.arrow.up"
                                   tint:[PMTheme accent] destructive:NO handler:^{
        [[PMHelperClient sharedClient] resolvePluginPaths:item.identifier completion:^(NSArray<NSString *> *paths, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (paths.count == 0) {
                    [PMToast show:[PMHelperClient messageForError:err] inView:weakHost.view style:2];
                    return;
                }
                [PMActionSheet sharePaths:paths];
            });
        }];
    }]];

    // 提取 dylib 到沙盒
    [items addObject:[PMActionItem item:@"提取 dylib" symbol:@"arrow.down.doc"
                                   tint:[PMTheme ok] destructive:NO handler:^{
        [[PMHelperClient sharedClient] extractPlugin:item.identifier kind:@"both" completion:^(NSDictionary *result, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!result) {
                    [PMToast show:[PMHelperClient messageForError:err] inView:weakHost.view style:2];
                    return;
                }
                NSString *dest = result[@"dest"] ?: @"Documents/PluginManager";
                [PMToast show:[NSString stringWithFormat:@"已提取到 %@", dest.lastPathComponent]
                       inView:weakHost.view style:1];
            });
        }];
    }]];

    // 解析包信息
    [items addObject:[PMActionItem item:@"包信息" symbol:@"doc.text.magnifyingglass"
                                   tint:[PMTheme warn] destructive:NO handler:^{
        [[PMHelperClient sharedClient] pluginInfo:item.identifier completion:^(NSDictionary *info, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!info) {
                    [PMToast show:[PMHelperClient messageForError:err] inView:weakHost.view style:2];
                    return;
                }
                NSString *text = [PMActionSheet describePluginInfo:info];
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:item.identifier
                                                                              message:text
                                                                       preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
                [[PMActionSheet topViewController] presentViewController:alert animated:YES completion:nil];
            });
        }];
    }]];

    // 备份
    [items addObject:[PMActionItem item:@"备份" symbol:@"archivebox"
                                   tint:[PMTheme accent] destructive:NO handler:^{
        [[PMHelperClient sharedClient] backupPlugin:item.identifier completion:^(NSDictionary *result, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!result) {
                    [PMToast show:[PMHelperClient messageForError:err] inView:weakHost.view style:2];
                    return;
                }
                [PMToast show:[NSString stringWithFormat:@"已备份 %@", result[@"file"] ?: @""]
                       inView:weakHost.view style:1];
                if (onRefresh) onRefresh();
            });
        }];
    }]];

    // 改名
    [items addObject:[PMActionItem item:@"改名" symbol:@"pencil"
                                   tint:[PMTheme accent] destructive:NO handler:^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名插件"
                                                                      message:[NSString stringWithFormat:@"当前：%@", item.identifier]
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"新名称";
            tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"改名" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            NSString *newName = alert.textFields.firstObject.text ?: @"";
            if (newName.length == 0) return;
            [[PMHelperClient sharedClient] renamePlugin:item.identifier to:newName completion:^(NSDictionary *result, NSError *err) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!result) {
                        [PMToast show:[PMHelperClient messageForError:err] inView:weakHost.view style:2];
                        return;
                    }
                    [PMToast show:[NSString stringWithFormat:@"已改名为 %@", newName] inView:weakHost.view style:1];
                    if (onRefresh) onRefresh();
                });
            }];
        }]];
        [[PMActionSheet topViewController] presentViewController:alert animated:YES completion:nil];
    }]];

    // 停用
    if (item.enabled) {
        [items addObject:[PMActionItem item:@"停用" symbol:@"nosign"
                                       tint:[PMTheme danger] destructive:YES handler:^{
            [[PMHelperClient sharedClient] setPlugin:item.identifier enabled:NO error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                [PMToast show:@"已停用，注销后生效" inView:weakHost.view style:1];
                if (onRefresh) onRefresh();
            });
        }]];
    } else {
        [items addObject:[PMActionItem item:@"启用" symbol:@"checkmark.circle"
                                       tint:[PMTheme ok] destructive:NO handler:^{
            [[PMHelperClient sharedClient] setPlugin:item.identifier enabled:YES error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                [PMToast show:@"已启用，注销后生效" inView:weakHost.view style:1];
                if (onRefresh) onRefresh();
            });
        }]];
    }

    vc.items = items;
    [self presentController:vc from:host];
}

+ (void)presentForDebAtPath:(NSString *)path
                       from:(UIViewController *)host
                  onRefresh:(void (^)(void))onRefresh {
    PMSheetController *vc = [PMSheetController new];
    vc.headerTitle = path.lastPathComponent;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    unsigned long long size = [attrs fileSize];
    vc.headerSubtitle = [NSString stringWithFormat:@"%.1f KB", size / 1024.0];
    vc.headerColor = [PMTheme accent];
    vc.headerInitial = @"D";

    NSMutableArray<PMActionItem *> *items = [NSMutableArray array];
    __weak typeof(host) weakHost = host;

    [items addObject:[PMActionItem item:@"解压 deb" symbol:@"archivebox.circle" tint:[PMTheme ok] destructive:NO handler:^{
        [[PMHelperClient sharedClient] debugExtractDeb:path dylibsOnly:NO completion:^(NSDictionary *r, NSError *e) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!r) { [PMToast show:[PMHelperClient messageForError:e] inView:weakHost.view style:2]; return; }
                [PMToast show:[NSString stringWithFormat:@"解出 %@ 个文件", r[@"extracted"] ?: @0]
                       inView:weakHost.view style:1];
                if (onRefresh) onRefresh();
            });
        }];
    }]];

    [items addObject:[PMActionItem item:@"提取 dylib" symbol:@"arrow.down.doc" tint:[PMTheme accent] destructive:NO handler:^{
        [[PMHelperClient sharedClient] debugExtractDeb:path dylibsOnly:YES completion:^(NSDictionary *r, NSError *e) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!r) { [PMToast show:[PMHelperClient messageForError:e] inView:weakHost.view style:2]; return; }
                [PMToast show:[NSString stringWithFormat:@"提取 %@ 个插件文件", r[@"extracted"] ?: @0]
                       inView:weakHost.view style:1];
                if (onRefresh) onRefresh();
            });
        }];
    }]];

    [items addObject:[PMActionItem item:@"包信息" symbol:@"doc.text.magnifyingglass" tint:[PMTheme warn] destructive:NO handler:^{
        [[PMHelperClient sharedClient] debInfo:path completion:^(NSDictionary *info, NSError *e) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!info) { [PMToast show:[PMHelperClient messageForError:e] inView:weakHost.view style:2]; return; }
                UIAlertController *a = [UIAlertController alertControllerWithTitle:path.lastPathComponent
                                                                          message:[PMActionSheet describeDebInfo:info]
                                                                   preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
                [[PMActionSheet topViewController] presentViewController:a animated:YES completion:nil];
            });
        }];
    }]];

    [items addObject:[PMActionItem item:@"分享" symbol:@"square.and.arrow.up" tint:[PMTheme accent] destructive:NO handler:^{
        [PMActionSheet sharePaths:@[path]];
    }]];

    [items addObject:[PMActionItem item:@"删除副本" symbol:@"trash" tint:[PMTheme danger] destructive:YES handler:^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"删除这个文件？"
                                                                  message:path.lastPathComponent
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
            if (onRefresh) onRefresh();
        }]];
        [[PMActionSheet topViewController] presentViewController:a animated:YES completion:nil];
    }]];

    vc.items = items;
    [self presentController:vc from:host];
}

+ (void)sharePaths:(NSArray<NSString *> *)paths {
    NSMutableArray *urls = [NSMutableArray array];
    for (NSString *p in paths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) [urls addObject:[NSURL fileURLWithPath:p]];
    }
    if (urls.count == 0) return;
    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:urls applicationActivities:nil];
    UIViewController *top = [self topViewController];
    av.popoverPresentationController.sourceView = top.view;
    av.popoverPresentationController.sourceRect = CGRectMake(top.view.bounds.size.width / 2,
                                                              top.view.bounds.size.height - 60, 1, 1);
    [top presentViewController:av animated:YES completion:nil];
}

+ (NSString *)describePluginInfo:(NSDictionary *)info {
    NSMutableArray *lines = [NSMutableArray array];
    if (info[@"dylib"]) [lines addObject:[@"dylib：" stringByAppendingString:info[@"dylib"]]];
    if (info[@"plist"]) [lines addObject:[@"plist：" stringByAppendingString:info[@"plist"]]];
    if (info[@"package"]) [lines addObject:[@"软件包：" stringByAppendingString:info[@"package"]]];
    if (info[@"bytes"]) [lines addObject:[NSString stringWithFormat:@"大小：%.1f KB", [info[@"bytes"] doubleValue] / 1024.0]];
    return [lines componentsJoinedByString:@"\n"];
}

+ (NSString *)describeDebInfo:(NSDictionary *)info {
    NSMutableArray *lines = [NSMutableArray array];
    if (info[@"package"]) [lines addObject:[@"包标识：" stringByAppendingString:info[@"package"]]];
    if (info[@"version"]) [lines addObject:[@"版本：" stringByAppendingString:info[@"version"]]];
    if (info[@"arch"]) [lines addObject:[@"架构：" stringByAppendingString:info[@"arch"]]];
    if (info[@"files"]) [lines addObject:[NSString stringWithFormat:@"文件数：%@", info[@"files"]]];
    if (info[@"members"]) [lines addObject:[@"成员：" stringByAppendingString:[(NSArray *)info[@"members"] componentsJoinedByString:@", "]]];
    return [lines componentsJoinedByString:@"\n"];
}

@end
