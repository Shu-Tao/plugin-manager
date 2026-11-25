#import "PMListViewController.h"
#import "PMStore.h"
#import "PMHelperClient.h"
#import "PMSwitchCell.h"
#import "PMStatusCell.h"
#import "PMToast.h"
#import "PMTheme.h"
#import "PMActionSheet.h"
#import "PMFileBrowserViewController.h"

typedef NS_ENUM(NSInteger, PMSection) {
    PMSectionDisabled = 0,   // 未开启的放最上面
    PMSectionEnabled = 1,
    PMSectionStatus = 2,
};

@interface PMListViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIRefreshControl *refreshControl;
@property (nonatomic, strong) UITextField *searchField;
@property (nonatomic, strong) PMStore *store;

@property (nonatomic, copy) NSArray<PMPluginItem *> *allVisible;   // 过滤后的全集
@property (nonatomic, copy) NSArray<PMPluginItem *> *disabledItems;
@property (nonatomic, copy) NSArray<PMPluginItem *> *enabledItems;

@property (nonatomic, copy) NSString *searchText;
@property (nonatomic, strong) NSMutableSet<NSString *> *expandedIDs;
@property (nonatomic, strong) UIBarButtonItem *menuButton;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, assign) BOOL ready;          // 视图树是否可安全 reload
@property (nonatomic, strong) NSTimer *searchDebounce;
@end

@implementation PMListViewController

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"插件管理";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.store = [PMStore new];
    self.searchText = @"";
    self.expandedIDs = [NSMutableSet set];
    self.disabledItems = @[];
    self.enabledItems = @[];
    self.allVisible = @[];
    self.navigationController.navigationBar.prefersLargeTitles = NO;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 70.0;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.tableView registerClass:[PMSwitchCell class] forCellReuseIdentifier:@"plugin"];
    [self.tableView registerClass:[PMStatusCell class] forCellReuseIdentifier:@"status"];
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(handleRefresh) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = self.refreshControl;

    // 不用 UISearchController。
    // 崩溃日志证明 CUIShapeEffectStack sharedCIContext 在激活搜索时必然崩溃，
    // 而 UISearchController 自带的放大镜与清除按钮都是 SF Symbol，
    // 会在 CA::Transaction::commit 阶段由 UIKit 内部 UIImageView 渲染。
    // 因此改为自绘 UITextField，全程不产生任何系统图标。
    self.searchField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 0, 42)];
    self.searchField.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.searchField.layer.cornerRadius = 10;
    self.searchField.layer.cornerCurve = kCACornerCurveContinuous;
    self.searchField.placeholder = @"搜索插件名或用途";
    self.searchField.font = [UIFont systemFontOfSize:16];
    self.searchField.clearButtonMode = UITextFieldViewModeNever;   // 清除按钮也是 SF Symbol
    self.searchField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchField.returnKeyType = UIReturnKeyDone;
    self.searchField.delegate = self;
    self.searchField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 42)];
    self.searchField.leftViewMode = UITextFieldViewModeAlways;
    [self.searchField addTarget:self
                         action:@selector(searchFieldChanged:)
               forControlEvents:UIControlEventEditingChanged];
    [self.searchField.heightAnchor constraintEqualToConstant:42].active = YES;

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 54)];
    header.backgroundColor = [UIColor clearColor];
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:self.searchField];
    [NSLayoutConstraint activateConstraints:@[
        [self.searchField.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [self.searchField.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
        [self.searchField.topAnchor constraintEqualToAnchor:header.topAnchor constant:6],
        [self.searchField.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-6],
    ]];
    self.tableView.tableHeaderView = header;

    // 用文字做图标：SF Symbol 会触发 CoreImage 的 GLContext 分配，
    // 内存不足时整进程崩溃（见 PMSharedSymbol 处的说明）。
    self.menuButton = [[UIBarButtonItem alloc] initWithTitle:@"⋯"
                                                       style:UIBarButtonItemStylePlain
                                                      target:self
                                                      action:@selector(showActionMenu)];
    self.menuButton.accessibilityLabel = @"生效与批量操作";
    self.navigationItem.rightBarButtonItem = self.menuButton;

    self.ready = YES;
    [self reloadData];
}

- (void)dealloc {
    [self.searchDebounce invalidate];
    self.searchDebounce = nil;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.store.items.count == 0) [self reloadData];
}

#pragma mark - 数据

- (void)reloadData {
    if (!self.ready) return;
    NSError *error = nil;
    BOOL ok = [self.store reloadWithError:&error];
    [self rebuildSections];
    [self.tableView reloadData];

    if (!ok) {
        [PMToast show:[PMHelperClient messageForError:error] inView:self.view style:2];
    } else if (!self.store.helperAvailable) {
        [PMToast show:@"特权助手不可用，请重装插件管理器" inView:self.view style:2];
    }
}

/// 过滤 + 按启用状态分组：未开启的在前
- (void)rebuildSections {
    NSString *needle = [self.searchText stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;

    NSMutableArray *disabled = [NSMutableArray array];
    NSMutableArray *enabled = [NSMutableArray array];
    NSMutableArray *all = [NSMutableArray array];

    for (PMPluginItem *item in self.store.items) {
        if (needle.length > 0) {
            BOOL hit = [item.identifier.lowercaseString containsString:needle];
            if (!hit) hit = [[item subtitleText].lowercaseString containsString:needle];
            if (!hit) hit = [item.package.lowercaseString containsString:needle];
            if (!hit) {
                for (NSString *b in item.bundles) {
                    if ([b.lowercaseString containsString:needle]) { hit = YES; break; }
                }
            }
            if (!hit) continue;
        }
        [all addObject:item];
        if (item.enabled) [enabled addObject:item];
        else [disabled addObject:item];
    }

    self.disabledItems = disabled;
    self.enabledItems = enabled;
    self.allVisible = all;
    self.menuButton.enabled = (all.count > 0);
}

- (void)handleRefresh {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL ok = [self.store reloadWithError:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.ready) return;
            [self rebuildSections];
            [self.tableView reloadData];
            [self.refreshControl endRefreshing];
            if (!ok) [PMToast show:[PMHelperClient messageForError:error] inView:self.view style:2];
        });
    });
}

#pragma mark - 开关

- (void)applyEnabled:(BOOL)enabled toItem:(PMPluginItem *)item {
    if (self.busy || !item) return;
    self.busy = YES;
    [self.tableView reloadData];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL ok = [self.store setEnabled:enabled forItem:item error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            if (!self.ready) return;
            [self rebuildSections];
            [self.tableView reloadData];
            if (!ok) {
                [PMToast show:[PMHelperClient messageForError:error] inView:self.view style:2];
            } else {
                [PMToast show:[NSString stringWithFormat:@"%@ 已%@", item.identifier, enabled ? @"启用" : @"停用"]
                       inView:self.view style:1];
            }
        });
    });
}

- (void)applyEnabled:(BOOL)enabled toItems:(NSArray<PMPluginItem *> *)items {
    if (self.busy || items.count == 0) return;
    self.busy = YES;
    [self.tableView reloadData];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL ok = [self.store setEnabled:enabled forItems:items error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            if (!self.ready) return;
            [self rebuildSections];
            [self.tableView reloadData];
            [PMToast show:(ok ? [NSString stringWithFormat:@"%lu 个插件已%@", (unsigned long)items.count, enabled ? @"启用" : @"停用"]
                          : [PMHelperClient messageForError:error])
                   inView:self.view style:(ok ? 1 : 2)];
        });
    });
}

#pragma mark - 右上角菜单

- (void)showActionMenu {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;

    NSUInteger pending = [self.store pendingCount];
    NSString *suffix = pending > 0 ? [NSString stringWithFormat:@"（%lu 项待生效）", (unsigned long)pending] : @"";

    [sheet addAction:[UIAlertAction actionWithTitle:[@"重启 SpringBoard（注销）" stringByAppendingString:suffix]
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) { [weakSelf confirmRespring]; }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"重启用户空间"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) { [weakSelf confirmRebootUserspace]; }]];

    if (self.allVisible.count > 0) {
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"全部启用（%lu）", (unsigned long)self.allVisible.count]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) { [weakSelf applyEnabled:YES toItems:weakSelf.allVisible]; }]];
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"全部停用（%lu）", (unsigned long)self.allVisible.count]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) { [weakSelf applyEnabled:NO toItems:weakSelf.allVisible]; }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"文件管理" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        PMFileBrowserViewController *browser = [PMFileBrowserViewController new];
        [weakSelf.navigationController pushViewController:browser animated:YES];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"刷新列表" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf reloadData];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.menuButton;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmRespring {
    NSUInteger pending = [self.store pendingCount];
    NSString *msg = pending > 0
        ? [NSString stringWithFormat:@"%lu 项改动已写盘。屏幕会短暂黑屏，3–8 秒后回到桌面。", (unsigned long)pending]
        : @"当前没有待生效的改动。仍要重启桌面吗？";
    [self confirmTitle:@"重启 SpringBoard（注销）"
               message:msg
               handler:^{ [self performRespring]; }];
}

- (void)confirmRebootUserspace {
    [self confirmTitle:@"重启用户空间"
               message:@"断网黑屏约 5–20 秒，等同于软重启；越狱环境会重新加载。请先保存工作。"
               handler:^{ [self performRebootUserspace]; }];
}

- (void)confirmTitle:(NSString *)title message:(NSString *)message handler:(void (^)(void))handler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"继续" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        handler();
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performRespring {
    [self.store markEffective];
    [self.tableView reloadData];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSString *method = [self.store respringWithError:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (method) {
                [PMToast show:[NSString stringWithFormat:@"已发送注销指令（%@）", method] inView:self.view style:1];
            } else {
                [PMToast show:[PMHelperClient messageForError:error] inView:self.view style:2];
            }
        });
    });
}

- (void)performRebootUserspace {
    [self.store markEffective];
    [self.tableView reloadData];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSString *method = [self.store rebootUserspaceWithError:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (method) {
                [PMToast show:[NSString stringWithFormat:@"已请求重启用户空间（%@）", method] inView:self.view style:1];
            } else {
                [PMToast show:[PMHelperClient messageForError:error] inView:self.view style:2];
            }
        });
    });
}

#pragma mark - TableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case PMSectionDisabled: return self.disabledItems.count;
        case PMSectionEnabled:  return self.enabledItems.count;
        default: return 1;
    }
}

- (PMPluginItem *)itemAtIndexPath:(NSIndexPath *)indexPath {
    if (!indexPath) return nil;
    NSUInteger row = (NSUInteger)indexPath.row;
    if (indexPath.section == PMSectionDisabled) {
        return row < self.disabledItems.count ? self.disabledItems[row] : nil;
    }
    if (indexPath.section == PMSectionEnabled) {
        return row < self.enabledItems.count ? self.enabledItems[row] : nil;
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == PMSectionDisabled) {
        if (self.disabledItems.count == 0) {
            return (self.allVisible.count == 0 && self.searchText.length > 0) ? @"没有匹配的插件" : @"未开启";
        }
        return [NSString stringWithFormat:@"未开启（%lu）", (unsigned long)self.disabledItems.count];
    }
    if (section == PMSectionEnabled) {
        if (self.enabledItems.count == 0) return nil;
        return [NSString stringWithFormat:@"已开启（%lu）", (unsigned long)self.enabledItems.count];
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == PMSectionDisabled && self.disabledItems.count > 0) {
        return @"这些插件当前不会被加载。打开开关并点右上角 ⋯ → 注销后即可生效。";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == PMSectionStatus) {
        PMStatusCell *cell = [tableView dequeueReusableCellWithIdentifier:@"status" forIndexPath:indexPath];
        [cell configureWithDirectory:self.store.injectDirectory
                         pluginCount:self.store.items.count
                        enabledCount:[self.store enabledCount]
                        pendingCount:[self.store pendingCount]];
        return cell;
    }

    PMSwitchCell *cell = [tableView dequeueReusableCellWithIdentifier:@"plugin" forIndexPath:indexPath];
    PMPluginItem *item = [self itemAtIndexPath:indexPath];
    if (!item) return cell;

    BOOL expanded = [self.expandedIDs containsObject:item.identifier];
    [cell configureWithItem:item
                    enabled:item.enabled
                    pending:[self.store isPending:item]
                   expanded:expanded];
    [cell setToggleEnabled:!self.busy];

    __weak typeof(self) weakSelf = self;
    NSString *ident = item.identifier;
    cell.onToggle = ^(BOOL isOn) {
        PMPluginItem *current = [weakSelf.store itemWithIdentifier:ident];
        if (current) [weakSelf applyEnabled:isOn toItem:current];
    };
    cell.onExpand = ^{
        if ([weakSelf.expandedIDs containsObject:ident]) {
            [weakSelf.expandedIDs removeObject:ident];
        } else {
            [weakSelf.expandedIDs addObject:ident];
        }
        [weakSelf.tableView beginUpdates];
        [weakSelf.tableView endUpdates];
        [weakSelf.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
    };
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    PMPluginItem *item = [self itemAtIndexPath:indexPath];
    if (!item) return;

    __weak typeof(self) weakSelf = self;
    [PMActionSheet presentForPlugin:item from:self onRefresh:^{
        [weakSelf reloadData];
    }];
}

#pragma mark - 搜索（防抖，避免高频 reload 崩溃）

- (void)searchFieldChanged:(UITextField *)field {
    NSString *text = field.text ?: @"";
    [self.searchDebounce invalidate];

    __weak typeof(self) weakSelf = self;
    self.searchDebounce = [NSTimer scheduledTimerWithTimeInterval:0.12
                                                          repeats:NO
                                                            block:^(NSTimer *timer) {
        [weakSelf applySearchText:text];
    }];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)applySearchText:(NSString *)text {
    if (!self.ready || !self.isViewLoaded) return;
    if ([self.searchText isEqualToString:text]) return;
    self.searchText = text ?: @"";
    [self rebuildSections];
    if (self.tableView.window == nil && self.tableView.superview == nil) return;
    [self.tableView reloadData];
}

@end