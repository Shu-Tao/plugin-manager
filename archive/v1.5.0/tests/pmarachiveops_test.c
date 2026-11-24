//
//  pmarachiveops_test.c — PMArchiveOps 单测
//
//  libarchive 的 dlopen 只在 iOS 上可用，宿主机（Windows）验证的是：
//    · 路径安全（pm_safe_subpath）——解包防穿越的核心
//    · 能力探测在无库时正确返回"不可用"而不是崩溃
//    · 参数校验
//  真正的解包正确性由 scripts/test-archive.py 用真实 deb 在构建期验证（见 build.ps1）。
//

#include "PMArchiveOps.h"

#include <stdio.h>
#include <string.h>

static int gPass = 0;
static int gFail = 0;

#define CHECK(cond, msg) \
    do { \
        if (cond) { gPass++; printf("  [PASS] %s\n", msg); } \
        else { gFail++; printf("  [FAIL] %s  (line %d)\n", msg, __LINE__); } \
    } while (0)

static void test_safe_subpath(void) {
    printf("\n[path safety]\n");
    char out[512];

    CHECK(pm_safe_subpath("/tmp/base", "a/b.txt", out, sizeof(out)) == PM_AR_OK,
          "普通相对路径通过");
    CHECK(strcmp(out, "/tmp/base/a/b.txt") == 0, "拼接结果正确");

    CHECK(pm_safe_subpath("/tmp/base", "../../etc/passwd", out, sizeof(out)) == PM_AR_ERR_BADPATH,
          "路径穿越被拒绝");
    CHECK(pm_safe_subpath("/tmp/base", "a/../../etc/passwd", out, sizeof(out)) == PM_AR_ERR_BADPATH,
          "中间穿越被拒绝");
    CHECK(pm_safe_subpath("/tmp/base", "/etc/passwd", out, sizeof(out)) == PM_AR_ERR_BADPATH,
          "绝对路径被拒绝");
    CHECK(pm_safe_subpath("/tmp/base", "..", out, sizeof(out)) == PM_AR_ERR_BADPATH,
          "裸 .. 被拒绝");

    CHECK(pm_safe_subpath(NULL, "a", out, sizeof(out)) == PM_AR_ERR_USAGE, "NULL base 拒绝");
    CHECK(pm_safe_subpath("/tmp/base", NULL, out, sizeof(out)) == PM_AR_ERR_USAGE, "NULL rel 拒绝");
    CHECK(pm_safe_subpath("/tmp/base", "a", NULL, 0) == PM_AR_ERR_USAGE, "NULL out 拒绝");

    char tiny[8];
    CHECK(pm_safe_subpath("/tmp/base", "verylongname.txt", tiny, sizeof(tiny)) == PM_AR_ERR_NOSPACE,
          "缓冲区不足报 NOSPACE");
}

static void test_unavailable(void) {
    printf("\n[availability]\n");
#if defined(__APPLE__)
    int avail = pm_archive_available();
    printf("  [INFO] libarchive available = %d\n", avail);
    CHECK(avail == 0 || avail == 1, "返回值只有 0/1");
#else
    CHECK(pm_archive_available() == 0, "非 Apple 宿主报告不可用");
#endif

    pm_entry_list list;
    memset(&list, 0, sizeof(list));
    int rc = pm_deb_members("/nonexistent.deb", &list);
    CHECK(rc < 0, "不存在的包返回负错误码而不是崩溃");
    pm_entry_list_free(&list);
    CHECK(list.items == NULL && list.count == 0, "释放后列表归零");
}

static void test_arg_validation(void) {
    printf("\n[arg validation]\n");
    char buf[128];

    CHECK(pm_deb_control("/x.deb", NULL, 128) == PM_AR_ERR_USAGE, "NULL buf 拒绝");
    CHECK(pm_deb_control("/x.deb", buf, 0) == PM_AR_ERR_USAGE, "零容量拒绝");

    CHECK(pm_deb_extract("/x.deb", NULL, 0, NULL) == PM_AR_ERR_USAGE, "NULL dest 拒绝");

    CHECK(pm_zip_pack(NULL, 1, "/x.zip") == PM_AR_ERR_USAGE, "NULL paths 拒绝");
    CHECK(pm_zip_pack((const char *[]){ "a" }, 0, "/x.zip") == PM_AR_ERR_USAGE, "零个数拒绝");
    CHECK(pm_zip_pack((const char *[]){ "a" }, 1, NULL) == PM_AR_ERR_USAGE, "NULL 输出拒绝");

    int files = -1;
    CHECK(pm_deb_count_files("/x.deb", NULL) == PM_AR_ERR_USAGE, "NULL filesOut 拒绝");
    (void)files;
}

static void test_entry_list(void) {
    printf("\n[entry list]\n");
    pm_entry_list list;
    memset(&list, 0, sizeof(list));
    pm_entry_list_free(&list);
    CHECK(list.items == NULL, "空列表释放安全");
    pm_entry_list_free(NULL);
    CHECK(1, "NULL 释放不崩溃");
}

int main(void) {
    printf("pmarachiveops 单测\n");
    test_safe_subpath();
    test_unavailable();
    test_arg_validation();
    test_entry_list();
    printf("\n%d passed, %d failed\n", gPass, gFail);
    return gFail == 0 ? 0 : 1;
}
