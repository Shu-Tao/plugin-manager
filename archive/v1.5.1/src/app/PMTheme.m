#import "PMTheme.h"

@implementation PMTheme

+ (UIColor *)accent  { return [UIColor colorWithRed:0.35 green:0.51 blue:1.00 alpha:1.0]; }
+ (UIColor *)danger  { return [UIColor colorWithRed:0.96 green:0.32 blue:0.32 alpha:1.0]; }
+ (UIColor *)ok      { return [UIColor colorWithRed:0.24 green:0.78 blue:0.47 alpha:1.0]; }
+ (UIColor *)warn    { return [UIColor colorWithRed:0.98 green:0.68 blue:0.20 alpha:1.0]; }

+ (UIColor *)cardBackground {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:0.13 alpha:1.0];
        }
        return [UIColor colorWithWhite:0.96 alpha:1.0];
    }];
}

+ (UIColor *)secondaryText { return [UIColor secondaryLabelColor]; }

+ (UIFont *)titleFont { return [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold]; }
+ (UIFont *)bodyFont  { return [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular]; }
+ (UIFont *)monoSmallFont { return [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular]; }

+ (UIColor *)colorForIdentifier:(NSString *)identifier {
    uint32_t hash = 2166136261u;
    const char *s = identifier.UTF8String ?: "";
    for (size_t i = 0; i < strlen(s); i++) {
        hash ^= (uint8_t)s[i];
        hash *= 16777619u;
    }
    CGFloat hue = (CGFloat)(hash % 360) / 360.0;
    return [UIColor colorWithHue:hue saturation:0.55 brightness:0.85 alpha:1.0];
}

+ (NSString *)initialForIdentifier:(NSString *)identifier {
    if (identifier.length == 0) return @"?";
    NSString *first = [[identifier substringToIndex:1] uppercaseString];
    return first;
}

@end
