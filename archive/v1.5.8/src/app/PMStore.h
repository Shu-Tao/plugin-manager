#import <Foundation/Foundation.h>
#import "PMPluginItem.h"

NS_ASSUME_NONNULL_BEGIN

/// 负责与助手通讯并维护插件列表状态
@interface PMStore : NSObject

@property (nonatomic, readonly, copy, nullable) NSString *injectDirectory;
@property (nonatomic, readonly, copy) NSArray<PMPluginItem *> *items;
@property (nonatomic, readonly) BOOL helperAvailable;

- (BOOL)reloadWithError:(NSError **)error;
- (BOOL)setEnabled:(BOOL)enabled forItem:(PMPluginItem *)item error:(NSError **)error;
- (BOOL)setEnabled:(BOOL)enabled forItems:(NSArray<PMPluginItem *> *)items error:(NSError **)error;

- (NSUInteger)enabledCount;

/// 该项自上次生效以来是否被改过
- (BOOL)isPending:(PMPluginItem *)item;

/// 按标识查条目（异步回调后取最新状态用）
- (nullable PMPluginItem *)itemWithIdentifier:(NSString *)identifier;

/// 本次启动以来改动过、但还没重启生效的插件数
- (NSUInteger)pendingCount;
- (NSArray<PMPluginItem *> *)pendingItems;
- (void)markEffective;

- (nullable NSString *)respringWithError:(NSError **)error;
- (nullable NSString *)rebootUserspaceWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
