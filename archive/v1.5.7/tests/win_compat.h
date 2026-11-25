//
//  win_compat.h — 让 PMFsOps 的单元测试能在 Windows 宿主机上跑
//  仅用于测试编译；iOS 目标编译不使用此头。
//
#ifndef PM_WIN_COMPAT_H
#define PM_WIN_COMPAT_H

#ifdef _WIN32

#include <sys/stat.h>
#include <direct.h>
#include <io.h>
#include <string.h>

#ifndef S_ISLNK
#define S_ISLNK(m) 0
#endif
#ifndef S_ISREG
#define S_ISREG(m) (((m) & _S_IFMT) == _S_IFREG)
#endif
#ifndef S_ISDIR
#define S_ISDIR(m) (((m) & _S_IFMT) == _S_IFDIR)
#endif

#define lstat stat
#define mkdir(p, m) _mkdir(p)
#define rmdir _rmdir

// MinGW 的 signal.h 只暴露 SIGABRT/SIGFPE/SIGILL/SIGINT/SIGSEGV/SIGTERM，
// 补上 PMProcOps 单测需要的两个常量（仅测试用，真实信号由 iOS 内核处理）。
#ifndef SIGKILL
#define SIGKILL 9
#endif
#ifndef SIGHUP
#define SIGHUP 1
#endif

/// Windows 无原生符号链接创建，测试里直接判定为不支持
static inline int symlink(const char *target, const char *linkpath) {
    (void)target; (void)linkpath;
    return -1;
}

#endif

#endif
