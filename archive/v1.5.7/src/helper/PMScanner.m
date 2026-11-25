#import "PMScanner.h"
#import "PMPaths.h"
#import "PMFsOps.h"
#import <sys/stat.h>

// 单条目字段（与 App 端 PMPluginItem 一一对应）：
// id       插件名（去掉 .dylib / .dylib.disabled 的文件名主干）
// dylib    当前磁盘上的 dylib 文件名
// plist    当前磁盘上的 Filter plist 文件名（可能为空）
// enabled  是否启用
// filter   Filter -> Bundles（前 8 个）
// execs    Filter -> Executables（前 8 个）
// size     dylib 字节数
// mtime    dylib 修改时间（unix 秒）
// package  归属 dpkg 包（可能为空）

static NSArray<NSString *> *PMStringArray(id value, NSUInteger limit) {
    if (![value isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id v in (NSArray *)value) {
        if (![v isKindOfClass:[NSString class]]) continue;
        [out addObject:v];
        if (out.count >= limit) break;
    }
    return out;
}

static void PMReadFilter(NSString *plistPath, NSArray **bundles, NSArray **execs) {
    *bundles = @[];
    *execs = @[];
    if (plistPath.length == 0) return;
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (![root isKindOfClass:[NSDictionary class]]) return;
    id filter = root[@"Filter"];
    if ([filter isKindOfClass:[NSArray class]] && [(NSArray *)filter count] > 0) {
        filter = [(NSArray *)filter firstObject];
    }
    if (![filter isKindOfClass:[NSDictionary class]]) return;
    *bundles = PMStringArray(((NSDictionary *)filter)[@"Bundles"], 8);
    *execs = PMStringArray(((NSDictionary *)filter)[@"Executables"], 8);
}

NSArray<NSDictionary *> *PMScanPlugins(NSString *dir) {
    NSMutableArray *items = [NSMutableArray array];
    if (!PMIsDirectory(dir)) return items;

    // 与单元测试同一份扫描实现：去重 + 字典序 + 标识白名单
    static char ids[PM_MAX_PLUGINS][PM_ID_MAX + 1];
    int count = pm_scan_ids(dir.fileSystemRepresentation, ids, PM_MAX_PLUGINS);
    if (count <= 0) return items;   // 0：空目录；负数：错误

    NSMutableArray<NSString *> *ordered = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (int i = 0; i < count; i++) {
        NSString *ident = [NSString stringWithUTF8String:ids[i]];
        if (ident.length) [ordered addObject:ident];
    }

    for (NSString *pid in ordered) {
        NSString *dylibOn = [dir stringByAppendingPathComponent:[pid stringByAppendingString:@".dylib"]];
        NSString *dylibOff = [dylibOn stringByAppendingString:@".disabled"];
        BOOL enabled = PMIsRegularFile(dylibOn);
        NSString *dylibPath = enabled ? dylibOn : dylibOff;
        if (!PMIsRegularFile(dylibPath)) continue;   // 既非普通文件也非改名态，跳过
        if (PMIsSymlink(dylibPath)) continue;        // 符号链接一律不接管

        NSString *plistOn = [dir stringByAppendingPathComponent:[pid stringByAppendingString:@".plist"]];
        NSString *plistOff = [plistOn stringByAppendingString:@".disabled"];
        NSString *plistPath = nil;
        if (PMIsRegularFile(plistOn) && !PMIsSymlink(plistOn)) plistPath = plistOn;
        else if (PMIsRegularFile(plistOff) && !PMIsSymlink(plistOff)) plistPath = plistOff;

        NSArray *bundles = nil, *execs = nil;
        PMReadFilter(plistPath, &bundles, &execs);

        struct stat st;
        unsigned long long size = 0;
        long long mtime = 0;
        if (lstat(dylibPath.fileSystemRepresentation, &st) == 0) {
            size = (unsigned long long)st.st_size;
            mtime = (long long)st.st_mtimespec.tv_sec;
        }

        [items addObject:@{
            @"id": pid,
            @"dylib": dylibPath.lastPathComponent,
            @"plist": plistPath.lastPathComponent ?: @"",
            @"enabled": @(enabled),
            @"filter": bundles,
            @"execs": execs,
            @"size": @(size),
            @"mtime": @(mtime),
            @"package": PMPackageOwningFile(dylibPath.lastPathComponent) ?: @"",
        }];
    }
    return items;
}

static NSMutableDictionary<NSString *, NSString *> *gOwners = nil;

NSString *PMPackageOwningFile(NSString *fileName) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gOwners = [NSMutableDictionary dictionary]; });
    if (fileName.length == 0) return @"";
    NSString *infoDir = [PMJBRoot() stringByAppendingString:@"/var/lib/dpkg/info"];
    if (!PMIsDirectory(infoDir)) return @"";
    if (gOwners[fileName]) return gOwners[fileName];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *lists = [fm contentsOfDirectoryAtPath:infoDir error:NULL] ?: @[];
    unsigned long long budget = 16ull * 1024 * 1024;   // 最多读 16MB list 文本
    NSString *needle = [@"/" stringByAppendingString:fileName];
    for (NSString *list in lists) {
        if (![list hasSuffix:@".list"]) continue;
        if (budget == 0) break;
        NSString *path = [infoDir stringByAppendingPathComponent:list];
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) != 0) continue;
        if (st.st_size <= 0) continue;
        if ((unsigned long long)st.st_size > budget) continue;
        budget -= (unsigned long long)st.st_size;
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        if (text.length == 0) continue;
        if ([text rangeOfString:needle].location != NSNotFound) {
            NSString *pkg = [list substringToIndex:list.length - @".list".length];
            gOwners[fileName] = pkg;
            return pkg;
        }
    }
    gOwners[fileName] = @"";
    return @"";
}
