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

/// 把 deb 文件本身复制到 PluginManager 目录
- (void)copyDebToStore:(NSString *)path completion:(PMDictCompletion)completion;

/// 由助手（root）删除 PluginManager 目录内的副本
- (void)removeCopy:(NSString *)path completion:(PMDictCompletion)completion;

/// 解压 zip
- (void)zipExtract:(NSString *)path completion:(PMDictCompletion)completion;

/// 查询插件的 deb 可得性（缓存 / 重打包 / 不可得）
- (void)debSourceForPlugin:(NSString *)identifier completion:(PMDictCompletion)completion;

/// 清空白名单目录内容
- (void)clearDir:(NSString *)path completion:(PMDictCompletion)completion;

/// 把若干文件打包成 zip，返回 {"path": "...", "bytes": n}
- (void)zipPack:(NSArray<NSString *> *)paths name:(NSString *)name completion:(PMDictCompletion)completion;

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
