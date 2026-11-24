#import "PMStore.h"
#import "PMHelperClient.h"

@interface PMStore ()
@property (nonatomic, copy, nullable) NSString *injectDirectory;
@property (nonatomic, copy) NSArray<PMPluginItem *> *items;
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *changed;
@end

@implementation PMStore

- (instancetype)init {
    self = [super init];
    if (self) {
        _items = @[];
        _changed = [NSMutableOrderedSet orderedSet];
    }
    return self;
}

- (BOOL)helperAvailable { return [PMHelperClient sharedClient].isAvailable; }

- (BOOL)reloadWithError:(NSError **)error {
    NSDictionary *result = [[PMHelperClient sharedClient] listPluginsWithError:error];
    if (!result) return NO;

    self.injectDirectory = result[@"dir"];
    NSMutableArray<PMPluginItem *> *list = [NSMutableArray array];
    for (NSDictionary *dict in result[@"items"]) {
        if (![dict isKindOfClass:[NSDictionary class]]) continue;
        [list addObject:[PMPluginItem itemWithDictionary:dict]];
    }
    self.items = list;

    // 插件被卸载/重装后，清掉已不存在的改动记录
    NSMutableArray *gone = [NSMutableArray array];
    NSMutableSet *alive = [NSMutableSet set];
    for (PMPluginItem *item in list) [alive addObject:item.identifier];
    for (NSString *ident in self.changed) {
        if (![alive containsObject:ident]) [gone addObject:ident];
    }
    for (NSString *ident in gone) [self.changed removeObject:ident];
    return YES;
}

- (BOOL)setEnabled:(BOOL)enabled forItem:(PMPluginItem *)item error:(NSError **)error {
    if (item.enabled == enabled) return YES;   // 已是目标状态，不打扰磁盘
    NSDictionary *result = [[PMHelperClient sharedClient] runCommand:@"set"
                                                          arguments:@[@"--id", item.identifier, @"--state", enabled ? @"enabled" : @"disabled"]
                                                              error:error];
    if (!result) return NO;

    item.enabled = enabled;
    [self.changed addObject:item.identifier];
    return YES;
}

- (BOOL)setEnabled:(BOOL)enabled forItems:(NSArray<PMPluginItem *> *)items error:(NSError **)error {
    BOOL allOK = YES;
    NSError *lastError = nil;
    for (PMPluginItem *item in items) {
        NSError *itemError = nil;
        if (![self setEnabled:enabled forItem:item error:&itemError]) {
            allOK = NO;
            lastError = itemError;
        }
    }
    if (!allOK && error) *error = lastError;
    return allOK;
}

- (NSUInteger)enabledCount {
    NSUInteger n = 0;
    for (PMPluginItem *item in self.items) if (item.enabled) n++;
    return n;
}

- (BOOL)isPending:(PMPluginItem *)item {
    return item ? [self.changed containsObject:item.identifier] : NO;
}

- (PMPluginItem *)itemWithIdentifier:(NSString *)identifier {
    if (identifier.length == 0) return nil;
    for (PMPluginItem *item in self.items) {
        if ([item.identifier isEqualToString:identifier]) return item;
    }
    return nil;
}

- (NSUInteger)pendingCount { return self.changed.count; }

- (NSArray<PMPluginItem *> *)pendingItems {
    NSMutableArray *out = [NSMutableArray array];
    for (PMPluginItem *item in self.items) {
        if ([self.changed containsObject:item.identifier]) [out addObject:item];
    }
    return out;
}

- (void)markEffective { [self.changed removeAllObjects]; }

- (NSString *)respringWithError:(NSError **)error {
    return [[PMHelperClient sharedClient] respringWithError:error];
}

- (NSString *)rebootUserspaceWithError:(NSError **)error {
    return [[PMHelperClient sharedClient] rebootUserspaceWithError:error];
}

@end
