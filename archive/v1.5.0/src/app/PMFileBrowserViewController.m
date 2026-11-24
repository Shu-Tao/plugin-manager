#import "PMFileBrowserViewController.h"
#import "PMActionSheet.h"
#import "PMHelperClient.h"
#import "PMTheme.h"
#import "PMToast.h"

/// 文件类型图标只有几种，全局缓存避免每行重复创建
static UIImage *PMFileIcon(NSString *name) {
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

@interface PMFileBrowserViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *rows;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIRefreshControl *refresh;
/// 当前浏览的子目录（相对两个根目录）；nil 表示根层
@property (nonatomic, copy, nullable) NSString *currentSub;
@property (nonatomic, copy, nullable) NSString *currentRoot;
@end

@implementation PMFileBrowserViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"文件管理";

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"清空"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(confirmClearAll)];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.rows = [NSMutableArray array];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"file"];
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    self.refresh = [UIRefreshControl new];
    [self.refresh addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = self.refresh;

    self.emptyLabel = [UILabel new];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.text = @"这里还没有文件\n先在插件页用「提取 dylib」或「备份」生成";
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.font = [UIFont systemFontOfSize:14];
    self.emptyLabel.textColor = [PMTheme secondaryText];
    self.emptyLabel.hidden = YES;
    [self.view addSubview:self.emptyLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-40],
        [self.emptyLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:40],
        [self.emptyLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-40],
    ]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)goBackToRoot {
    self.currentRoot = nil;
    self.currentSub = nil;
    self.title = @"文件管理";
    [self reload];
}

- (NSArray<NSString *> *)baseRoots {
    return @[
        @"/var/mobile/Documents/PluginManager",
        @"/var/mobile/Library/PluginManager",
    ];
}

- (NSArray<NSString *> *)searchRoots {
    if (self.currentRoot.length > 0) {
        NSString *sub = self.currentSub.length ? self.currentSub : @"";
        NSString *full = sub.length
            ? [self.currentRoot stringByAppendingPathComponent:sub]
            : self.currentRoot;
        return @[full];
    }
    return [self baseRoots];
}

- (void)reload {
    [self.rows removeAllObjects];
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *root in [self searchRoots]) {
        NSArray *names = [fm contentsOfDirectoryAtPath:root error:NULL];
        if (names.count == 0) continue;
        for (NSString *name in [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
            NSString *full = [root stringByAppendingPathComponent:name];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;

            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:NULL];
            unsigned long long size = isDir ? 0 : [attrs fileSize];
            NSDate *date = attrs[NSFileModificationDate];

            // 目录显示内部条目数
            if (isDir) {
                NSArray *inner = [fm contentsOfDirectoryAtPath:full error:NULL];
                [self.rows addObject:@{
                    @"name": name, @"path": full, @"dir": @YES,
                    @"count": @(inner.count), @"date": date ?: [NSDate date],
                }];
            } else {
                [self.rows addObject:@{
                    @"name": name, @"path": full, @"dir": @NO,
                    @"size": @(size), @"date": date ?: [NSDate date],
                }];
            }
        }
    }

    // 置顶项排最前，其余保持原顺序
    NSArray<NSString *> *pins = [self pinnedPaths];
    if (pins.count > 0) {
        [self.rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSUInteger ia = [pins indexOfObject:a[@"path"]];
            NSUInteger ib = [pins indexOfObject:b[@"path"]];
            BOOL pa = (ia != NSNotFound);
            BOOL pb = (ib != NSNotFound);
            if (pa && pb) return ia < ib ? NSOrderedAscending : (ia > ib ? NSOrderedDescending : NSOrderedSame);
            if (pa) return NSOrderedAscending;
            if (pb) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    }

    self.emptyLabel.hidden = self.rows.count > 0;
    [self.tableView reloadData];
    [self.refresh endRefreshing];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.rows.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.rows.count ? @"已提取 / 备份的文件" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.rows.count == 0) return nil;
    return @"这些是本 App 生成的副本，删除不影响系统中的原始插件。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"file" forIndexPath:indexPath];
    NSDictionary *row = self.rows[indexPath.row];

    UIListContentConfiguration *cfg = [UIListContentConfiguration subtitleCellConfiguration];
    cfg.text = row[@"name"];

    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"MM-dd HH:mm";
    NSString *when = [fmt stringFromDate:row[@"date"]];

    if ([row[@"dir"] boolValue]) {
        cfg.secondaryText = [NSString stringWithFormat:@"文件夹 · %@ 项 · %@", row[@"count"], when];
        cfg.image = PMFileIcon(@"folder");
    } else {
        cfg.secondaryText = [NSString stringWithFormat:@"%.1f KB · %@",
                             [row[@"size"] doubleValue] / 1024.0, when];
        NSString *name = row[@"name"];
        if ([name hasSuffix:@".deb"]) cfg.image = PMFileIcon(@"shippingbox");
        else if ([name hasSuffix:@".zip"]) cfg.image = PMFileIcon(@"archivebox");
        else if ([name hasSuffix:@".dylib"]) cfg.image = PMFileIcon(@"cpu");
        else cfg.image = PMFileIcon(@"doc");
    }
    cell.contentConfiguration = cfg;
    // 复用前清掉残留的 accessory，避免图钉串行
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;

    // 置顶项在右侧显示图钉
    if ([self isPinned:row[@"path"]]) {
        UIImageView *pinView = [[UIImageView alloc] initWithImage:PMFileIcon(@"pin.fill")];
        pinView.tintColor = [PMTheme accent];
        pinView.contentMode = UIViewContentModeScaleAspectFit;
        pinView.frame = CGRectMake(0, 0, 16, 16);
        cell.accessoryView = pinView;
    } else {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = self.rows[indexPath.row];
    NSString *path = row[@"path"];

    if ([row[@"dir"] boolValue]) {
        // 进入子目录浏览
        self.currentRoot = path;
        self.currentSub = @"";
        self.title = row[@"name"];
        [self reload];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [PMActionSheet presentForDebAtPath:path from:self onRefresh:^{
        [weakSelf reload];
    }];
}


#pragma mark - 清空与打包

- (void)confirmClearAll {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空全部文件？"
                                                                  message:@"将删除 PluginManager 目录下的所有副本，不可恢复。"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        NSArray<NSString *> *roots = [weakSelf baseRoots];
        __block NSInteger remaining = (NSInteger)roots.count;
        if (remaining == 0) return;
        for (NSString *root in roots) {
            [[PMHelperClient sharedClient] clearDir:root completion:^(NSDictionary *r, NSError *e) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    remaining--;
                    if (remaining > 0) return;
                    NSMutableArray *list = [weakSelf pinnedPaths];
                    [list removeAllObjects];
                    [[NSUserDefaults standardUserDefaults] setObject:list forKey:PMPinnedDefaultsKey];
                    [PMToast show:@"已清空" inView:weakSelf.view style:1];
                    [weakSelf reload];
                });
            }];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// 把当前目录全部文件打包成 zip 再分享（.deb 直接分享成功率低）
- (void)shareAllAsZip {
    NSArray<NSString *> *paths = [self.rows valueForKey:@"path"];
    if (paths.count == 0) return;

    __weak typeof(self) weakSelf = self;
    [[PMHelperClient sharedClient] zipPack:paths name:nil completion:^(NSDictionary *r, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!r) {
                [PMToast show:[PMHelperClient messageForError:e] inView:weakSelf.view style:2];
                return;
            }
            NSString *zip = r[@"path"];
            if (zip.length) [PMActionSheet sharePaths:@[zip]];
        });
    }];
}

#pragma mark - 左滑操作

static NSString *const PMPinnedDefaultsKey = @"PMPinnedFiles";

- (NSMutableArray<NSString *> *)pinnedPaths {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:PMPinnedDefaultsKey];
    return saved ? [saved mutableCopy] : [NSMutableArray array];
}

- (BOOL)isPinned:(NSString *)path {
    return [[self pinnedPaths] containsObject:path];
}

- (void)togglePin:(NSString *)path {
    NSMutableArray *list = [self pinnedPaths];
    if ([list containsObject:path]) {
        [list removeObject:path];
        [PMToast show:@"已取消置顶" inView:self.view style:0];
    } else {
        [list insertObject:path atIndex:0];
        [PMToast show:@"已置顶" inView:self.view style:1];
    }
    [[NSUserDefaults standardUserDefaults] setObject:list forKey:PMPinnedDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self reload];
}

- (void)confirmDelete:(NSString *)path name:(NSString *)name {
    // 统一走助手删除：助手以 root 运行，能删掉 mobile 用户无权动的文件
    __weak typeof(self) weakSelf = self;
    [PMActionSheet confirmDeletePath:path onRefresh:^{
        NSMutableArray *list = [weakSelf pinnedPaths];
        if ([list containsObject:path]) {
            [list removeObject:path];
            [[NSUserDefaults standardUserDefaults] setObject:list forKey:PMPinnedDefaultsKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
        [weakSelf reload];
    }];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.rows.count) return nil;
    NSDictionary *row = self.rows[indexPath.row];
    NSString *path = row[@"path"];
    NSString *name = row[@"name"];
    if (!path) return nil;

    __weak typeof(self) weakSelf = self;
    BOOL pinned = [self isPinned:path];

    UIContextualAction *pin = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                      title:(pinned ? @"取消置顶" : @"置顶")
                                                                    handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) {
        [weakSelf togglePin:path];
        completion(YES);
    }];
    pin.backgroundColor = pinned ? [UIColor systemGrayColor] : [PMTheme accent];
    pin.image = PMFileIcon(pinned ? @"pin.slash" : @"pin");

    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                      title:@"删除"
                                                                    handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) {
        [weakSelf confirmDelete:path name:name];
        completion(YES);
    }];
    del.backgroundColor = [PMTheme danger];

    UISwipeActionsConfiguration *cfg = [UISwipeActionsConfiguration configurationWithActions:@[del, pin]];
    cfg.performsFirstActionWithFullSwipe = NO;
    return cfg;
}


@end