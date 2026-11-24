#import "PMHelperClient.h"
#import <spawn.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <signal.h>

extern char **environ;

NSString *const PMHelperErrorDomain = @"com.yg.pluginmanager.helper";

@interface PMHelperClient ()
@property (nonatomic, readwrite, copy, nullable) NSString *helperPath;
@property (nonatomic, readwrite, assign) BOOL archiveAvailable;
@end

static NSString *const kErrorCodeKey = @"PMHelperCode";
static NSString *const kErrorDetailKey = @"PMHelperDetail";

@implementation PMHelperClient

+ (instancetype)sharedClient {
    static PMHelperClient *client = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ client = [PMHelperClient new]; });
    return client;
}

- (NSString *)helperPath {
    if (_helperPath) return _helperPath;
    NSString *jb = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"] ? @"/var/jb" : @"";
    NSArray<NSString *> *candidates = @[
        @"/var/jb/usr/libexec/pluginmanager/pmhelper",
        @"/usr/libexec/pluginmanager/pmhelper",
        [jb stringByAppendingString:@"/usr/libexec/pluginmanager/pmhelper"],
    ];
    for (NSString *path in candidates) {
        if (path.length == 0) continue;
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG) {
            _helperPath = [path copy];
            return _helperPath;
        }
    }
    return nil;
}

- (BOOL)isAvailable {
    NSString *path = self.helperPath;
    if (path.length == 0) return NO;
    return access(path.fileSystemRepresentation, X_OK) == 0;
}

- (NSDictionary *)runCommand:(NSString *)command
                   arguments:(NSArray<NSString *> *)arguments
                       error:(NSError **)error {
    NSString *path = self.helperPath;
    if (path.length == 0 || !self.isAvailable) {
        if (error) {
            *error = [NSError errorWithDomain:PMHelperErrorDomain code:PMHelperErrorUnavailable
                                     userInfo:@{NSLocalizedDescriptionKey: @"未找到特权助手 pmhelper，请重新安装插件管理器"}];
        }
        return nil;
    }

    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"pmhelper-%@.out", NSUUID.UUID.UUIDString]];

    NSMutableArray<NSString *> *all = [NSMutableArray arrayWithObject:path];
    [all addObject:command];
    if (arguments.count) [all addObjectsFromArray:arguments];

    char **argv = calloc(all.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < all.count; i++) argv[i] = strdup(all[i].fileSystemRepresentation);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, outPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, path.fileSystemRepresentation, &actions, NULL, argv, environ);
    for (NSUInteger i = 0; i < all.count; i++) free(argv[i]);
    free(argv);
    posix_spawn_file_actions_destroy(&actions);

    if (rc != 0 || pid <= 0) {
        [[NSFileManager defaultManager] removeItemAtPath:outPath error:NULL];
        if (error) {
            *error = [NSError errorWithDomain:PMHelperErrorDomain code:PMHelperErrorSpawnFailed
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"启动助手失败：%s", strerror(rc)]}];
        }
        return nil;
    }

    int status = 0;
    BOOL finished = NO;
    for (int i = 0; i < 150; i++) {          // 最长 15 秒
        pid_t got = waitpid(pid, &status, WNOHANG);
        if (got == pid) { finished = YES; break; }
        usleep(100000);
    }
    if (!finished) {
        kill(pid, SIGKILL);
        waitpid(pid, &status, 0);
        [[NSFileManager defaultManager] removeItemAtPath:outPath error:NULL];
        if (error) {
            *error = [NSError errorWithDomain:PMHelperErrorDomain code:PMHelperErrorTimeout
                                     userInfo:@{NSLocalizedDescriptionKey: @"助手响应超时"}];
        }
        return nil;
    }

    NSData *data = [NSData dataWithContentsOfFile:outPath];
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:NULL];
    if (data.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:PMHelperErrorDomain code:PMHelperErrorBadOutput
                                     userInfo:@{NSLocalizedDescriptionKey: @"助手无输出（可能未以 root 身份运行）"}];
        }
        return nil;
    }

    NSError *jsonError = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![parsed isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:PMHelperErrorDomain code:PMHelperErrorBadOutput
                                     userInfo:@{NSLocalizedDescriptionKey: @"助手输出无法解析"}];
        }
        return nil;
    }
    NSDictionary *dict = parsed;
    if (![dict[@"ok"] boolValue]) {
        NSString *code = dict[@"error"] ?: @"E_UNKNOWN";
        NSString *detail = dict[@"detail"] ?: @"";
        if (error) {
            *error = [NSError errorWithDomain:PMHelperErrorDomain code:PMHelperErrorHelperReported
                                     userInfo:@{NSLocalizedDescriptionKey: detail.length ? detail : code,
                                                kErrorCodeKey: code,
                                                kErrorDetailKey: detail}];
        }
        return nil;
    }
    return dict;
}

- (NSDictionary *)listPluginsWithError:(NSError **)error {
    return [self runCommand:@"list" arguments:nil error:error];
}

- (BOOL)setPlugin:(NSString *)identifier enabled:(BOOL)enabled error:(NSError **)error {
    NSDictionary *result = [self runCommand:@"set"
                                 arguments:@[@"--id", identifier, @"--state", enabled ? @"enabled" : @"disabled"]
                                     error:error];
    return result != nil;
}

- (NSString *)respringWithError:(NSError **)error {
    NSDictionary *result = [self runCommand:@"respring" arguments:nil error:error];
    return result[@"method"];
}

- (NSString *)rebootUserspaceWithError:(NSError **)error {
    NSDictionary *result = [self runCommand:@"reboot-userspace" arguments:nil error:error];
    return result[@"method"];
}

#pragma mark - 异步封装

- (void)runAsync:(NSString *)command
       arguments:(nullable NSArray<NSString *> *)arguments
      completion:(PMDictCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSDictionary *result = [self runCommand:command arguments:arguments error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(result, error);
        });
    });
}

- (void)resolvePluginPaths:(NSString *)identifier completion:(PMPathsCompletion)completion {
    [self runAsync:@"plugin-paths" arguments:@[@"--id", identifier ?: @""] completion:^(NSDictionary *r, NSError *e) {
        if (!completion) return;
        if (!r) { completion(nil, e); return; }
        NSArray *files = r[@"files"];
        completion([files isKindOfClass:[NSArray class]] ? files : @[], nil);
    }];
}

- (void)extractPlugin:(NSString *)identifier kind:(NSString *)kind completion:(PMDictCompletion)completion {
    [self runAsync:@"extract" arguments:@[@"--id", identifier ?: @"", @"--kind", kind ?: @"both"] completion:completion];
}

- (void)pluginInfo:(NSString *)identifier completion:(PMDictCompletion)completion {
    [self runAsync:@"plugin-info" arguments:@[@"--id", identifier ?: @""] completion:completion];
}

- (void)backupPlugin:(NSString *)identifier completion:(PMDictCompletion)completion {
    [self runAsync:@"backup" arguments:@[@"--id", identifier ?: @""] completion:completion];
}

- (void)renamePlugin:(NSString *)identifier to:(NSString *)newName completion:(PMDictCompletion)completion {
    [self runAsync:@"rename" arguments:@[@"--id", identifier ?: @"", @"--to", newName ?: @""] completion:completion];
}

- (void)debInfo:(NSString *)path completion:(PMDictCompletion)completion {
    [self runAsync:@"deb-info" arguments:@[@"--path", path ?: @""] completion:completion];
}

- (void)debugExtractDeb:(NSString *)path dylibsOnly:(BOOL)dylibsOnly completion:(PMDictCompletion)completion {
    NSMutableArray *args = [NSMutableArray arrayWithArray:@[@"--path", path ?: @""]];
    if (dylibsOnly) [args addObject:@"--dylibs-only"];
    [self runAsync:@"deb-extract" arguments:args completion:completion];
}

- (void)probeCapabilities:(PMDictCompletion)completion {
    [self runAsync:@"capabilities" arguments:nil completion:^(NSDictionary *r, NSError *e) {
        if (r) {
            self->_archiveAvailable = [r[@"archive"] boolValue];
        }
        if (completion) completion(r, e);
    }];
}

+ (NSString *)messageForError:(NSError *)error {
    if (!error) return @"";
    NSString *code = error.userInfo[kErrorCodeKey] ?: @"";
    NSString *detail = error.userInfo[kErrorDetailKey] ?: error.localizedDescription ?: @"";
    NSDictionary<NSString *, NSString *> *map = @{
        @"E_NOT_ROOT": @"助手没有 root 权限",
        @"E_NO_DIR": @"未检测到插件注入目录",
        @"E_BAD_ID": @"插件标识非法",
        @"E_BAD_STATE": @"状态参数非法",
        @"E_NOENT": @"插件文件不存在",
        @"E_NOSTATE": @"状态与请求一致，无需改动",
        @"E_IO": @"文件操作失败",
        @"E_NO_TOOL": @"系统工具缺失",
        @"E_USAGE": @"参数错误",
        @"E_JSON": @"序列化失败",
    };
    NSString *friendly = map[code];
    if (friendly.length == 0) return detail.length ? detail : @"未知错误";
    return detail.length ? [NSString stringWithFormat:@"%@（%@）", friendly, detail] : friendly;
}

@end