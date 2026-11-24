#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 与 pmhelper list 返回条目一一对应
@interface PMPluginItem : NSObject

@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *dylibName;
@property (nonatomic, copy) NSString *plistName;
@property (nonatomic, copy) NSString *package;
@property (nonatomic, copy) NSArray<NSString *> *bundles;
@property (nonatomic, copy) NSArray<NSString *> *executables;
@property (nonatomic, assign) BOOL enabled;          ///< 磁盘当前状态（每次操作成功后即时更新）
@property (nonatomic, assign) unsigned long long bytes;
@property (nonatomic, assign) long long mtime;

+ (instancetype)itemWithDictionary:(NSDictionary *)dict;

/// 一行用途摘要（列表折叠态显示）
- (NSString *)subtitleText;

/// 展开后的详细信息（多行）
- (NSString *)detailText;

@end

NS_ASSUME_NONNULL_END
