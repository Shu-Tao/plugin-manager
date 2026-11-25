#import <UIKit/UIKit.h>
#import "PMPluginItem.h"

NS_ASSUME_NONNULL_BEGIN

/// 插件详情面板：显示标识、路径、大小、软件包，并提供注销入口
@interface PMActionSheet : NSObject

+ (void)presentForPlugin:(PMPluginItem *)item
                    from:(UIViewController *)host;

/// 在指定控制器上弹 alert（避免被操作面板自身遮挡）
+ (void)presentAlert:(UIAlertController *)alert from:(UIViewController *)host;

@end

NS_ASSUME_NONNULL_END
