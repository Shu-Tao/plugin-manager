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

@interface PMHelperClient : NSObject

+ (instancetype)sharedClient;

@property (nonatomic, readonly, copy, nullable) NSString *helperPath;
@property (nonatomic, readonly, assign) BOOL archiveAvailable;

- (BOOL)isAvailable;

- (nullable NSDictionary *)runCommand:(NSString *)command
                            arguments:(nullable NSArray<NSString *> *)arguments
                                error:(NSError **)error;

/// 同步
- (nullable NSDictionary *)listPluginsWithError:(NSError **)error;
- (BOOL)setPlugin:(NSString *)identifier enabled:(BOOL)enabled error:(NSError **)error;
- (nullable NSString *)respringWithError:(NSError **)error;
- (nullable NSString *)rebootUserspaceWithError:(NSError **)error;

/// 异步（文件操作，避免阻塞 UI）
- (void)resolvePluginPaths:(NSString *)identifier completion:(PMPathsCompletion)completion;
- (void)extractPlugin:(NSString *)identifier kind:(NSString *)kind completion:(PMDictCompletion)completion;
- (void)pluginInfo:(NSString *)identifier completion:(PMDictCompletion)completion;
- (void)backupPlugin:(NSString *)identifier completion:(PMDictCompletion)completion;
- (void)renamePlugin:(NSString *)identifier to:(NSString *)newName completion:(PMDictCompletion)completion;
- (void)debInfo:(NSString *)path completion:(PMDictCompletion)completion;
- (void)debugExtractDeb:(NSString *)path dylibsOnly:(BOOL)dylibsOnly completion:(PMDictCompletion)completion;

/// 探测 libarchive 可用性（结果缓存）
- (void)probeCapabilities:(PMDictCompletion)completion;

+ (NSString *)messageForError:(nullable NSError *)error;

@end

@interface PMHelperClient (Async)
- (void)runAsync:(NSString *)command
       arguments:(nullable NSArray<NSString *> *)arguments
      completion:(PMDictCompletion)completion;
@end

NS_ASSUME_NONNULL_END
