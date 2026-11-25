#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const PMHelperErrorDomain;

typedef NS_ENUM(NSInteger, PMHelperErrorCode) {
    PMHelperErrorUnavailable = 1,
    PMHelperErrorSpawnFailed = 2,
    PMHelperErrorTimeout = 3,
    PMHelperErrorBadOutput = 4,
    PMHelperErrorHelperReported = 5,
};

typedef void (^PMDictCompletion)(NSDictionary *_Nullable result, NSError *_Nullable error);
typedef void (^PMPathsCompletion)(NSArray<NSString *> *_Nullable paths, NSError *_Nullable error);

/// 与特权助手通信的客户端。
/// 2.0.0 精简：只保留列表、开关、注销、重启用户空间四类能力。
@interface PMHelperClient : NSObject

+ (instancetype)sharedClient;

@property (nonatomic, readonly, copy, nullable) NSString *helperPath;

- (BOOL)isAvailable;

- (nullable NSDictionary *)runCommand:(NSString *)command
                            arguments:(nullable NSArray<NSString *> *)arguments
                                error:(NSError **)error;

/// 列出所有注入型插件
- (nullable NSDictionary *)listPluginsWithError:(NSError **)error;

/// 开关单个插件
- (BOOL)setPlugin:(NSString *)identifier enabled:(BOOL)enabled error:(NSError **)error;

/// 重启 SpringBoard（注销）
- (nullable NSString *)respringWithError:(NSError **)error;

/// 重启用户空间
- (nullable NSString *)rebootUserspaceWithError:(NSError **)error;

/// 把助手的错误翻译成可读文案
+ (NSString *)messageForError:(nullable NSError *)error;

@end

NS_ASSUME_NONNULL_END
