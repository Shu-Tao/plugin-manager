//
//  pmprocops_test.c — PMProcOps 宿主机单测
//  覆盖：名字白名单、pid 合法性、非法参数、找不到进程的返回值。
//  真信号与进程枚举依赖内核 sysctl，宿主机上按条件编译跳过并明确标注。
//

#include "PMProcOps.h"

#include <signal.h>
#include <stdio.h>
#include <string.h>

#ifndef NSIG
#define NSIG 65
#endif

static int gPass = 0;
static int gFail = 0;

#define CHECK(cond, msg) \
    do { \
        if (cond) { gPass++; printf("  [PASS] %s\n", msg); } \
        else { gFail++; printf("  [FAIL] %s  (line %d)\n", msg, __LINE__); } \
    } while (0)

static void test_allowed(void) {
    printf("\n[allow list]\n");
    const char *allowed[] = { "SpringBoard", "backboardd", NULL };
    CHECK(pm_name_allowed("SpringBoard", allowed) == 1, "白名单内的名字通过");
    CHECK(pm_name_allowed("backboardd", allowed) == 1, "第二个白名单项通过");
    CHECK(pm_name_allowed("launchd", allowed) == 0, "白名单外拒绝");
    CHECK(pm_name_allowed("springboard", allowed) == 0, "大小写不同要拒绝（精确匹配）");
    CHECK(pm_name_allowed("", allowed) == 0, "空串拒绝");
    CHECK(pm_name_allowed("SpringBoard", NULL) == 0, "空白名单拒绝");
}

static void test_kill_pid_guards(void) {
    printf("\n[pid guards]\n");
    CHECK(pm_kill_pid(0, SIGKILL) == -1, "PID 0 拒绝");
    CHECK(pm_kill_pid(1, SIGKILL) == -1, "PID 1 拒绝（保护 init）");
    CHECK(pm_kill_pid(-5, SIGKILL) == -1, "负数 pid 拒绝");
    CHECK(pm_kill_pid(999999, 0) == -1, "信号 0 拒绝");
    CHECK(pm_kill_pid(999999, NSIG) == -1, "越界信号拒绝");
}

static void test_kill_by_name_guards(void) {
    printf("\n[kill by name guards]\n");
    CHECK(pm_kill_by_name(NULL, SIGKILL) == -1, "NULL 名字拒绝");
    CHECK(pm_kill_by_name("", SIGKILL) == -1, "空名字拒绝");
    CHECK(pm_kill_by_name("SpringBoard", 0) == -1, "信号 0 拒绝");
    CHECK(pm_kill_by_name("SpringBoard", -1) == -1, "负信号拒绝");
    CHECK(pm_kill_by_name("SpringBoard", NSIG) == -1, "越界信号拒绝");
}

static void test_lookup(void) {
    printf("\n[lookup]\n");
    CHECK(pm_find_pid_by_name(NULL) == -1, "NULL 查不到返回 -1");
    CHECK(pm_find_pid_by_name("") == -1, "空名字返回 -1");
    CHECK(pm_count_by_name(NULL) == 0, "NULL 计数为 0");
    CHECK(pm_count_by_name("") == 0, "空名字计数为 0");
#if defined(__APPLE__)
    int sb = pm_find_pid_by_name("SpringBoard");
    printf("  [INFO] SpringBoard pid = %d\n", sb);
    CHECK(sb != 0, "pid 永不为 0（-1 表示未找到，>0 表示找到）");
    int self = pm_count_by_name("pmprocops_test");
    printf("  [INFO] self count = %d\n", self);
#else
    printf("  [SKIP] 进程表枚举仅 Apple 平台可用（当前宿主为 Windows/Linux）\n");
    CHECK(pm_find_pid_by_name("SpringBoard") == -1, "非 Apple 平台返回 -1 而不是乱值");
    CHECK(pm_kill_by_name("SpringBoard", SIGKILL) == -1, "非 Apple 平台不执行信号");
#endif
}

int main(void) {
    printf("pmprocops 单测\n");
    test_allowed();
    test_kill_pid_guards();
    test_kill_by_name_guards();
    test_lookup();
    printf("\n%d passed, %d failed\n", gPass, gFail);
    return gFail == 0 ? 0 : 1;
}
