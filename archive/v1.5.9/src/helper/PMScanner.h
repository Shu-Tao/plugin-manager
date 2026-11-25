#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 扫描注入目录，返回插件条目数组（每项字段见 PMScanner.m 顶部注释）。
FOUNDATION_EXPORT NSArray<NSDictionary *> *PMScanPlugins(NSString *dir);

/// dpkg 归属查询（可能返回空串）
FOUNDATION_EXPORT NSString *PMPackageOwningFile(NSString *fileName);

NS_ASSUME_NONNULL_END
