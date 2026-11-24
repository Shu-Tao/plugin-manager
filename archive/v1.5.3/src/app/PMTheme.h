#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PMTheme : NSObject
+ (UIColor *)accent;
+ (UIColor *)danger;
+ (UIColor *)ok;
+ (UIColor *)warn;
+ (UIColor *)cardBackground;
+ (UIColor *)secondaryText;
+ (UIFont *)titleFont;
+ (UIFont *)bodyFont;
+ (UIFont *)monoSmallFont;
/// 依据字符串稳定取一个色块颜色
+ (UIColor *)colorForIdentifier:(NSString *)identifier;
+ (NSString *)initialForIdentifier:(NSString *)identifier;
@end

NS_ASSUME_NONNULL_END
