#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PMToast : NSObject
/// 顶部悬浮提示，2 秒自动消失
+ (void)show:(NSString *)message inView:(UIView *)view style:(NSInteger)style;  // 0=普通 1=成功 2=失败
@end

NS_ASSUME_NONNULL_END
