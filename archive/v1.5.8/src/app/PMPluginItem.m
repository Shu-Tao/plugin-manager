#import "PMPluginItem.h"
#import "PMHostNames.h"

@implementation PMPluginItem

+ (instancetype)itemWithDictionary:(NSDictionary *)dict {
    PMPluginItem *item = [PMPluginItem new];
    item.identifier = dict[@"id"] ?: @"";
    item.dylibName = dict[@"dylib"] ?: @"";
    item.plistName = dict[@"plist"] ?: @"";
    item.package = dict[@"package"] ?: @"";
    item.bundles = dict[@"filter"] ?: @[];
    item.executables = dict[@"execs"] ?: @[];
    item.enabled = [dict[@"enabled"] boolValue];
    item.bytes = [dict[@"size"] unsignedLongLongValue];
    item.mtime = [dict[@"mtime"] longLongValue];
    return item;
}

/// 折叠态只给「大概功能」：最多 2 个宿主中文名，不带 bundle id / 包名 / 大小
- (NSString *)subtitleText {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (NSString *b in self.bundles) {
        NSString *human = PMDescribeHost(b) ?: b;
        if ([seen containsObject:human]) continue;
        [seen addObject:human];
        [names addObject:human];
        if (names.count >= 2) break;
    }
    if (names.count < 2) {
        for (NSString *e in self.executables) {
            NSString *human = PMDescribeHost(e) ?: e;
            if ([seen containsObject:human]) continue;
            [seen addObject:human];
            [names addObject:human];
            if (names.count >= 2) break;
        }
    }

    NSUInteger total = self.bundles.count + self.executables.count;
    if (names.count == 0) return @"未声明作用范围";
    if (total > names.count) {
        return [NSString stringWithFormat:@"%@ 等 %lu 处",
                [names componentsJoinedByString:@"、"], (unsigned long)total];
    }
    return [names componentsJoinedByString:@"、"];
}

- (NSString *)detailText {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];

    if (self.bundles.count > 0) {
        NSMutableArray *human = [NSMutableArray array];
        for (NSString *b in self.bundles) {
            NSString *name = PMDescribeHost(b);
            if (name) [human addObject:[NSString stringWithFormat:@"%@（%@）", name, b]];
            else [human addObject:b];
        }
        [lines addObject:[@"作用于 Bundle：" stringByAppendingString:[human componentsJoinedByString:@"、"]]];
    }

    if (self.executables.count > 0) {
        NSMutableArray *human = [NSMutableArray array];
        for (NSString *e in self.executables) {
            NSString *name = PMDescribeHost(e);
            if (name) [human addObject:[NSString stringWithFormat:@"%@（%@）", name, e]];
            else [human addObject:e];
        }
        [lines addObject:[@"作用于进程：" stringByAppendingString:[human componentsJoinedByString:@"、"]]];
    }

    if (self.bundles.count == 0 && self.executables.count == 0) {
        [lines addObject:@"Filter plist 未声明 Bundles / Executables"];
    }

    [lines addObject:[NSString stringWithFormat:@"文件：%@%@",
                      self.dylibName.length ? self.dylibName : @"?",
                      self.plistName.length ? [@", " stringByAppendingString:self.plistName] : @",（无 plist）"]];

    if (self.package.length > 0) {
        [lines addObject:[@"软件包：" stringByAppendingString:self.package]];
    } else {
        [lines addObject:@"软件包：不属于任何 dpkg 包"];
    }

    if (self.bytes > 0) {
        [lines addObject:[NSString stringWithFormat:@"大小：%.1f KB", self.bytes / 1024.0]];
    }

    if (self.mtime > 0) {
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)self.mtime];
        NSDateFormatter *fmt = [NSDateFormatter new];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm";
        [lines addObject:[@"修改时间：" stringByAppendingString:[fmt stringFromDate:date]]];
    }

    return [lines componentsJoinedByString:@"\n"];
}

@end
