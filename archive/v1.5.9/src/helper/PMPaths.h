//
//  PMPaths.h — 注入目录与关键路径探测
//  PluginManager helper (setuid root)
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 返回第一个存在的插件注入目录（已 realpath，去重）。
/// 顺序：/var/jb/usr/lib/TweakInject → /var/jb/Library/MobileSubstrate/DynamicLibraries
///      → /usr/lib/TweakInject → /Library/MobileSubstrate/DynamicLibraries
FOUNDATION_EXPORT NSString *_Nullable PMResolveInjectDirectory(void);

/// JB 根前缀：/var/jb 存在则为 @"/var/jb"，否则 @"" （rootful）
FOUNDATION_EXPORT NSString *PMJBRoot(void);

FOUNDATION_EXPORT BOOL PMIsDirectory(NSString *path);
FOUNDATION_EXPORT BOOL PMIsRegularFile(NSString *path);
FOUNDATION_EXPORT BOOL PMIsSymlink(NSString *path);

NS_ASSUME_NONNULL_END
