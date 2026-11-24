#import "PMSwitchCell.h"
#import "PMTheme.h"

/// 箭头图标全局只创建一次并复用。
/// 自绘位图会让首屏 74 个 cell 各占一份缓冲，实测会触发
/// "VM - pmap_enter failed with resource shortage" 导致启动闪退。
static UIImage *PMChevronImage(BOOL pointingUp) {
    static UIImage *downImage = nil;
    static UIImage *upImage = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:9.0
                                                            weight:UIImageSymbolWeightBold];
        downImage = [UIImage systemImageNamed:@"chevron.down" withConfiguration:cfg];
        upImage   = [UIImage systemImageNamed:@"chevron.up" withConfiguration:cfg];
    });
    return pointingUp ? upImage : downImage;
}

static const CGFloat kBadgeSize = 34.0;
static const CGFloat kBadgeGap = 12.0;
static const CGFloat kToggleWidth = 51.0;
static const CGFloat kSideInset = 16.0;
static const CGFloat kChevronHitSize = 16.0;       // 点击热区（图形本身由 SF Symbol 决定）
static const CGFloat kChevronGap = 6.0;            // 与副标题的间距
static const CGFloat kChevronToggleGap = 8.0;      // 与开关左缘的间距

@interface PMSwitchCell ()
@property (nonatomic, strong) UIView *badgeContainer;
@property (nonatomic, strong) UILabel *badge;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *pendingLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIButton *chevronButton;
@property (nonatomic, strong) UISwitch *toggle;
@property (nonatomic, strong, nullable) NSLayoutConstraint *collapsedBottom;
@property (nonatomic, strong, nullable) NSLayoutConstraint *detailBottom;
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, assign) BOOL chevronDrawn;
@end

@implementation PMSwitchCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _badgeContainer = [UIView new];
    _badgeContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _badgeContainer.layer.cornerRadius = 9.0;
    _badgeContainer.layer.cornerCurve = kCACornerCurveContinuous;
    [self.contentView addSubview:_badgeContainer];

    _badge = [UILabel new];
    _badge.translatesAutoresizingMaskIntoConstraints = NO;
    _badge.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightBold];
    _badge.textColor = [UIColor whiteColor];
    _badge.textAlignment = NSTextAlignmentCenter;
    [_badgeContainer addSubview:_badge];

    _titleLabel = [UILabel new];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [PMTheme titleFont];
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleLabel.numberOfLines = 1;
    [_titleLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                 forAxis:UILayoutConstraintAxisHorizontal];
    [self.contentView addSubview:_titleLabel];

    _pendingLabel = [UILabel new];
    _pendingLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _pendingLabel.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightBold];
    _pendingLabel.textColor = [PMTheme warn];
    _pendingLabel.text = @"";
    [_pendingLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                   forAxis:UILayoutConstraintAxisHorizontal];
    [self.contentView addSubview:_pendingLabel];

    _subtitleLabel = [UILabel new];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.font = [PMTheme bodyFont];
    _subtitleLabel.textColor = [PMTheme secondaryText];
    _subtitleLabel.numberOfLines = 1;
    _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_subtitleLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                    forAxis:UILayoutConstraintAxisHorizontal];
    [self.contentView addSubview:_subtitleLabel];

    // 箭头：自绘小 V 形，宽高比拉开（角度更宽、两边更短）
    _chevronButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _chevronButton.translatesAutoresizingMaskIntoConstraints = NO;
    _chevronButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    _chevronButton.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    _chevronButton.tintColor = [PMTheme secondaryText];
    [_chevronButton addTarget:self action:@selector(chevronTapped) forControlEvents:UIControlEventTouchUpInside];
    // 注意：这里不绘制箭头。绘制移到 configureWithItem，避免在构造期
    // （启动流程中会被连续触发几十次）做位图渲染。
    [self.contentView addSubview:_chevronButton];

    _toggle = [UISwitch new];
    _toggle.translatesAutoresizingMaskIntoConstraints = NO;
    _toggle.onTintColor = [PMTheme ok];
    [_toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.contentView addSubview:_toggle];

    _detailLabel = [UILabel new];
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _detailLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
    _detailLabel.textColor = [PMTheme secondaryText];
    _detailLabel.numberOfLines = 0;
    _detailLabel.lineBreakMode = NSLineBreakByCharWrapping;
    _detailLabel.hidden = YES;
    [self.contentView addSubview:_detailLabel];

    [self buildConstraints];
    return self;
}

- (void)buildConstraints {
    // 横向：色块 | 标题列（弹性，占满） | 开关
    // 箭头放在标题列内部右下，不再切走一列宽度
    [NSLayoutConstraint activateConstraints:@[
        [_badgeContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:kSideInset],
        [_badgeContainer.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
        [_badgeContainer.widthAnchor constraintEqualToConstant:kBadgeSize],
        [_badgeContainer.heightAnchor constraintEqualToConstant:kBadgeSize],

        [_badge.centerXAnchor constraintEqualToAnchor:_badgeContainer.centerXAnchor],
        [_badge.centerYAnchor constraintEqualToAnchor:_badgeContainer.centerYAnchor],

        [_toggle.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-kSideInset],
        [_toggle.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:13],
        [_toggle.widthAnchor constraintEqualToConstant:kToggleWidth],

        [_titleLabel.leadingAnchor constraintEqualToAnchor:_badgeContainer.trailingAnchor constant:kBadgeGap],
        [_titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:11],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:_toggle.leadingAnchor constant:-10],

        [_pendingLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
        [_pendingLabel.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
        [_pendingLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_titleLabel.leadingAnchor],

        // 副标题：左边界同标题，右边界让给箭头
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
        [_subtitleLabel.trailingAnchor constraintEqualToAnchor:_chevronButton.leadingAnchor constant:-kChevronGap],

        // 箭头：贴在开关左缘外侧，y 与副标题行对齐（不与开关重叠）
        [_chevronButton.trailingAnchor constraintEqualToAnchor:_toggle.leadingAnchor constant:-kChevronToggleGap],
        [_chevronButton.centerYAnchor constraintEqualToAnchor:_subtitleLabel.centerYAnchor],
        [_chevronButton.widthAnchor constraintEqualToConstant:kChevronHitSize],
        [_chevronButton.heightAnchor constraintEqualToConstant:kChevronHitSize],
    ]];

    // 折叠态：副标题收底
    NSLayoutConstraint *collapsed =
        [_subtitleLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-11];
    collapsed.priority = 999;
    collapsed.active = YES;
    _collapsedBottom = collapsed;

    // 展开态：详情参与高度
    [[_detailLabel.leadingAnchor constraintEqualToAnchor:_subtitleLabel.leadingAnchor] setActive:YES];
    _detailBottom = [_detailLabel.trailingAnchor constraintEqualToAnchor:_toggle.leadingAnchor constant:-kChevronToggleGap];
    _detailBottom.active = YES;
    [[_detailLabel.topAnchor constraintEqualToAnchor:_subtitleLabel.bottomAnchor constant:8] setActive:YES];
    NSLayoutConstraint *db =
        [_detailLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10];
    db.priority = 998;
    db.active = NO;
    self.detailBottom = db;
}

- (void)configureWithItem:(PMPluginItem *)item
                  enabled:(BOOL)enabled
                  pending:(BOOL)pending
                 expanded:(BOOL)expanded {
    self.titleLabel.text = item.identifier;
    self.subtitleLabel.text = [item subtitleText];
    self.badge.text = [PMTheme initialForIdentifier:item.identifier];
    self.badgeContainer.backgroundColor = [PMTheme colorForIdentifier:item.identifier];
    self.toggle.on = enabled;
    self.pendingLabel.text = pending ? @"待重启" : @"";
    self.titleLabel.textColor = enabled ? [UIColor labelColor] : [UIColor secondaryLabelColor];

    self.expanded = expanded;
    self.detailLabel.text = expanded ? [item detailText] : @"";
    self.detailLabel.hidden = !expanded;
    self.collapsedBottom.active = !expanded;
    self.detailBottom.active = expanded;
    // 绘制唯一入口：构造期不画，只在真正要显示内容时画
    [self setChevronExpanded:expanded];
    self.chevronDrawn = YES;
}

- (void)setChevronExpanded:(BOOL)expanded {
    if (!self.chevronButton) return;
    // 共享静态图：不在这里创建位图，避免每个 cell 各占一份内存
    UIImage *glyph = PMChevronImage(expanded);
    if (glyph) {
        [self.chevronButton setImage:glyph forState:UIControlStateNormal];
    }
    self.chevronButton.tintColor = expanded ? [PMTheme accent] : [PMTheme secondaryText];
    self.chevronButton.accessibilityLabel = expanded ? @"收起详情" : @"展开详情";
}

- (void)setToggleEnabled:(BOOL)enabled {
    self.toggle.enabled = enabled;
    self.contentView.alpha = enabled ? 1.0 : 0.55;
    self.chevronButton.enabled = YES;
}

- (void)toggleChanged:(UISwitch *)sender {
    if (self.onToggle) self.onToggle(sender.isOn);
}

- (void)chevronTapped {
    if (self.onExpand) self.onExpand();
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.onToggle = nil;
    self.onExpand = nil;
    self.pendingLabel.text = @"";
    self.detailLabel.text = @"";
    self.detailLabel.hidden = YES;
    self.detailBottom.active = NO;
    self.collapsedBottom.active = YES;
    self.expanded = NO;
    self.chevronDrawn = NO;
    self.contentView.alpha = 1.0;
    self.toggle.enabled = YES;
}

+ (CGFloat)expandedExtraHeightForItem:(PMPluginItem *)item width:(CGFloat)width {
    NSString *text = [item detailText];
    if (text.length == 0) return 0;
    CGFloat textWidth = width - kSideInset * 2 - kBadgeSize - kBadgeGap;
    if (textWidth < 80) textWidth = 80;
    UIFont *font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
    CGRect bound = [text boundingRectWithSize:CGSizeMake(textWidth, CGFLOAT_MAX)
                                      options:NSStringDrawingUsesLineFragmentOrigin
                                   attributes:@{ NSFontAttributeName: font }
                                      context:nil];
    return ceil(bound.size.height) + 20.0;
}

@end
