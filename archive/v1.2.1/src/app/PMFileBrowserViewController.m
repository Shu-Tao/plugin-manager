#import "PMFileBrowserViewController.h"
#import "PMActionSheet.h"
#import "PMHelperClient.h"
#import "PMTheme.h"
#import "PMToast.h"

@interface PMFileBrowserViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *rows;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIRefreshControl *refresh;
@end

@implementation PMFileBrowserViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"文件管理";
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

- (NSArray<NSString *> *)searchRoots {
    NSString *home = NSHomeDirectory();
    return @[
        [home stringByAppendingPathComponent:@"Documents/PluginManager"],
        [home stringByAppendingPathComponent:@"Library/PluginManager"],
    ];
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
        cfg.image = [UIImage systemImageNamed:@"folder"];
    } else {
        cfg.secondaryText = [NSString stringWithFormat:@"%.1f KB · %@",
                             [row[@"size"] doubleValue] / 1024.0, when];
        NSString *name = row[@"name"];
        if ([name hasSuffix:@".deb"]) cfg.image = [UIImage systemImageNamed:@"shippingbox"];
        else if ([name hasSuffix:@".zip"]) cfg.image = [UIImage systemImageNamed:@"archivebox"];
        else if ([name hasSuffix:@".dylib"]) cfg.image = [UIImage systemImageNamed:@"cpu"];
        else cfg.image = [UIImage systemImageNamed:@"doc"];
    }
    cell.contentConfiguration = cfg;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = self.rows[indexPath.row];
    NSString *path = row[@"path"];

    if ([row[@"dir"] boolValue]) {
        // 目录：分享其中全部文件
        NSArray *inner = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL];
        NSMutableArray *paths = [NSMutableArray array];
        for (NSString *n in inner) [paths addObject:[path stringByAppendingPathComponent:n]];
        if (paths.count == 0) return;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:row[@"name"]
                                                                  message:[NSString stringWithFormat:@"选出 %lu 个文件分享？", (unsigned long)paths.count]
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"分享" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [PMActionSheet sharePaths:paths];
        }]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [PMActionSheet presentForDebAtPath:path from:self onRefresh:^{
        [weakSelf reload];
    }];
}

@end
