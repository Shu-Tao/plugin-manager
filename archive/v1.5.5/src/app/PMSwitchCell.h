#import <UIKit/UIKit.h>
#import "PMPluginItem.h"

NS_ASSUME_NONNULL_BEGIN

@interface PMSwitchCell : UITableViewCell

/// 开关被拨动
@property (nonatomic, copy, nullable) void (^onToggle)(BOOL enabled);
/// 点击了展开/收起箭头
@property (nonatomic, copy, nullable) void (^onExpand)(void);

/// pending = 本次改动尚未重启生效
- (void)configureWithItem:(PMPluginItem *)item
                  enabled:(BOOL)enabled
                  pending:(BOOL)pending
                 expanded:(BOOL)expanded;

- (void)setToggleEnabled:(BOOL)enabled;

/// 供列表计算展开后的高度
+ (CGFloat)expandedExtraHeightForItem:(PMPluginItem *)item width:(CGFloat)width;

@end

NS_ASSUME_NONNULL_END
