#import "PMActionSheet.h"
#import "PMHelperClient.h"
#import "PMTheme.h"
#import "PMToast.h"

/// 符号图标全局缓存：同一 symbol 只创建一次，避免每个按钮各建一份位图
/// （启动/渲染期反复创建位图会触发内存耗尽，见 1.2.3 修复说明）
static UIImage *PMSharedSymbol(NSString *name) {
    static NSMutableDictionary<NSString *, UIImage *> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    if (name.length == 0) return nil;
    UIImage *hit = cache[name];
    if (hit) return hit;
    UIImage *img = [UIImage systemImageNamed:name];
    if (img) cache[name] = img;
    return img;
}

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
    _iconView.image = PMSharedSymbol(item.symbol);
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

/// 分享时的文件包装：按扩展名给出合适的 UTI，让第三方分享扩展（QQ/微信）能识别
@interface PMShareItem : NSObject <UIActivityItemSource>
@property (nonatomic, strong) NSURL *url;
@end

@implementation PMShareItem

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) _url = [NSURL fileURLWithPath:path];
    return self;
}

- (id)activityViewControllerPlaceholderItem:(UIActivityViewController *)c {
    return self.url;
}

- (id)activityViewController:(UIActivityViewController *)c
         itemForActivityType:(UIActivityType)type {
    return self.url;
}

- (NSString *)activityViewController:(UIActivityViewController *)c
   dataTypeIdentifierForActivityType:(UIActivityType)type {
    NSString *ext = self.url.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"zip"]) return @"public.zip-archive";
    if ([ext isEqualToString:@"plist"]) return @"com.apple.property-list";
    // deb / dylib 等二进制统一用 public.item：比 public.data 更通用，
    // 第三方扩展（QQ/微信）过滤时不容易把条目丢掉
    return @"public.item";
}

/// 第三方分享扩展（尤其 QQ）会调这个方法取缩略图。
/// 之前没实现，返回 nil 后部分版本会进入异常分支直接闪退。
- (UIImage *)activityViewController:(UIActivityViewController *)c
      thumbnailImageForActivityType:(UIActivityType)type
                      suggestedSize:(CGSize)size {
    // 返回 nil，系统会用该文件类型的默认图标。
    // 原来这里用 UIGraphicsImageRenderer 现场绘制，分享面板会为每个候选 App
    // 各请求一次缩略图（一屏 8 个就画 8 张位图），内存紧张时直接闪退。
    return nil;
}

/// subject 传文件名会让部分扩展把它当正文显示，改掉
- (NSString *)activityViewController:(UIActivityViewController *)c
              subjectForActivityType:(UIActivityType)type {
    return nil;
}

@end


#pragma mark - 提取选项面板（自绘，带真开关）

@interface PMExtractOptionsController : UIViewController
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *dylibName;
@property (nonatomic, copy) NSString *plistName;
@property (nonatomic, assign) BOOL debAvailable;
@property (nonatomic, copy) NSString *debSubtitle;
@property (nonatomic, copy) void (^onConfirm)(BOOL dylib, BOOL plist, BOOL deb);
@end

@implementation PMExtractOptionsController {
    UISwitch *_dylibSwitch;
    UISwitch *_plistSwitch;
    UISwitch *_debSwitch;
    UIButton *_confirmButton;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];

    BOOL hasDylib = self.dylibName.length > 0;
    BOOL hasPlist = self.plistName.length > 0;
    BOOL hasDeb = self.debAvailable;

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"选择要提取的文件";
    title.font = [UIFont systemFontOfSize:16.5 weight:UIFontWeightSemibold];
    title.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:title];

    UISwitch *s1 = nil, *s2 = nil, *s3 = nil;
    UIView *row1 = [self makeRowWithTitle:(hasDylib ? self.dylibName : @"（没有 dylib）")
                                 subtitle:@"插件本体"
                                       on:hasDylib swOut:&s1];
    _dylibSwitch = s1;
    [self.view addSubview:row1];

    UIView *row2 = [self makeRowWithTitle:(hasPlist ? self.plistName : @"（没有 plist）")
                                 subtitle:@"过滤规则，可选"
                                       on:NO swOut:&s2];
    _plistSwitch = s2;
    [self.view addSubview:row2];

    NSString *debTitle = [NSString stringWithFormat:@"%@.deb", self.identifier];
    NSString *debSub = self.debSubtitle.length ? self.debSubtitle : @"可直接 Sileo 安装";
    UIView *row3 = [self makeRowWithTitle:debTitle subtitle:debSub on:NO swOut:&s3];
    _debSwitch = s3;
    [self.view addSubview:row3];

    _dylibSwitch.enabled = hasDylib;
    _plistSwitch.enabled = hasPlist;
    _debSwitch.enabled = hasDeb;
    _dylibSwitch.on = hasDylib;
    _plistSwitch.on = NO;
    _debSwitch.on = NO;

    [_dylibSwitch addTarget:self action:@selector(switchChanged) forControlEvents:UIControlEventValueChanged];
    [_plistSwitch addTarget:self action:@selector(switchChanged) forControlEvents:UIControlEventValueChanged];
    [_debSwitch addTarget:self action:@selector(switchChanged) forControlEvents:UIControlEventValueChanged];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.translatesAutoresizingMaskIntoConstraints = NO;
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [cancel addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:cancel];

    _confirmButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _confirmButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_confirmButton setTitle:@"提取" forState:UIControlStateNormal];
    _confirmButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [_confirmButton addTarget:self action:@selector(confirmTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_confirmButton];

    UILayoutGuide *m = self.view.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:18],
        [title.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [title.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],

        [row1.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:14],
        [row1.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [row1.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],

        [row2.topAnchor constraintEqualToAnchor:row1.bottomAnchor constant:8],
        [row2.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [row2.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],

        [row3.topAnchor constraintEqualToAnchor:row2.bottomAnchor constant:8],
        [row3.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [row3.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],

        [cancel.topAnchor constraintEqualToAnchor:row3.bottomAnchor constant:14],
        [cancel.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [cancel.heightAnchor constraintEqualToConstant:40],

        [_confirmButton.topAnchor constraintEqualToAnchor:cancel.topAnchor],
        [_confirmButton.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [_confirmButton.heightAnchor constraintEqualToConstant:40],

        [self.view.bottomAnchor constraintEqualToAnchor:cancel.bottomAnchor constant:12],
    ]];
    [self updateConfirmState];
}

- (UIView *)makeRowWithTitle:(NSString *)titleText
                    subtitle:(NSString *)subtitle
                          on:(BOOL)on
                       swOut:(UISwitch **)swOut {
    UIView *row = [UIView new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.backgroundColor = [UIColor tertiarySystemGroupedBackgroundColor];
    row.layer.cornerRadius = 10;
    row.layer.cornerCurve = kCACornerCurveContinuous;

    UILabel *l1 = [UILabel new];
    l1.translatesAutoresizingMaskIntoConstraints = NO;
    l1.text = titleText;
    l1.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    l1.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [row addSubview:l1];

    UILabel *l2 = [UILabel new];
    l2.translatesAutoresizingMaskIntoConstraints = NO;
    l2.text = subtitle;
    l2.font = [UIFont systemFontOfSize:11];
    l2.textColor = [PMTheme secondaryText];
    l2.numberOfLines = 2;
    [row addSubview:l2];

    UISwitch *sw = [UISwitch new];
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    sw.on = on;
    sw.onTintColor = [PMTheme ok];
    sw.transform = CGAffineTransformMakeScale(0.82, 0.82);
    [row addSubview:sw];

    [NSLayoutConstraint activateConstraints:@[
        [l1.topAnchor constraintEqualToAnchor:row.topAnchor constant:8],
        [l1.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12],
        [l1.trailingAnchor constraintEqualToAnchor:sw.leadingAnchor constant:-8],

        [l2.leadingAnchor constraintEqualToAnchor:l1.leadingAnchor],
        [l2.topAnchor constraintEqualToAnchor:l1.bottomAnchor constant:1],
        [l2.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-8],
        [l2.trailingAnchor constraintEqualToAnchor:l1.trailingAnchor],

        [sw.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-10],
        [sw.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];

    if (swOut) *swOut = sw;
    return row;
}

- (void)switchChanged { [self updateConfirmState]; }

- (void)updateConfirmState {
    BOOL any = _dylibSwitch.on || _plistSwitch.on || _debSwitch.on;
    _confirmButton.enabled = any;
    _confirmButton.alpha = any ? 1.0 : 0.4;
}

- (void)cancelTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)confirmTapped {
    BOOL d = _dylibSwitch.on;
    BOOL p = _plistSwitch.on;
    BOOL b = _debSwitch.on;
    if (!d && !p && !b) return;
    void (^cb)(BOOL, BOOL, BOOL) = self.onConfirm;
    [self dismissViewControllerAnimated:YES completion:^{
        if (cb) cb(d, p, b);
    }];
}

@end

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

    // 2) 回退到旧式 AppDelegate 窗口。
    //    本项目 Info.plist 没有 SceneManifest，实际走这条；
    //    此前只写 Scene API 导致 window 恒为 nil，搜索与分享全部失效。
    if (!window) {
        id<UIApplicationDelegate> del = UIApplication.sharedApplication.delegate;
        if ([del respondsToSelector:@selector(window)]) {
            window = [del window];
        }
    }

    // 3) 再回退：windows 列表里挑 key window
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

    // 提取：先弹对话框让用户勾选要提取什么，不默认带 plist
    [items addObject:[PMActionItem item:@"提取" symbol:@"arrow.down.doc"
                                   tint:[PMTheme ok] destructive:NO handler:^{
        [PMActionSheet presentExtractOptionsForPlugin:item];
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
    // 按扩展名分流：不同文件给不同操作，避免 .zip 上出现「解压 deb」
    NSString *ext = path.pathExtension.lowercaseString;
    BOOL isDeb = [ext isEqualToString:@"deb"];
    BOOL isZip = [ext isEqualToString:@"zip"];
    BOOL isPluginFile = [ext isEqualToString:@"dylib"] || [ext isEqualToString:@"plist"];

    PMSheetController *vc = [PMSheetController new];
    vc.headerTitle = path.lastPathComponent;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    unsigned long long size = [attrs fileSize];
    vc.headerSubtitle = [NSString stringWithFormat:@"%.1f KB", size / 1024.0];
    vc.headerColor = [PMTheme accent];
    vc.headerInitial = isDeb ? @"D" : (isZip ? @"Z" : @"F");

    NSMutableArray<PMActionItem *> *items = [NSMutableArray array];
    __weak typeof(host) weakHost = host;

    // ---- .deb 专属 ----
    if (isDeb) {
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
                    [PMActionSheet presentAlert:a from:weakHost];
                });
            }];
        }]];

        [items addObject:[PMActionItem item:@"提取到目录" symbol:@"tray.and.arrow.down"
                                       tint:[PMTheme ok] destructive:NO handler:^{
            [PMActionSheet extractDebFileToStore:path];
        }]];
    }

    // ---- .zip 专属 ----
    if (isZip) {
        [items addObject:[PMActionItem item:@"解压 zip" symbol:@"archivebox.circle" tint:[PMTheme ok] destructive:NO handler:^{
            [[PMHelperClient sharedClient] zipExtract:path completion:^(NSDictionary *r, NSError *e) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!r) { [PMToast show:[PMHelperClient messageForError:e] inView:weakHost.view style:2]; return; }
                    [PMToast show:[NSString stringWithFormat:@"解出 %@ 个文件", r[@"extracted"] ?: @0]
                           inView:weakHost.view style:1];
                    if (onRefresh) onRefresh();
                });
            }];
        }]];
    }

    // ---- .dylib / .plist：只给信息 ----
    if (isPluginFile) {
        [items addObject:[PMActionItem item:@"文件信息" symbol:@"info.circle" tint:[PMTheme warn] destructive:NO handler:^{
            NSMutableString *msg = [NSMutableString string];
            [msg appendFormat:@"路径：%@\n", path];
            [msg appendFormat:@"大小：%.1f KB\n", size / 1024.0];
            NSDate *d = attrs[NSFileModificationDate];
            if (d) {
                NSDateFormatter *f = [NSDateFormatter new];
                f.dateFormat = @"yyyy-MM-dd HH:mm";
                [msg appendFormat:@"修改：%@", [f stringFromDate:d]];
            }
            UIAlertController *a = [UIAlertController alertControllerWithTitle:path.lastPathComponent
                                                                      message:msg
                                                               preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [PMActionSheet presentAlert:a from:weakHost];
        }]];
    }

    // ---- 通用：分享 ----
    [items addObject:[PMActionItem item:@"分享" symbol:@"square.and.arrow.up" tint:[PMTheme accent] destructive:NO handler:^{
        [PMActionSheet sharePaths:@[path]];
    }]];

    // ---- 通用：打包成 zip 再分享（.deb 这类二进制直接分享容易被扩展拒绝）----
    if (isDeb || isPluginFile) {
        [items addObject:[PMActionItem item:@"打包分享" symbol:@"archivebox" tint:[PMTheme accent] destructive:NO handler:^{
            [[PMHelperClient sharedClient] zipPack:@[path] name:nil completion:^(NSDictionary *r, NSError *e) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!r) {
                        [PMToast show:[PMHelperClient messageForError:e] inView:weakHost.view style:2];
                        return;
                    }
                    NSString *zip = r[@"path"];
                    if (zip.length) [PMActionSheet sharePaths:@[zip]];
                });
            }];
        }]];
    }

    // ---- 通用：删除（走助手，root 执行；失败要能看到原因）----
    [items addObject:[PMActionItem item:@"删除" symbol:@"trash" tint:[PMTheme danger] destructive:YES handler:^{
        [PMActionSheet confirmDeletePath:path onRefresh:onRefresh];
    }]];

    vc.items = items;
    [self presentController:vc from:host];
}

/// 在指定控制器上弹 alert（不要用 topViewController，否则会被弹窗自己挡住）
+ (void)presentAlert:(UIAlertController *)alert from:(UIViewController *)host {
    UIViewController *base = host;
    if (!base) base = [PMActionSheet topViewController];
    // 若 base 自身正在 present 别的东西，退到它的 presenting
    while (base.presentedViewController) {
        base = base.presentingViewController ?: base;
        break;
    }
    [base presentViewController:alert animated:YES completion:nil];
}

/// 删除确认 + 执行。统一走助手 root 权限，避免 mobile 用户删不掉 root 文件
+ (void)confirmDeletePath:(NSString *)path onRefresh:(void (^)(void))onRefresh {
    UIViewController *host = [PMActionSheet topViewController];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除文件？"
                                                                  message:[NSString stringWithFormat:@"%@\n\n删除后不可恢复。", path.lastPathComponent]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [[PMHelperClient sharedClient] removeCopy:path completion:^(NSDictionary *r, NSError *e) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIViewController *t = [PMActionSheet topViewController];
                if (!r) {
                    NSString *reason = [PMHelperClient messageForError:e];
                    [PMToast show:(reason.length ? reason : @"删除失败") inView:t.view style:2];
                    return;
                }
                [PMToast show:@"已删除" inView:t.view style:1];
                if (onRefresh) onRefresh();
            });
        }];
    }]];
    [PMActionSheet presentAlert:alert from:host];
}

+ (void)sharePaths:(NSArray<NSString *> *)paths {
    NSMutableArray *shareItems = [NSMutableArray array];
    for (NSString *p in paths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
            [shareItems addObject:[[PMShareItem alloc] initWithPath:p]];
        }
    }
    if (shareItems.count == 0) return;

    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:shareItems
                                                                     applicationActivities:nil];

    // 明确声明可处理的数据类型，QQ / 微信等第三方扩展才会被系统列出
    av.excludedActivityTypes = nil;

    UIViewController *top = [self topViewController];
    av.popoverPresentationController.sourceView = top.view;
    av.popoverPresentationController.sourceRect = CGRectMake(top.view.bounds.size.width / 2,
                                                              top.view.bounds.size.height - 60, 1, 1);

    // iPad 上必须给 popover，否则崩溃
    av.popoverPresentationController.permittedArrowDirections = 0;

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


+ (void)presentExtractOptionsForPlugin:(PMPluginItem *)item {
    if (!item) return;
    UIViewController *top = [self topViewController];
    if (!top) return;

    // 先查 deb 可得性，再弹面板（避免用户勾了却发现拿不到）
    __weak typeof(top) weakTop = top;
    [[PMHelperClient sharedClient] debSourceForPlugin:item.identifier completion:^(NSDictionary *info, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *host = weakTop ?: [PMActionSheet topViewController];
            if (!host) return;

            BOOL available = [info[@"available"] boolValue];
            NSString *mode = info[@"mode"] ?: @"none";
            NSString *subtitle = @"可直接 Sileo 安装";
            if (!available) {
                subtitle = info[@"reason"] ?: @"当前无法获取 deb";
            } else if ([mode isEqualToString:@"repack"]) {
                subtitle = @"由已装文件重新打包（不含安装脚本）";
            } else if ([mode isEqualToString:@"cache"]) {
                subtitle = @"原始包，可直接安装";
            }

            PMExtractOptionsController *vc = [PMExtractOptionsController new];
            vc.identifier = item.identifier;
            vc.dylibName = item.dylibName;
            vc.plistName = item.plistName;
            vc.debAvailable = available;
            vc.debSubtitle = subtitle;
            vc.onConfirm = ^(BOOL dylib, BOOL plist, BOOL deb) {
                [PMActionSheet performExtractForPlugin:item dylib:dylib plist:plist deb:deb];
            };

            // 贴合内容：三行 76 + 标题 40 + 按钮 54 + 边距
            CGFloat height = 18 + 24 + 14 + 3 * 62 + 2 * 8 + 14 + 40 + 12;
            vc.modalPresentationStyle = UIModalPresentationCustom;
            vc.preferredContentSize = CGSizeMake(host.view.bounds.size.width, height);

            PMSheetDelegate *delegate = [PMActionSheet newSheetDelegate];
            vc.transitioningDelegate = delegate;
            [host presentViewController:vc animated:YES completion:nil];
        });
    }];
}

+ (PMSheetDelegate *)newSheetDelegate {
    static NSMutableArray<PMSheetDelegate *> *pool = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pool = [NSMutableArray array]; });
    PMSheetDelegate *d = [PMSheetDelegate new];
    [pool addObject:d];
    if (pool.count > 8) [pool removeObjectAtIndex:0];
    return d;
}

+ (void)performExtractForPlugin:(PMPluginItem *)item dylib:(BOOL)dylib plist:(BOOL)plist deb:(BOOL)deb {
    if (!dylib && !plist && !deb) return;

    NSString *kind = nil;
    if (deb && dylib && plist) kind = @"all";
    else if (deb && dylib) kind = @"both";
    else if (deb && plist) kind = @"both";
    else if (deb) kind = @"deb";
    else if (dylib && plist) kind = @"both";
    else if (dylib) kind = @"dylib";
    else kind = @"plist";

    UIViewController *top = [self topViewController];
    [[PMHelperClient sharedClient] extractPlugin:item.identifier kind:kind completion:^(NSDictionary *result, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *t = [PMActionSheet topViewController] ?: top;
            if (!result) {
                [PMToast show:[PMHelperClient messageForError:err] inView:t.view style:2];
                return;
            }
            NSArray *files = result[@"files"];
            NSUInteger n = [files isKindOfClass:[NSArray class]] ? files.count : 0;
            [PMToast show:[NSString stringWithFormat:@"已提取 %lu 个文件", (unsigned long)n]
                   inView:t.view style:1];
        });
    }];
}

/// 把 deb 文件本身复制到 PluginManager 目录
+ (void)extractDebFileToStore:(NSString *)path {
    if (path.length == 0) return;
    UIViewController *top = [self topViewController];

    [[PMHelperClient sharedClient] copyDebToStore:path completion:^(NSDictionary *result, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *t = [PMActionSheet topViewController] ?: top;
            if (!result) {
                [PMToast show:[PMHelperClient messageForError:err] inView:t.view style:2];
                return;
            }
            [PMToast show:(result[@"already"] ? @"文件已在该目录" : @"已复制到 PluginManager 目录")
                   inView:t.view style:1];
        });
    }];
}

@end
