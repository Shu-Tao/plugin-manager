#include "PMProcOps.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <sys/sysctl.h>
#include <sys/proc.h>
// SDK 不带 libproc.h，但 libproc.tbd 里有符号；本文件用不到它的 API，
// 进程枚举全部走 sysctl(CTL_KERN, KERN_PROC, KERN_PROC_ALL)。
#endif

#define PM_MAX_PROCS 4096

#if defined(__APPLE__)

/// 枚举系统进程表，把 pid 与 p_comm 交给回调。
/// 返回实际枚举到的进程数；失败返回 -1。
static int pm_enumerate(int (*visit)(int pid, const char *name, void *ctx), void *ctx) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };

    // 先问需要多大缓冲
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) return -1;
    if (size == 0) return 0;

    // 进程可能在两次调用之间新增，多留余量并重试
    for (int attempt = 0; attempt < 4; attempt++) {
        size_t bufSize = size + size / 4 + 4096;
        struct kinfo_proc *procs = (struct kinfo_proc *)malloc(bufSize);
        if (!procs) return -1;

        size_t got = bufSize;
        int rc = sysctl(mib, 4, procs, &got, NULL, 0);
        if (rc == 0) {
            int count = (int)(got / sizeof(struct kinfo_proc));
            int visited = 0;
            for (int i = 0; i < count; i++) {
                int pid = procs[i].kp_proc.p_pid;
                if (pid <= 0) continue;
                char name[MAXCOMLEN + 1];
                memcpy(name, procs[i].kp_proc.p_comm, MAXCOMLEN);
                name[MAXCOMLEN] = '\0';
                if (visit) visit(pid, name, ctx);
                visited++;
            }
            free(procs);
            return visited;
        }
        free(procs);
        if (errno != ENOMEM) return -1;
        size = got > size ? got : size * 2;   // 缓冲不够，按内核回报值放大重来
    }
    return -1;
}

#else

// 非 Apple 平台的占位实现：让单测能在宿主机编译通过，
// 真实信号与进程表只在本文件之外的测试桩里模拟。
static int pm_enumerate(int (*visit)(int pid, const char *name, void *ctx), void *ctx) {
    (void)visit;
    (void)ctx;
    return -1;
}

#endif

struct pm_match_ctx {
    const char *target;
    int firstPid;
    int count;
    int lastErrno;
};

static int pm_match_visit(int pid, const char *name, void *ctx) {
    struct pm_match_ctx *m = (struct pm_match_ctx *)ctx;
    if (strcmp(name, m->target) != 0) return 0;
    m->count++;
    if (m->firstPid < 0) m->firstPid = pid;
    return 1;
}

int pm_find_pid_by_name(const char *name) {
    if (!name || !*name) return -1;
    struct pm_match_ctx ctx = { name, -1, 0, 0 };
    if (pm_enumerate(pm_match_visit, &ctx) < 0) return -1;
    return ctx.firstPid;
}

int pm_count_by_name(const char *name) {
    if (!name || !*name) return 0;
    struct pm_match_ctx ctx = { name, -1, 0, 0 };
    if (pm_enumerate(pm_match_visit, &ctx) < 0) return 0;
    return ctx.count;
}

struct pm_kill_ctx {
    const char *target;
    int sig;
    int killed;
};

#if defined(__APPLE__)
static int pm_kill_visit(int pid, const char *name, void *ctx) {
    struct pm_kill_ctx *k = (struct pm_kill_ctx *)ctx;
    if (strcmp(name, k->target) != 0) return 0;
    if (pid <= 1) return 0;                 // 绝不碰 PID 0/1
    if (kill(pid, k->sig) == 0) k->killed++;
    return 1;
}
#endif

int pm_kill_by_name(const char *name, int sig) {
    if (!name || !*name) return -1;
    if (sig <= 0 || sig >= NSIG) return -1;

#if defined(__APPLE__)
    struct pm_kill_ctx k = { name, sig, 0 };
    if (pm_enumerate(pm_kill_visit, &k) < 0) return -1;
    return k.killed;
#else
    return -1;
#endif
}

int pm_kill_pid(int pid, int sig) {
    if (pid <= 1) return -1;
    if (sig <= 0 || sig >= NSIG) return -1;
#if defined(__APPLE__)
    return kill(pid, sig) == 0 ? 0 : -1;
#else
    // 非 Apple 宿主（单测）不真的发信号
    return -1;
#endif
}

int pm_name_allowed(const char *name, const char *const *allowed) {
    if (!name || !allowed) return 0;
    for (int i = 0; allowed[i]; i++) {
        if (strcmp(name, allowed[i]) == 0) return 1;
    }
    return 0;
}
