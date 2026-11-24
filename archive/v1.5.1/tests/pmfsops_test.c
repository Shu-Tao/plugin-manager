//
//  pmfsops_test.c — PMFsOps 的宿主机单元测试（无 Foundation，直接 gcc/clang 编译运行）
//  覆盖：标识白名单、扫描、启用/禁用、幂等、回滚、符号链接拒绝、目录缺失。
//

#include "PMFsOps.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>

static int gPass = 0;
static int gFail = 0;

#define CHECK(cond, msg)                                                       \
    do {                                                                       \
        if (cond) {                                                            \
            gPass++;                                                           \
            printf("  [PASS] %s\n", msg);                                      \
        } else {                                                               \
            gFail++;                                                           \
            printf("  [FAIL] %s  (line %d)\n", msg, __LINE__);                 \
        }                                                                      \
    } while (0)

static char gRoot[512];

static void make_dir(const char *path) { mkdir(path, 0755); }

static void touch(const char *path, const char *body) {
    FILE *f = fopen(path, "wb");
    if (!f) {
        printf("cannot create %s\n", path);
        exit(1);
    }
    fputs(body, f);
    fclose(f);
}

static int exists(const char *path) {
    struct stat st;
    return lstat(path, &st) == 0;
}

static void join(char *out, size_t n, const char *dir, const char *name) {
    snprintf(out, n, "%s/%s", dir, name);
}

/// 递归删除（可移植实现，不依赖系统 rm）
static void remove_tree(const char *path) {
    struct stat st;
    if (lstat(path, &st) != 0) return;
    if (S_ISDIR(st.st_mode)) {
        DIR *dp = opendir(path);
        if (dp) {
            struct dirent *e;
            while ((e = readdir(dp)) != NULL) {
                if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
                char child[1024];
                snprintf(child, sizeof(child), "%s/%s", path, e->d_name);
                remove_tree(child);
            }
            closedir(dp);
        }
        rmdir(path);
    } else {
        remove(path);
    }
}

static void reset_fixture(void) {
    remove_tree(gRoot);
    make_dir(gRoot);
}

static void test_valid_id(void) {
    printf("\n[valid id]\n");
    CHECK(pm_valid_id("DemoTweak"), "常规名字通过");
    CHECK(pm_valid_id("com.yg.tweak-v2_x+1"), "含点/横线/下划线/加号通过");
    CHECK(!pm_valid_id(""), "空串拒绝");
    CHECK(!pm_valid_id("../etc/passwd"), "路径穿越拒绝");
    CHECK(!pm_valid_id("a/b"), "含斜杠拒绝");
    CHECK(!pm_valid_id("name with space"), "含空格拒绝");
    char longId[PM_ID_MAX + 8];
    memset(longId, 'a', sizeof(longId));
    longId[PM_ID_MAX + 2] = '\0';
    CHECK(!pm_valid_id(longId), "超长拒绝");
}

static void test_scan(void) {
    printf("\n[scan]\n");
    reset_fixture();
    char p[1024];
    join(p, sizeof(p), gRoot, "Alpha.dylib"); touch(p, "a");
    join(p, sizeof(p), gRoot, "Alpha.plist"); touch(p, "<plist/>");
    join(p, sizeof(p), gRoot, "Beta.dylib"); touch(p, "b");
    join(p, sizeof(p), gRoot, "Beta.plist.disabled"); touch(p, "<plist/>");
    join(p, sizeof(p), gRoot, "Gamma.dylib.disabled"); touch(p, "c");
    join(p, sizeof(p), gRoot, "Gamma.plist"); touch(p, "<plist/>");
    join(p, sizeof(p), gRoot, "README.txt"); touch(p, "noise");

    char ids[64][PM_ID_MAX + 1];
    int n = pm_scan_ids(gRoot, ids, 64);
    CHECK(n == 3, "扫描到 3 个插件");
    CHECK(n > 0 && strcmp(ids[0], "Alpha") == 0, "按字典序第一个是 Alpha");
    CHECK(n > 2 && strcmp(ids[2], "Gamma") == 0, "第三个是 Gamma");

    char missing[512];
    snprintf(missing, sizeof(missing), "%s/nope", gRoot);
    CHECK(pm_scan_ids(missing, ids, 64) == PM_ERR_NO_DIR, "目录不存在返回 E_NO_DIR");
}

static void test_switch(void) {
    printf("\n[switch]\n");
    reset_fixture();
    char dylib[1024], plist[1024], dylibOff[1024], plistOff[1024];
    join(dylib, sizeof(dylib), gRoot, "Demo.dylib"); touch(dylib, "bin");
    join(plist, sizeof(plist), gRoot, "Demo.plist"); touch(plist, "f");
    join(dylibOff, sizeof(dylibOff), gRoot, "Demo.dylib.disabled");
    join(plistOff, sizeof(plistOff), gRoot, "Demo.plist.disabled");

    int moved = 0;
    CHECK(pm_switch(gRoot, "Demo", 0, &moved) == PM_OK, "禁用成功");
    CHECK(moved == 2, "改动 2 个文件");
    CHECK(!exists(dylib) && exists(dylibOff), "dylib 已改名为 .disabled");
    CHECK(!exists(plist) && exists(plistOff), "plist 已改名为 .disabled");

    CHECK(pm_switch(gRoot, "Demo", 0, &moved) == PM_ERR_NOSTATE, "重复禁用返回 E_NOSTATE");

    CHECK(pm_switch(gRoot, "Demo", 1, &moved) == PM_OK, "启用成功");
    CHECK(moved == 2, "恢复 2 个文件");
    CHECK(exists(dylib) && !exists(dylibOff), "dylib 恢复原名");
    CHECK(exists(plist) && !exists(plistOff), "plist 恢复原名");

    CHECK(pm_switch(gRoot, "Ghost", 1, &moved) == PM_ERR_NOENT, "不存在的插件返回 E_NOENT");
    CHECK(pm_switch(gRoot, "../evil", 1, &moved) == PM_ERR_BAD_ID, "非法标识返回 E_BAD_ID");
}

static void test_partial(void) {
    printf("\n[partial files]\n");
    reset_fixture();
    char dylib[1024], dylibOff[1024];
    join(dylib, sizeof(dylib), gRoot, "Solo.dylib"); touch(dylib, "bin");
    join(dylibOff, sizeof(dylibOff), gRoot, "Solo.dylib.disabled");

    int moved = 0;
    CHECK(pm_switch(gRoot, "Solo", 0, &moved) == PM_OK, "只有 dylib 也能禁用");
    CHECK(moved == 1, "只改 1 个文件");
    CHECK(exists(dylibOff), "dylib 已禁用");
    CHECK(pm_switch(gRoot, "Solo", 1, &moved) == PM_OK, "能恢复");
}

static void test_symlink_refused(void) {
    printf("\n[symlink]\n");
    reset_fixture();
    char real[1024], link[1024], outside[1024];
    snprintf(outside, sizeof(outside), "%s/outside.bin", gRoot);
    touch(outside, "payload");
    join(real, sizeof(real), gRoot, "Trojan.dylib");
    snprintf(link, sizeof(link), "%s/tmp_link", gRoot);
    if (symlink(outside, link) != 0) {
        printf("  [SKIP] 当前环境不支持 symlink\n");
        return;
    }
    if (rename(link, real) != 0) {
        printf("  [SKIP] rename symlink 失败\n");
        return;
    }
    int moved = 0;
    int rc = pm_switch(gRoot, "Trojan", 0, &moved);
    CHECK(rc == PM_ERR_IO, "符号链接被拒绝（E_IO）");
    CHECK(exists(real), "符号链接原样保留");
}

static void test_rollback(void) {
    printf("\n[rollback]\n");
    reset_fixture();
    char dylib[1024], plist[1024], dylibOff[1024], plistOff[1024];
    join(dylib, sizeof(dylib), gRoot, "Two.dylib"); touch(dylib, "bin");
    join(plist, sizeof(plist), gRoot, "Two.plist"); touch(plist, "f");
    join(dylibOff, sizeof(dylibOff), gRoot, "Two.dylib.disabled");
    join(plistOff, sizeof(plistOff), gRoot, "Two.plist.disabled");

    touch(plistOff, "occupied");

    int moved = 0;
    int rc = pm_switch(gRoot, "Two", 0, &moved);
    CHECK(rc == PM_ERR_IO, "第二步失败返回 E_IO");
    CHECK(exists(dylib), "第一步已回滚：dylib 仍在原名");
    CHECK(!exists(dylibOff), "没有留下半禁用的 dylib");
    CHECK(exists(plist), "plist 未被改动");
}

static void test_plan(void) {
    printf("\n[plan]\n");
    reset_fixture();
    char dylib[1024];
    join(dylib, sizeof(dylib), gRoot, "Plan.dylib"); touch(dylib, "bin");

    char from[2][PM_PATH_MAX], to[2][PM_PATH_MAX];
    int count = 0;
    CHECK(pm_plan_switch(gRoot, "Plan", 0, from, to, &count) == PM_OK, "规划成功");
    CHECK(count == 1, "计划 1 步");
    CHECK(strstr(from[0], "Plan.dylib") != NULL && strstr(from[0], ".disabled") == NULL, "from 是原名");
    CHECK(strstr(to[0], "Plan.dylib.disabled") != NULL, "to 是 .disabled");

    char missing[512];
    snprintf(missing, sizeof(missing), "%s/nodir", gRoot);
    CHECK(pm_plan_switch(missing, "Plan", 0, from, to, &count) == PM_ERR_NO_DIR, "目录缺失返回 E_NO_DIR");
}

int main(void) {
    const char *base = getenv("PM_TEST_ROOT");
    if (!base || !*base) base = "/tmp";
    snprintf(gRoot, sizeof(gRoot), "%s/pmfsops-test-%d", base, (int)getpid());
    printf("fixture root: %s\n", gRoot);

    test_valid_id();
    test_scan();
    test_switch();
    test_partial();
    test_symlink_refused();
    test_rollback();
    test_plan();

    reset_fixture();
    printf("\n%d passed, %d failed\n", gPass, gFail);
    return gFail == 0 ? 0 : 1;
}
