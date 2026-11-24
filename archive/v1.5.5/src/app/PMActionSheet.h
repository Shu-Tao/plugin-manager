#import <UIKit/UIKit.h>
#import "PMPluginItem.h"

NS_ASSUME_NONNULL_BEGIN

@interface PMActionSheet : NSObject

/// 插件操作面板（分享 / 提取 / 包信息 / 备份 / 改名 / 停用）
+ (void)presentForPlugin:(PMPluginItem *)item
                    from:(UIViewController *)host
               onRefresh:(nullable void (^)(void))onRefresh;

/// deb 文件操作面板（解压 / 提取 dylib / 包信息 / 分享 / 删除副本）
+ (void)presentForDebAtPath:(NSString *)path
                       from:(UIViewController *)host
                  onRefresh:(nullable void (^)(void))onRefresh;

/// 用系统分享面板分享若干文件
+ (void)sharePaths:(NSArray<NSString *> *)paths;

/// 弹提取选项对话框（dylib / plist 可勾选）
+ (void)presentExtractOptionsForPlugin:(PMPluginItem *)item;
+ (void)presentExtractOptionsForPlugin:(PMPluginItem *)item
                        preselectDylib:(BOOL)dylib
                         preselectPlist:(BOOL)plist;
+ (void)performExtractForPlugin:(PMPluginItem *)item dylib:(BOOL)dylib plist:(BOOL)plist deb:(BOOL)deb;
+ (id)newSheetDelegate;

/// 把 deb 文件本身复制到 PluginManager 目录
+ (void)extractDebFileToStore:(NSString *)path;

/// 在指定控制器上弹 alert（避免被操作面板自身遮挡）
+ (void)presentAlert:(UIAlertController *)alert from:(UIViewController *)host;

/// 删除确认 + 走助手 root 权限执行
+ (void)confirmDeletePath:(NSString *)path onRefresh:(nullable void (^)(void))onRefresh;

@end

NS_ASSUME_NONNULL_END
