//
//  pmhelper — PluginManager 的特权助手（setuid root）
//  用法：
//    pmhelper list
//    pmhelper set --id <Name> --state enabled|disabled
//    pmhelper respring
//    pmhelper reboot-userspace
//    pmhelper version
//  stdout 只输出单行 JSON；诊断信息走 stderr。
//

#import <Foundation/Foundation.h>
#import <unistd.h>
#import <sys/stat.h>
#import <errno.h>
#import <string.h>
#import <spawn.h>
#import <signal.h>
#import <pwd.h>
#import "PMPaths.h"
#import "PMScanner.h"
#import "PMFsOps.h"
#import "PMProcOps.h"

// 前向声明：这些函数定义在文件后半部分，但前面的 PMCmdExtract 需要调用
static NSString *PMMaterializeDeb(NSString *pkg, NSString *outDir,
                                  NSString **errCode, NSString **errDetail);
#import <signal.h>

extern char **environ;

static const char *kVersion = "1.0.0";

static void PMEmit(NSDictionary *payload) {
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&err];
    if (!data) {
        fputs("{\"ok\":false,\"error\":\"E_JSON\",\"detail\":\"serialize failed\"}\n", stdout);
        fflush(stdout);
        return;
    }
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static int PMFail(NSString *code, NSString *detail) {
    PMEmit(@{@"ok": @NO, @"error": code, @"detail": detail ?: @""});
    return 1;
}

static BOOL PMValidIdent(NSString *ident) {
    if (ident.length == 0) return NO;
    return pm_valid_id(ident.UTF8String) == 1;
}

/// 把 PMFsOps 的错误码翻成协议错误码
static NSString *PMCodeForError(int rc) {
    switch (rc) {
        case PM_ERR_BAD_ID: return @"E_BAD_ID";
        case PM_ERR_NO_DIR: return @"E_NO_DIR";
        case PM_ERR_NOENT: return @"E_NOENT";
        case PM_ERR_NOSTATE: return @"E_NOSTATE";
        case PM_ERR_IO: return @"E_IO";
        case PM_ERR_USAGE: return @"E_USAGE";
        default: return @"E_UNKNOWN";
    }
}

static NSString *PMDetailForError(int rc) {
    switch (rc) {
        case PM_ERR_BAD_ID: return @"插件标识非法";
        case PM_ERR_NO_DIR: return @"未找到插件注入目录";
        case PM_ERR_NOENT: return @"该插件的 dylib 不存在";
        case PM_ERR_NOSTATE: return @"状态与请求一致，无需改动";
        case PM_ERR_IO: return @"文件操作失败（可能目标已存在或为符号链接）";
        case PM_ERR_USAGE: return @"参数错误";
        default: return @"未知错误";
    }
}

static int PMCmdList(void) {
    NSString *dir = PMResolveInjectDirectory();
    if (!dir) return PMFail(@"E_NO_DIR", @"未找到插件注入目录（TweakInject / DynamicLibraries）");
    NSArray<NSDictionary *> *items = PMScanPlugins(dir);
    PMEmit(@{@"ok": @YES, @"dir": dir, @"jbroot": PMJBRoot(), @"count": @(items.count), @"items": items});
    return 0;
}

static int PMCmdSet(NSString *ident, NSString *state) {
    BOOL wantEnabled;
    if ([state isEqualToString:@"enabled"]) wantEnabled = YES;
    else if ([state isEqualToString:@"disabled"]) wantEnabled = NO;
    else return PMFail(@"E_BAD_STATE", @"state 必须是 enabled 或 disabled");

    NSString *dir = PMResolveInjectDirectory();
    if (!dir) return PMFail(@"E_NO_DIR", @"未找到插件注入目录（TweakInject / DynamicLibraries）");

    // 走与单元测试同一份实现：规划 -> 执行 -> 失败回滚
    char from[2][PM_PATH_MAX];
    char to[2][PM_PATH_MAX];
    int count = 0;
    int rc = pm_plan_switch(dir.fileSystemRepresentation, ident.UTF8String, wantEnabled ? 1 : 0,
                            from, to, &count);
    if (rc != PM_OK) return PMFail(PMCodeForError(rc), PMDetailForError(rc));

    NSMutableArray<NSString *> *moved = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        [moved addObject:[[NSString stringWithUTF8String:to[i]] lastPathComponent]];
    }

    rc = pm_apply_plan(from, to, count);
    if (rc != PM_OK) return PMFail(PMCodeForError(rc), PMDetailForError(rc));

    PMEmit(@{@"ok": @YES, @"id": ident, @"state": wantEnabled ? @"enabled" : @"disabled", @"moved": moved});
    return 0;
}

static BOOL PMRunTool(NSString *path, NSArray<NSString *> *args) {
    if (!PMIsRegularFile(path)) return NO;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    NSMutableArray<NSString *> *all = [NSMutableArray arrayWithObject:path];
    [all addObjectsFromArray:args];
    char **argv = calloc(all.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < all.count; i++) argv[i] = strdup(all[i].fileSystemRepresentation);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, path.fileSystemRepresentation, &actions, NULL, argv, environ);
    for (NSUInteger i = 0; i < all.count; i++) free(argv[i]);
    free(argv);
    posix_spawn_file_actions_destroy(&actions);
    if (rc != 0 || pid <= 0) return NO;

    int status = 0;
    for (int i = 0; i < 40; i++) {          // 最多等 4 秒
        pid_t got = waitpid(pid, &status, WNOHANG);
        if (got == pid) return WIFEXITED(status) && WEXITSTATUS(status) == 0;
        usleep(100000);
    }
    return YES;                              // 已拉起但未退出，视为成功
}

/// 在若干目录里找某个可执行文件，跟随符号链接（Dopamine 的 /var/jb/usr/bin 大量是软链）
static NSString *PMResolveExecutable(NSString *name) {
    if (name.length == 0) return nil;
    NSString *jb = PMJBRoot();
    NSArray<NSString *> *dirs = @[
        [jb stringByAppendingString:@"/usr/bin"],
        [jb stringByAppendingString:@"/usr/local/bin"],
        [jb stringByAppendingString:@"/bin"],
        @"/var/jb/usr/bin",
        @"/var/jb/usr/local/bin",
        @"/var/jb/bin",
        @"/usr/bin",
        @"/usr/local/bin",
        @"/bin",
        @"/sbin",
    ];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *dir in dirs) {
        if (dir.length == 0) continue;
        if (![seen containsObject:dir]) [seen addObject:dir];
        NSString *candidate = [dir stringByAppendingPathComponent:name];
        // stat 跟随符号链接；lstat 会把软链判成非普通文件
        struct stat st;
        if (stat(candidate.fileSystemRepresentation, &st) != 0) continue;
        if ((st.st_mode & S_IFMT) != S_IFREG) continue;
        if (access(candidate.fileSystemRepresentation, X_OK) != 0) continue;
        return candidate;
    }
    return nil;
}

/// 注销主路径：直接对 SpringBoard 发 SIGKILL。不依赖任何外部程序。
static int PMCmdRespring(void) {
    NSMutableArray<NSString *> *tried = [NSMutableArray array];

    int killed = pm_kill_by_name("SpringBoard", SIGKILL);
    [tried addObject:@"signal:SpringBoard(SIGKILL)"];
    if (killed > 0) {
        PMEmit(@{@"ok": @YES, @"method": @"signal", @"killed": @(killed)});
        return 0;
    }

    // 降级 1：sbreload
    NSString *sbreload = PMResolveExecutable(@"sbreload");
    if (sbreload) {
        [tried addObject:sbreload];
        if (PMRunTool(sbreload, @[])) { PMEmit(@{@"ok": @YES, @"method": @"sbreload"}); return 0; }
    } else {
        [tried addObject:@"sbreload(not found)"];
    }

    // 降级 2：killall（用 stat 解析路径，不再用 lstat）
    NSString *killall = PMResolveExecutable(@"killall");
    if (killall) {
        [tried addObject:killall];
        if (PMRunTool(killall, @[@"-9", @"SpringBoard"])) { PMEmit(@{@"ok": @YES, @"method": @"killall"}); return 0; }
    } else {
        [tried addObject:@"killall(not found)"];
    }

    NSString *detail = [NSString stringWithFormat:@"注销失败；已尝试：%@",
                        [tried componentsJoinedByString:@" | "]];
    return PMFail(@"E_NO_TOOL", detail);
}

static int PMCmdRebootUserspace(void) {
    NSMutableArray<NSString *> *tried = [NSMutableArray array];

    // 主路径：launchctl reboot userspace（用 stat 跟随软链解析）
    NSString *launchctl = PMResolveExecutable(@"launchctl");
    if (launchctl) {
        [tried addObject:launchctl];
        if (PMRunTool(launchctl, @[@"reboot", @"userspace"])) {
            PMEmit(@{@"ok": @YES, @"method": @"launchctl"});
            return 0;
        }
    } else {
        [tried addObject:@"launchctl(not found)"];
    }

    // 降级：至少要重载桌面，并如实告诉 UI 走的是回退
    int killed = pm_kill_by_name("SpringBoard", SIGKILL);
    [tried addObject:@"signal:SpringBoard(SIGKILL)"];
    if (killed > 0) {
        PMEmit(@{@"ok": @YES, @"method": @"signal", @"fallback": @YES, @"killed": @(killed)});
        return 0;
    }

    NSString *sbreload = PMResolveExecutable(@"sbreload");
    if (sbreload) {
        [tried addObject:sbreload];
        if (PMRunTool(sbreload, @[])) {
            PMEmit(@{@"ok": @YES, @"method": @"sbreload", @"fallback": @YES});
            return 0;
        }
    }

    NSString *detail = [NSString stringWithFormat:@"重启用户空间失败；已尝试：%@",
                        [tried componentsJoinedByString:@" | "]];
    return PMFail(@"E_NO_TOOL", detail);
}

// ---------------------------------------------------------------------------
// 文件操作相关命令
// ---------------------------------------------------------------------------


/// 白名单输出目录：<jbroot>/var/mobile/Documents/PluginManager
/// 助手以 root 运行，产物属主要改成 mobile，否则 App 删不掉自己的副本
static void PMAdoptForMobile(NSString *path) {
    if (path.length == 0) return;
    struct passwd *pw = getpwnam("mobile");
    if (!pw) return;
    chown(path.fileSystemRepresentation, pw->pw_uid, pw->pw_gid);
}

/// 递归把目录内容属主改成 mobile
static void PMAdoptTreeForMobile(NSString *root) {
    if (root.length == 0) return;
    PMAdoptForMobile(root);
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
    for (NSString *rel in en) {
        PMAdoptForMobile([root stringByAppendingPathComponent:rel]);
    }
}

static NSString *PMDocumentsDir(void) {
    // 固定绝对路径，与 App 侧 searchRoots 保持一致
    NSString *dir = @"/var/mobile/Documents/PluginManager";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    PMAdoptForMobile(dir);
    return dir;
}

static NSString *PMLibraryDir(void) {
    NSString *dir = @"/var/mobile/Library/PluginManager";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    PMAdoptForMobile(dir);
    return dir;
}

static int PMCmdCapabilities(void) {
    PMEmit(@{
        @"ok": @YES,
        @"archive": @(pm_archive_available() == 1),
        @"version": [NSString stringWithUTF8String:kVersion],
        @"paths": @{
            @"documents": PMDocumentsDir(),
            @"library": PMLibraryDir(),
        },
    });
    return 0;
}

static NSString *PMPluginPath(NSString *dir, NSString *ident, NSString *ext) {
    NSString *on = [dir stringByAppendingPathComponent:[ident stringByAppendingString:ext]];
    if (PMIsRegularFile(on)) return on;
    NSString *off = [on stringByAppendingString:@".disabled"];
    if (PMIsRegularFile(off)) return off;
    return nil;
}

static int PMCmdPluginPaths(NSString *ident) {
    if (!PMValidIdent(ident)) return PMFail(PMCodeForError(PM_ERR_BAD_ID), PMDetailForError(PM_ERR_BAD_ID));
    NSString *dir = PMResolveInjectDirectory();
    if (!dir) return PMFail(@"E_NO_DIR", @"未找到插件注入目录");

    NSMutableArray *files = [NSMutableArray array];
    NSString *dylib = PMPluginPath(dir, ident, @".dylib");
    if (dylib) [files addObject:dylib];
    NSString *plist = PMPluginPath(dir, ident, @".plist");
    if (plist) [files addObject:plist];

    if (files.count == 0) return PMFail(@"E_NOENT", @"该插件文件不存在");
    PMEmit(@{@"ok": @YES, @"id": ident, @"files": files});
    return 0;
}

static int PMCmdPluginInfo(NSString *ident) {
    if (!PMValidIdent(ident)) return PMFail(PMCodeForError(PM_ERR_BAD_ID), PMDetailForError(PM_ERR_BAD_ID));
    NSString *dir = PMResolveInjectDirectory();
    if (!dir) return PMFail(@"E_NO_DIR", @"未找到插件注入目录");

    NSString *dylib = PMPluginPath(dir, ident, @".dylib");
    NSString *plist = PMPluginPath(dir, ident, @".plist");
    if (!dylib && !plist) return PMFail(@"E_NOENT", @"该插件文件不存在");

    struct stat st;
    unsigned long long size = 0;
    long long mtime = 0;
    if (dylib && lstat(dylib.fileSystemRepresentation, &st) == 0) {
        size = (unsigned long long)st.st_size;
        mtime = (long long)st.st_mtimespec.tv_sec;
    }

    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:@{
        @"ok": @YES,
        @"id": ident,
        @"dylib": dylib ? dylib.lastPathComponent : @"",
        @"plist": plist ? plist.lastPathComponent : @"",
        @"enabled": @(dylib != nil && [dylib hasSuffix:@".dylib"]),
        @"bytes": @(size),
        @"mtime": @(mtime),
        @"package": PMPackageOwningFile(dylib.lastPathComponent ?: ident) ?: @"",
    }];
    PMEmit(payload);
    return 0;
}


/// 从参数数组里取 --key value 形式的值
static NSString *PMArgValue(NSArray<NSString *> *args, NSString *key) {
    NSUInteger i = [args indexOfObject:key];
    if (i == NSNotFound || i + 1 >= args.count) return nil;
    return args[i + 1];
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (geteuid() != 0) {
            return PMFail(@"E_NOT_ROOT", @"pmhelper 需要 setuid root 运行");
        }
        if (argc < 2) return PMFail(@"E_USAGE", @"pmhelper list|set|respring|reboot-userspace|version");

        NSString *cmd = [NSString stringWithUTF8String:argv[1]];
        NSMutableArray<NSString *> *rest = [NSMutableArray array];
        for (int i = 2; i < argc; i++) [rest addObject:[NSString stringWithUTF8String:argv[i]]];

        if ([cmd isEqualToString:@"list"]) return PMCmdList();
        if ([cmd isEqualToString:@"plugin-info"]) return PMCmdPluginInfo(PMArgValue(rest, @"--id"));
        if ([cmd isEqualToString:@"set"]) {
            return PMCmdSet(PMArgValue(rest, @"--id"), PMArgValue(rest, @"--state"));
        }
        if ([cmd isEqualToString:@"respring"]) return PMCmdRespring();
        if ([cmd isEqualToString:@"reboot-userspace"]) return PMCmdRebootUserspace();
        if ([cmd isEqualToString:@"version"]) {
            PMEmit(@{@"ok": @YES, @"version": [NSString stringWithUTF8String:kVersion], @"uid": @(getuid()), @"euid": @(geteuid())});
            return 0;
        }
        return PMFail(@"E_USAGE", [NSString stringWithFormat:@"未知命令 %@", cmd]);
    }
}

