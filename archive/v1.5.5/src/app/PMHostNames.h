#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 把 Bundle ID / 可执行名翻成人话用途。返回 nil 表示没收录。
FOUNDATION_EXPORT NSString *_Nullable PMDescribeHost(NSString *identifier);

/// 把一条插件条目的过滤目标拼成一行中文用途描述。
FOUNDATION_EXPORT NSString *PMDescribeTargets(NSArray<NSString *> *bundles,
                                              NSArray<NSString *> *executables);

NS_ASSUME_NONNULL_END
