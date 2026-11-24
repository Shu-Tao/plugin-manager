#import "PMToast.h"
#import "PMTheme.h"

@implementation PMToast

+ (void)show:(NSString *)message inView:(UIView *)view style:(NSInteger)style {
    if (message.length == 0 || view == nil) return;

    UIView *container = [UIView new];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.layer.cornerRadius = 14.0;
    container.layer.cornerCurve = kCACornerCurveContinuous;
    container.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return tc.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:0.22 alpha:0.98]
            : [UIColor colorWithWhite:0.12 alpha:0.96];
    }];
    container.alpha = 0.0;

    UIView *dot = [UIView new];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.layer.cornerRadius = 4.0;
    dot.backgroundColor = style == 1 ? [PMTheme ok] : (style == 2 ? [PMTheme danger] : [PMTheme accent]);
    [container addSubview:dot];

    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = message;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    label.numberOfLines = 3;
    [container addSubview:label];

    [view addSubview:container];
    UILayoutGuide *safe = view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [container.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [container.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [container.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:16],
        [container.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-16],

        [dot.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:14],
        [dot.centerYAnchor constraintEqualToAnchor:label.centerYAnchor],
        [dot.widthAnchor constraintEqualToConstant:8],
        [dot.heightAnchor constraintEqualToConstant:8],

        [label.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:10],
        [label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-14],
        [label.topAnchor constraintEqualToAnchor:container.topAnchor constant:10],
        [label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-10],
    ]];

    [UIView animateWithDuration:0.18 animations:^{
        container.alpha = 1.0;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.25 delay:2.0 options:UIViewAnimationOptionCurveEaseIn animations:^{
            container.alpha = 0.0;
        } completion:^(BOOL done) {
            [container removeFromSuperview];
        }];
    }];
}

@end
