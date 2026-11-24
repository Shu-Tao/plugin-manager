#import "PMStatusCell.h"
#import "PMTheme.h"

@interface PMStatusCell ()
@property (nonatomic, strong) UILabel *statLabel;
@property (nonatomic, strong) UILabel *dirLabel;
@property (nonatomic, strong) UIView *pendingBox;
@property (nonatomic, strong) UILabel *pendingLabel;
@property (nonatomic, strong) UIStackView *stack;
@end

@implementation PMStatusCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _statLabel = [UILabel new];
        _statLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        _statLabel.numberOfLines = 0;

        _dirLabel = [UILabel new];
        _dirLabel.font = [PMTheme monoSmallFont];
        _dirLabel.textColor = [PMTheme secondaryText];
        _dirLabel.numberOfLines = 2;
        _dirLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

        _pendingLabel = [UILabel new];
        _pendingLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
        _pendingLabel.textColor = [PMTheme warn];
        _pendingLabel.numberOfLines = 0;

        _pendingBox = [UIView new];
        _pendingBox.layer.cornerRadius = 10.0;
        _pendingBox.layer.cornerCurve = kCACornerCurveContinuous;
        _pendingBox.backgroundColor = [[PMTheme warn] colorWithAlphaComponent:0.16];
        _pendingBox.layoutMargins = UIEdgeInsetsMake(8, 10, 8, 10);
        [_pendingBox addSubview:_pendingLabel];
        _pendingLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [_pendingLabel.topAnchor constraintEqualToAnchor:_pendingBox.layoutMarginsGuide.topAnchor],
            [_pendingLabel.bottomAnchor constraintEqualToAnchor:_pendingBox.layoutMarginsGuide.bottomAnchor],
            [_pendingLabel.leadingAnchor constraintEqualToAnchor:_pendingBox.layoutMarginsGuide.leadingAnchor],
            [_pendingLabel.trailingAnchor constraintEqualToAnchor:_pendingBox.layoutMarginsGuide.trailingAnchor],
        ]];

        // 用 StackView 排布：隐藏时自动折叠，不需要手动增删约束
        _stack = [[UIStackView alloc] initWithArrangedSubviews:@[_statLabel, _dirLabel, _pendingBox]];
        _stack.axis = UILayoutConstraintAxisVertical;
        _stack.alignment = UIStackViewAlignmentFill;
        _stack.spacing = 6.0;
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_stack];

        UILayoutGuide *m = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [_stack.topAnchor constraintEqualToAnchor:m.topAnchor constant:11],
            [_stack.bottomAnchor constraintEqualToAnchor:m.bottomAnchor constant:-11],
            [_stack.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
            [_stack.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        ]];

        [_statLabel setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisVertical];
    }
    return self;
}

- (void)configureWithDirectory:(NSString *)directory
                   pluginCount:(NSUInteger)count
                  enabledCount:(NSUInteger)enabled
                  pendingCount:(NSUInteger)pending {
    self.dirLabel.text = directory.length ? directory : @"未检测到插件注入目录";
    self.statLabel.text = [NSString stringWithFormat:@"共 %lu 个插件 · 已启用 %lu",
                           (unsigned long)count, (unsigned long)enabled];

    BOOL show = pending > 0;
    self.pendingBox.hidden = !show;
    self.pendingLabel.text = show
        ? [NSString stringWithFormat:@"%lu 项改动已写盘，重启 SpringBoard 或用户空间后生效", (unsigned long)pending]
        : @"";
}

@end
