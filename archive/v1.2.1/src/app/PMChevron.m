#import "PMChevron.h"

@implementation PMChevron

+ (UIImage *)imageWithWidth:(CGFloat)width
                     height:(CGFloat)height
                     stroke:(CGFloat)stroke
                      color:(UIColor *)color
                 pointingUp:(BOOL)pointingUp {
    if (width <= 0 || height <= 0) return nil;
    CGFloat w = width;
    CGFloat h = height;
    CGFloat sw = MAX(stroke, 0.5);

    // 线宽的一半要留出来，否则圆头会被裁掉
    CGFloat pad = sw / 2.0 + 0.5;
    CGSize canvas = CGSizeMake(w + pad * 2, h + pad * 2);

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvas format:fmt];

    UIImage *img = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef cg = ctx.CGContext;
        CGContextSetShouldAntialias(cg, YES);
        [color setStroke];

        CGFloat top = pad;
        CGFloat bottom = pad + h;
        if (pointingUp) {
            // 顶点在上，两翼在下
            top = pad + h;
            bottom = pad;
        }

        UIBezierPath *path = [UIBezierPath bezierPath];
        path.lineWidth = sw;
        path.lineCapStyle = kCGLineCapRound;
        path.lineJoinStyle = kCGLineJoinRound;

        [path moveToPoint:CGPointMake(pad, top)];
        [path addLineToPoint:CGPointMake(pad + w / 2.0, bottom)];
        [path addLineToPoint:CGPointMake(pad + w, top)];
        [path stroke];
    }];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

@end
