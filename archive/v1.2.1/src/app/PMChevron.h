#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 自绘 V 形箭头，替换 SF Symbol —— 后者夹角与边长固定，无法按要求调整。
@interface PMChevron : NSObject

/// @param width     整个字形的宽（越大则角越宽）
/// @param height    整个字形的高（越小则角的两边越短）
/// @param stroke    线宽
/// @param color     线条颜色
/// @param pointingUp 朝上为展开态
+ (UIImage *)imageWithWidth:(CGFloat)width
                     height:(CGFloat)height
                     stroke:(CGFloat)stroke
                      color:(UIColor *)color
                 pointingUp:(BOOL)pointingUp;

@end

NS_ASSUME_NONNULL_END
