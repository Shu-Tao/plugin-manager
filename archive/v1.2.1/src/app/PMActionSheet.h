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

@end

NS_ASSUME_NONNULL_END
