#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PMStatusCell : UITableViewCell
- (void)configureWithDirectory:(nullable NSString *)directory
                    pluginCount:(NSUInteger)count
                   enabledCount:(NSUInteger)enabled
                   pendingCount:(NSUInteger)pending;
@end

NS_ASSUME_NONNULL_END
