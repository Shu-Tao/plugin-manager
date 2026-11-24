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
#import "PMArchiveOps.h"
#import "PMRepack.h"

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
        case PM_AR_ERR_UNAVAILABLE: return @"E_NO_ARCHIVE";
        case PM_AR_ERR_OPEN: return @"E_OPEN";
        case PM_AR_ERR_FORMAT: return @"E_FORMAT";
        case PM_AR_ERR_TOO_BIG: return @"E_TOO_BIG";
        case PM_AR_ERR_BADPATH: return @"E_BADPATH";
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

#import "PMArchiveOps.h"

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

static int PMCmdExtract(NSString *ident, NSString *kind) {
    if (!PMValidIdent(ident)) return PMFail(PMCodeForError(PM_ERR_BAD_ID), PMDetailForError(PM_ERR_BAD_ID));
    NSString *dir = PMResolveInjectDirectory();
    if (!dir) return PMFail(@"E_NO_DIR", @"未找到插件注入目录");

    NSString *destDir = PMDocumentsDir();
    NSMutableArray *copied = [NSMutableArray array];
    unsigned long long totalBytes = 0;

    BOOL wantDeb = [kind isEqualToString:@"deb"] || [kind isEqualToString:@"both"];
    BOOL wantAll = [kind isEqualToString:@"all"];
    if (wantAll) { wantDeb = YES; }

    BOOL wantDylib = ([kind isEqualToString:@"dylib"] || [kind isEqualToString:@"both"] || wantAll);
    BOOL wantPlist = ([kind isEqualToString:@"plist"] || [kind isEqualToString:@"both"] || wantAll);

    if (wantDylib) {
        NSString *src = PMPluginPath(dir, ident, @".dylib");
        if (src) {
            NSString *dst = [destDir stringByAppendingPathComponent:src.lastPathComponent];
            [[NSFileManager defaultManager] removeItemAtPath:dst error:NULL];
            NSError *e = nil;
            if ([[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:&e]) {
                [copied addObject:dst];
                struct stat st;
                if (lstat(dst.fileSystemRepresentation, &st) == 0) totalBytes += (unsigned long long)st.st_size;
            }
        }
    }
    if (wantPlist) {
        NSString *src = PMPluginPath(dir, ident, @".plist");
        if (src) {
            NSString *dst = [destDir stringByAppendingPathComponent:src.lastPathComponent];
            [[NSFileManager defaultManager] removeItemAtPath:dst error:NULL];
            if ([[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:NULL]) {
                [copied addObject:dst];
            }
        }
    }

    // deb：先找缓存，否则用 dpkg-deb 重打包
    if (wantDeb) {
        NSString *pkg = PMPackageOwningFile([ident stringByAppendingString:@".dylib"]);
        if (pkg.length == 0) {
            if (!wantDylib && !wantPlist) {
                return PMFail(@"E_NO_PACKAGE", @"该插件不属于任何 dpkg 包，无法追溯来源");
            }
        } else {
            NSString *errCode = nil;
            NSString *errDetail = nil;
            NSString *made = PMMaterializeDeb(pkg, destDir, &errCode, &errDetail);
            if (made) {
                [copied addObject:made];
                struct stat dst2;
                if (lstat(made.fileSystemRepresentation, &dst2) == 0) {
                    totalBytes += (unsigned long long)dst2.st_size;
                }
            } else if (!wantDylib && !wantPlist) {
                return PMFail(errCode ?: @"E_IO", errDetail ?: @"生成 deb 失败");
            }
        }
    }

    if (copied.count == 0) return PMFail(@"E_NOENT", @"没有可提取的文件");
    PMEmit(@{@"ok": @YES, @"id": ident, @"dest": destDir, @"files": copied, @"bytes": @(totalBytes)});
    return 0;
}

static int PMCmdBackup(NSString *ident) {
    if (!PMValidIdent(ident)) return PMFail(PMCodeForError(PM_ERR_BAD_ID), PMDetailForError(PM_ERR_BAD_ID));
    NSString *dir = PMResolveInjectDirectory();
    if (!dir) return PMFail(@"E_NO_DIR", @"未找到插件注入目录");

    NSString *backupDir = PMLibraryDir();
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *stamp = [fmt stringFromDate:[NSDate date]];
    NSString *fileName = [NSString stringWithFormat:@"%@-%@.zip", ident, stamp];
    NSString *zipPath = [backupDir stringByAppendingPathComponent:fileName];

    NSMutableArray *sources = [NSMutableArray array];
    NSString *dylib = PMPluginPath(dir, ident, @".dylib");
    NSString *plist = PMPluginPath(dir, ident, @".plist");
    if (dylib) [sources addObject:dylib];
    if (plist) [sources addObject:plist];
    if (sources.count == 0) return PMFail(@"E_NOENT", @"没有可备份的文件");

    if (!pm_archive_available()) return PMFail(@"E_NO_ARCHIVE", @"设备缺少 libarchive，备份不可用");

    const char *paths[4] = {0};
    for (NSUInteger i = 0; i < sources.count && i < 4; i++) {
        paths[i] = [sources[i] fileSystemRepresentation];
    }
    int rc = pm_zip_pack(paths, (int)sources.count, zipPath.fileSystemRepresentation);
    if (rc != PM_AR_OK) return PMFail(@"E_IO", @"打包失败");

    PMEmit(@{@"ok": @YES, @"id": ident, @"file": fileName, @"path": zipPath});
    return 0;
}

static int PMCmdRename(NSString *ident, NSString *newName) {
    if (!PMValidIdent(ident) || !PMValidIdent(newName)) {
        return PMFail(PMCodeForError(PM_ERR_BAD_ID), @"名称非法");
    }
    NSString *dir = PMResolveInjectDirectory();
    if (!dir) return PMFail(@"E_NO_DIR", @"未找到插件注入目录");

    NSString *oldDylib = PMPluginPath(dir, ident, @".dylib");
    if (!oldDylib) return PMFail(@"E_NOENT", @"原插件不存在");

    BOOL wasDisabled = [oldDylib hasSuffix:@".disabled"];
    NSString *newBase = [dir stringByAppendingPathComponent:newName];

    // 目标已存在则拒绝
    if (PMIsRegularFile([newBase stringByAppendingString:@".dylib"]) ||
        PMIsRegularFile([newBase stringByAppendingString:@".dylib.disabled"])) {
        return PMFail(@"E_EXISTS", @"目标名称已被占用");
    }

    NSMutableArray *moved = [NSMutableArray array];
    NSMutableArray *undo = [NSMutableArray array];

    NSString *oldPlist = PMPluginPath(dir, ident, @".plist");
    NSString *dylibSuffix = wasDisabled ? @".dylib.disabled" : @".dylib";
    NSString *plistSuffix = (oldPlist && [oldPlist hasSuffix:@".disabled"]) ? @".plist.disabled" : @".plist";

    NSString *newDylib = [newBase stringByAppendingString:dylibSuffix];
    if (rename(oldDylib.fileSystemRepresentation, newDylib.fileSystemRepresentation) != 0) {
        return PMFail(@"E_IO", @"改名失败");
    }
    [moved addObject:newDylib.lastPathComponent];
    [undo addObject:@[newDylib, oldDylib]];

    if (oldPlist) {
        NSString *newPlist = [newBase stringByAppendingString:plistSuffix];
        if (rename(oldPlist.fileSystemRepresentation, newPlist.fileSystemRepresentation) != 0) {
            // 回滚
            for (NSArray *pair in undo) {
                rename([pair[0] fileSystemRepresentation], [pair[1] fileSystemRepresentation]);
            }
            return PMFail(@"E_IO", @"plist 改名失败，已回滚");
        }
        [moved addObject:newPlist.lastPathComponent];
    }

    PMEmit(@{@"ok": @YES, @"from": ident, @"to": newName, @"moved": moved});
    return 0;
}

static int PMCmdDebInfo(NSString *path) {
    if (path.length == 0) return PMFail(@"E_USAGE", @"缺少 --path");
    if (!PMIsRegularFile(path)) return PMFail(@"E_NOENT", @"文件不存在");
    if (!pm_archive_available()) return PMFail(@"E_NO_ARCHIVE", @"设备缺少 libarchive，无法解析 deb");

    char controlBuf[8192];
    int rc = pm_deb_control(path.fileSystemRepresentation, controlBuf, sizeof(controlBuf));
    if (rc != PM_AR_OK) return PMFail(@"E_FORMAT", @"control 解析失败");

    NSString *control = [NSString stringWithUTF8String:controlBuf] ?: @"";
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    for (NSString *line in [control componentsSeparatedByString:@"\n"]) {
        NSRange colon = [line rangeOfString:@": "];
        if (colon.location == NSNotFound) continue;
        NSString *k = [line substringToIndex:colon.location];
        NSString *v = [line substringFromIndex:colon.location + 2];
        fields[k] = v;
    }

    pm_entry_list members;
    NSMutableArray *names = [NSMutableArray array];
    if (pm_deb_members(path.fileSystemRepresentation, &members) == PM_AR_OK) {
        for (int i = 0; i < members.count; i++) {
            [names addObject:[NSString stringWithFormat:@"%s (%llu B)",
                              members.items[i].name, members.items[i].size]];
        }
        pm_entry_list_free(&members);
    }

    int fileCount = 0;
    pm_deb_count_files(path.fileSystemRepresentation, &fileCount);

    PMEmit(@{
        @"ok": @YES,
        @"package": fields[@"Package"] ?: @"",
        @"version": fields[@"Version"] ?: @"",
        @"arch": fields[@"Architecture"] ?: @"",
        @"name": fields[@"Name"] ?: @"",
        @"depends": fields[@"Depends"] ?: @"",
        @"files": @(fileCount),
        @"members": names,
    });
    return 0;
}

static int PMCmdDebExtract(NSString *path, BOOL dylibsOnly) {
    if (path.length == 0) return PMFail(@"E_USAGE", @"缺少 --path");
    if (!PMIsRegularFile(path)) return PMFail(@"E_NOENT", @"文件不存在");
    if (!pm_archive_available()) return PMFail(@"E_NO_ARCHIVE", @"设备缺少 libarchive，无法解包");

    NSString *stem = path.lastPathComponent.stringByDeletingPathExtension;
    NSString *dest = [PMDocumentsDir() stringByAppendingPathComponent:stem];
    pm_extract_result result;
    int rc = pm_deb_extract(path.fileSystemRepresentation, dest.fileSystemRepresentation,
                            dylibsOnly ? 1 : 0, &result);
    if (rc != PM_AR_OK) return PMFail(@"E_IO", @"解包失败");

    PMAdoptTreeForMobile(dest);

    PMEmit(@{
        @"ok": @YES,
        @"dest": dest,
        @"extracted": @(result.extracted),
        @"skipped": @(result.skipped),
        @"bytes": @(result.bytes),
    });
    return 0;
}

static int PMCmdDebCopy(NSString *path) {
    if (path.length == 0) return PMFail(@"E_USAGE", @"缺少 --path");
    if (!PMIsRegularFile(path)) return PMFail(@"E_NOENT", @"文件不存在");

    NSString *destDir = PMDocumentsDir();
    NSString *dest = [destDir stringByAppendingPathComponent:path.lastPathComponent];

    // 已经在目标目录里，直接如实回报
    NSString *srcReal = path.stringByStandardizingPath;
    NSString *dstReal = dest.stringByStandardizingPath;
    if ([srcReal isEqualToString:dstReal]) {
        PMEmit(@{@"ok": @YES, @"already": @YES, @"path": dest});
        return 0;
    }

    // 目标已存在则覆盖，让用户能更新副本
    if (PMIsRegularFile(dest)) {
        [[NSFileManager defaultManager] removeItemAtPath:dest error:NULL];
    }

    NSError *error = nil;
    if (![[NSFileManager defaultManager] copyItemAtPath:path toPath:dest error:&error]) {
        return PMFail(@"E_IO", error.localizedDescription ?: @"复制失败");
    }

    struct stat st;
    unsigned long long bytes = 0;
    if (lstat(dest.fileSystemRepresentation, &st) == 0) bytes = (unsigned long long)st.st_size;

    PMEmit(@{@"ok": @YES, @"already": @NO, @"path": dest, @"bytes": @(bytes)});
    return 0;
}

/// 路径是否允许写入：位于两个白名单目录内（允许等于根）
static BOOL PMPathAllowedTarget(NSString *path) {
    if (path.length == 0) return NO;
    NSArray<NSString *> *roots = @[
        @"/var/mobile/Documents/PluginManager",
        @"/var/mobile/Library/PluginManager",
    ];
    char resolved[PATH_MAX];
    BOOL resolvedOk = realpath(path.fileSystemRepresentation, resolved) == 0;
    NSString *real = resolvedOk ? [NSString stringWithUTF8String:resolved] : path;

    for (NSString *root in roots) {
        if ([real isEqualToString:root]) return YES;
        if ([real hasPrefix:[root stringByAppendingString:@"/"]]) return YES;
    }
    return NO;
}

/// 删除 PluginManager 目录内的副本（由 root 执行，绕过 App 权限限制）
static int PMCmdRemoveCopy(NSString *path) {
    if (path.length == 0) return PMFail(@"E_USAGE", @"缺少 --path");
    if (!PMIsRegularFile(path) && !PMIsDirectory(path)) {
        return PMFail(@"E_NOENT", @"文件或目录不存在");
    }
    // 不允许删根目录本身
    if ([path isEqualToString:@"/var/mobile/Documents/PluginManager"] ||
        [path isEqualToString:@"/var/mobile/Library/PluginManager"]) {
        return PMFail(@"E_FORBIDDEN", @"不能删除根目录");
    }
    if (!PMPathAllowedTarget(path)) {
        return PMFail(@"E_FORBIDDEN", @"只允许删除 PluginManager 目录内的副本");
    }

    NSError *error = nil;
    if (![[NSFileManager defaultManager] removeItemAtPath:path error:&error]) {
        return PMFail(@"E_IO", error.localizedDescription ?: @"删除失败");
    }
    PMEmit(@{@"ok": @YES, @"path": path});
    return 0;
}

/// 解压 zip
static int PMCmdZipExtract(NSString *path, NSString *destArg) {
    if (path.length == 0) return PMFail(@"E_USAGE", @"缺少 --path");
    if (!PMIsRegularFile(path)) return PMFail(@"E_NOENT", @"文件不存在");
    if (!pm_archive_available()) return PMFail(@"E_NO_ARCHIVE", @"设备缺少 libarchive，无法解压");

    NSString *dest = destArg.length ? destArg : PMDocumentsDir();
    if (!PMPathAllowedTarget(dest)) {
        return PMFail(@"E_FORBIDDEN", @"解压目标必须在 PluginManager 目录内");
    }

    pm_extract_result result;
    int rc = pm_zip_extract(path.fileSystemRepresentation, dest.fileSystemRepresentation, &result);
    if (rc != PM_AR_OK) return PMFail(@"E_IO", @"解压失败");

    PMAdoptTreeForMobile(dest);

    PMEmit(@{
        @"ok": @YES,
        @"dest": dest,
        @"extracted": @(result.extracted),
        @"skipped": @(result.skipped),
        @"bytes": @(result.bytes),
    });
    return 0;
}

/// 清空一个白名单目录下的全部内容（不删目录本身）
static int PMCmdClearDir(NSString *path) {
    if (path.length == 0) return PMFail(@"E_USAGE", @"缺少 --path");
    if (!PMIsDirectory(path)) return PMFail(@"E_NOENT", @"目录不存在");
    if (!PMPathAllowedTarget(path)) return PMFail(@"E_FORBIDDEN", @"只允许清空 PluginManager 目录");

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:path error:NULL];
    int removed = 0;
    int failed = 0;
    for (NSString *n in names) {
        NSString *full = [path stringByAppendingPathComponent:n];
        NSError *e = nil;
        if ([fm removeItemAtPath:full error:&e]) removed++;
        else failed++;
    }
    PMEmit(@{@"ok": @YES, @"removed": @(removed), @"failed": @(failed)});
    return 0;
}

/// 把若干文件打包成 zip（分享用）
static int PMCmdZipPack(NSArray<NSString *> *paths, NSString *outName) {
    if (paths.count == 0) return PMFail(@"E_USAGE", @"没有要打包的文件");
    if (!pm_archive_available()) return PMFail(@"E_NO_ARCHIVE", @"设备缺少 libarchive");

    NSString *dir = PMLibraryDir();
    NSString *name = outName.length ? outName : @"share.zip";
    NSString *zipPath = [dir stringByAppendingPathComponent:name];

    NSMutableArray<NSString *> *valid = [NSMutableArray array];
    for (NSString *p in paths) {
        if (PMIsRegularFile(p)) [valid addObject:p];
    }
    if (valid.count == 0) return PMFail(@"E_NOENT", @"没有可打包的文件");

    const char *arr[64] = {0};
    int n = 0;
    for (NSString *p in valid) {
        if (n >= 64) break;
        arr[n++] = p.fileSystemRepresentation;
    }
    int rc = pm_zip_pack(arr, n, zipPath.fileSystemRepresentation);
    if (rc != PM_AR_OK) return PMFail(@"E_IO", @"打包失败");

    PMAdoptForMobile(zipPath);

    struct stat st;
    unsigned long long bytes = 0;
    if (lstat(zipPath.fileSystemRepresentation, &st) == 0) bytes = (unsigned long long)st.st_size;

    PMEmit(@{@"ok": @YES, @"path": zipPath, @"bytes": @(bytes), @"count": @(n)});
    return 0;
}

// ---------------------------------------------------------------------------
// deb 来源探测与重打包
// ---------------------------------------------------------------------------

static NSString *PMStatusPath(void) {
    NSString *p = [PMJBRoot() stringByAppendingString:@"/var/lib/dpkg/status"];
    return PMIsRegularFile(p) ? p : @"/var/lib/dpkg/status";
}

static NSString *PMListPathFor(NSString *pkg) {
    if (pkg.length == 0) return @"";
    NSString *p = [[PMJBRoot() stringByAppendingString:@"/var/lib/dpkg/info"]
                   stringByAppendingPathComponent:[pkg stringByAppendingString:@".list"]];
    return PMIsRegularFile(p) ? p : @"";
}

/// 在若干目录里按包名前缀找 deb 缓存
static NSString *PMFindCachedDeb(NSString *pkg) {
    if (pkg.length == 0) return nil;
    NSArray<NSString *> *dirs = @[
        @"/var/cache/apt/archives",
        @"/var/mobile/Library/Caches/com.apple.Sileo",
        @"/var/mobile/Documents",
        @"/var/mobile/Downloads",
        @"/var/tmp",
    ];
    NSString *prefix = [pkg stringByAppendingString:@"_"];
    for (NSString *dir in dirs) {
        NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL];
        for (NSString *n in names) {
            if (![n hasSuffix:@".deb"]) continue;
            if ([n hasPrefix:prefix]) {
                return [dir stringByAppendingPathComponent:n];
            }
        }
    }
    return nil;
}

static int PMCmdDebSource(NSString *ident) {
    if (!PMValidIdent(ident)) return PMFail(@"E_BAD_ID", @"插件标识非法");

    NSString *pkg = PMPackageOwningFile([ident stringByAppendingString:@".dylib"]);
    if (pkg.length == 0) {
        PMEmit(@{@"ok": @YES, @"available": @NO, @"mode": @"none",
                 @"reason": @"该插件不属于任何 dpkg 包，无法追溯来源"});
        return 0;
    }

    NSString *cached = PMFindCachedDeb(pkg);
    char dpkgDeb[512] = {0};
    BOOL hasDpkgDeb = pm_repack_find_dpkg_deb(dpkgDeb, sizeof(dpkgDeb)) == 1;
    NSString *listPath = PMListPathFor(pkg);

    pm_pkg_meta meta;
    int rc = pm_repack_read_meta(PMStatusPath().fileSystemRepresentation, pkg.UTF8String, &meta);

    NSString *mode = @"none";
    NSString *reason = @"";
    if (cached) {
        mode = @"cache";
    } else if (hasDpkgDeb && listPath.length > 0) {
        mode = @"repack";
    } else if (!hasDpkgDeb) {
        reason = @"设备缺少 dpkg-deb，且缓存里没有原始包";
    } else {
        reason = @"dpkg 数据库缺少该包的文件清单";
    }

    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:@{
        @"ok": @YES,
        @"available": @( ![mode isEqualToString:@"none"] ),
        @"mode": mode,
        @"package": pkg,
        @"hasDpkgDeb": @(hasDpkgDeb),
        @"hasList": @(listPath.length > 0),
    }];
    if (rc == PM_RP_OK) {
        payload[@"version"] = [NSString stringWithUTF8String:meta.version];
        payload[@"arch"] = [NSString stringWithUTF8String:meta.architecture];
        payload[@"description"] = [NSString stringWithUTF8String:meta.description];
    }
    if (cached) payload[@"cachePath"] = cached;
    if (reason.length) payload[@"reason"] = reason;

    PMEmit(payload);
    return 0;
}

/// 生成 deb：优先缓存，否则重打包
static NSString *PMMaterializeDeb(NSString *pkg, NSString *outDir, NSString **errCode, NSString **errDetail) {
    NSString *cached = PMFindCachedDeb(pkg);
    if (cached) {
        NSString *dst = [outDir stringByAppendingPathComponent:cached.lastPathComponent];
        [[NSFileManager defaultManager] removeItemAtPath:dst error:NULL];
        NSError *e = nil;
        if ([[NSFileManager defaultManager] copyItemAtPath:cached toPath:dst error:&e]) {
            PMAdoptForMobile(dst);
            return dst;
        }
        if (errCode) *errCode = @"E_IO";
        if (errDetail) *errDetail = e.localizedDescription ?: @"复制缓存包失败";
        return nil;
    }

    NSString *listPath = PMListPathFor(pkg);
    char dpkgDeb[512] = {0};
    if (!pm_repack_find_dpkg_deb(dpkgDeb, sizeof(dpkgDeb))) {
        if (errCode) *errCode = @"E_NO_DPKG";
        if (errDetail) *errDetail = @"设备缺少 dpkg-deb，无法重新打包";
        return nil;
    }
    if (listPath.length == 0) {
        if (errCode) *errCode = @"E_NO_LIST";
        if (errDetail) *errDetail = @"dpkg 数据库缺少该包文件清单";
        return nil;
    }

    NSString *staging = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"pm-repack-%@", NSUUID.UUID.UUIDString]];
    // 命名成 <包标识>_<版本>_<架构>.deb，符合 APT 习惯
    pm_pkg_meta nameMeta;
    NSString *verPart = @"unknown";
    NSString *archPart = @"iphoneos-arm64";
    if (pm_repack_read_meta(PMStatusPath().fileSystemRepresentation,
                            pkg.UTF8String, &nameMeta) == PM_RP_OK) {
        if (nameMeta.version[0]) verPart = [NSString stringWithUTF8String:nameMeta.version];
        if (nameMeta.architecture[0]) archPart = [NSString stringWithUTF8String:nameMeta.architecture];
    }
    NSString *outName = [NSString stringWithFormat:@"%@_%@_%@.deb", pkg, verPart, archPart];
    NSString *outDeb = [outDir stringByAppendingPathComponent:outName];

    pm_pkg_meta meta;
    int rc = pm_repack_build(PMStatusPath().fileSystemRepresentation,
                             listPath.fileSystemRepresentation,
                             pkg.UTF8String,
                             staging.fileSystemRepresentation,
                             outDeb.fileSystemRepresentation,
                             dpkgDeb, &meta);

    [[NSFileManager defaultManager] removeItemAtPath:staging error:NULL];

    if (rc != PM_RP_OK) {
        NSDictionary *codes = @{
            @(PM_RP_ERR_NO_DPKG): @"E_NO_DPKG",
            @(PM_RP_ERR_NO_PACKAGE): @"E_NO_PACKAGE",
            @(PM_RP_ERR_NO_LIST): @"E_NO_LIST",
            @(PM_RP_ERR_TOO_BIG): @"E_TOO_BIG",
            @(PM_RP_ERR_BUILD): @"E_BUILD",
        };
        if (errCode) *errCode = codes[@(rc)] ?: @"E_IO";
        if (errDetail) *errDetail = [NSString stringWithFormat:@"重新打包失败（rc=%d）", rc];
        return nil;
    }

    PMAdoptForMobile(outDeb);
    return outDeb;
}

static NSString *PMArgValue(NSArray<NSString *> *args, NSString *key) {
    NSUInteger idx = [args indexOfObject:key];
    if (idx == NSNotFound || idx + 1 >= args.count) return nil;
    return args[idx + 1];
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
        if ([cmd isEqualToString:@"capabilities"]) return PMCmdCapabilities();
        if ([cmd isEqualToString:@"plugin-paths"]) return PMCmdPluginPaths(PMArgValue(rest, @"--id"));
        if ([cmd isEqualToString:@"plugin-info"]) return PMCmdPluginInfo(PMArgValue(rest, @"--id"));
        if ([cmd isEqualToString:@"extract"]) {
            return PMCmdExtract(PMArgValue(rest, @"--id"), PMArgValue(rest, @"--kind") ?: @"both");
        }
        if ([cmd isEqualToString:@"backup"]) return PMCmdBackup(PMArgValue(rest, @"--id"));
        if ([cmd isEqualToString:@"rename"]) {
            return PMCmdRename(PMArgValue(rest, @"--id"), PMArgValue(rest, @"--to"));
        }
        if ([cmd isEqualToString:@"deb-source"]) return PMCmdDebSource(PMArgValue(rest, @"--id"));
        if ([cmd isEqualToString:@"deb-info"]) return PMCmdDebInfo(PMArgValue(rest, @"--path"));
        if ([cmd isEqualToString:@"deb-copy"]) return PMCmdDebCopy(PMArgValue(rest, @"--path"));
        if ([cmd isEqualToString:@"remove-copy"]) return PMCmdRemoveCopy(PMArgValue(rest, @"--path"));
        if ([cmd isEqualToString:@"clear-dir"]) return PMCmdClearDir(PMArgValue(rest, @"--path"));
        if ([cmd isEqualToString:@"zip-pack"]) {
            NSMutableArray *ps = [NSMutableArray array];
            for (NSString *a in rest) {
                if ([a hasPrefix:@"--"]) continue;
                [ps addObject:a];
            }
            return PMCmdZipPack(ps, PMArgValue(rest, @"--name"));
        }
        if ([cmd isEqualToString:@"zip-extract"]) {
            return PMCmdZipExtract(PMArgValue(rest, @"--path"), PMArgValue(rest, @"--to"));
        }
        if ([cmd isEqualToString:@"deb-extract"]) {
            BOOL dylibsOnly = [rest containsObject:@"--dylibs-only"];
            return PMCmdDebExtract(PMArgValue(rest, @"--path"), dylibsOnly);
        }
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