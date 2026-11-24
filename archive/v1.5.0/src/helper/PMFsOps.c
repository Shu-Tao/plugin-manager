#include "PMFsOps.h"

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *kDylibSuffix = ".dylib";
static const char *kDisabledSuffix = ".disabled";
static const char *kPlistSuffix = ".plist";

int pm_valid_id(const char *ident) {
    if (!ident) return 0;
    size_t len = strlen(ident);
    if (len == 0 || len > PM_ID_MAX) return 0;
    for (size_t i = 0; i < len; i++) {
        char c = ident[i];
        int ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                 (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '+' || c == '-';
        if (!ok) return 0;
    }
    return 1;
}

int pm_is_dir(const char *path) {
    struct stat st;
    if (!path || stat(path, &st) != 0) return 0;
    return S_ISDIR(st.st_mode) ? 1 : 0;
}

int pm_is_regular(const char *path) {
    struct stat st;
    if (!path || lstat(path, &st) != 0) return 0;
    return S_ISREG(st.st_mode) ? 1 : 0;
}

int pm_is_symlink(const char *path) {
    struct stat st;
    if (!path || lstat(path, &st) != 0) return 0;
    return S_ISLNK(st.st_mode) ? 1 : 0;
}

static int build(char *dst, const char *dir, const char *ident,
                 const char *mid, const char *tail) {
    int n = snprintf(dst, PM_PATH_MAX, "%s/%s%s%s", dir, ident, mid, tail ? tail : "");
    if (n < 0 || n >= PM_PATH_MAX) return PM_ERR_USAGE;
    return PM_OK;
}

int pm_plan_switch(const char *dir, const char *ident, int enable,
                   char from[2][PM_PATH_MAX], char to[2][PM_PATH_MAX], int *count) {
    if (!dir || !count) return PM_ERR_USAGE;
    if (!pm_valid_id(ident)) return PM_ERR_BAD_ID;
    if (!pm_is_dir(dir)) return PM_ERR_NO_DIR;

    char dylib_on[PM_PATH_MAX], dylib_off[PM_PATH_MAX];
    char plist_on[PM_PATH_MAX], plist_off[PM_PATH_MAX];
    if (build(dylib_on, dir, ident, kDylibSuffix, "") != PM_OK) return PM_ERR_USAGE;
    if (build(dylib_off, dir, ident, kDylibSuffix, kDisabledSuffix) != PM_OK) return PM_ERR_USAGE;
    if (build(plist_on, dir, ident, kPlistSuffix, "") != PM_OK) return PM_ERR_USAGE;
    if (build(plist_off, dir, ident, kPlistSuffix, kDisabledSuffix) != PM_OK) return PM_ERR_USAGE;

    int on_exists = pm_is_regular(dylib_on);
    int off_exists = pm_is_regular(dylib_off);
    if (!on_exists && !off_exists) return PM_ERR_NOENT;
    if (on_exists == enable) return PM_ERR_NOSTATE;   // 已是目标状态
    if ((on_exists && pm_is_symlink(dylib_on)) || (off_exists && pm_is_symlink(dylib_off))) {
        return PM_ERR_IO;
    }

    int n = 0;
    if (enable) {
        strcpy(from[n], dylib_off);
        strcpy(to[n], dylib_on);
    } else {
        strcpy(from[n], dylib_on);
        strcpy(to[n], dylib_off);
    }
    n++;

    if (enable) {
        if (pm_is_regular(plist_off) && !pm_is_symlink(plist_off)) {
            strcpy(from[n], plist_off);
            strcpy(to[n], plist_on);
            n++;
        }
    } else {
        if (pm_is_regular(plist_on) && !pm_is_symlink(plist_on)) {
            strcpy(from[n], plist_on);
            strcpy(to[n], plist_off);
            n++;
        }
    }

    *count = n;
    return PM_OK;
}

int pm_apply_plan(char from[2][PM_PATH_MAX], char to[2][PM_PATH_MAX], int count) {
    if (count <= 0 || count > 2) return PM_ERR_USAGE;
    int done = 0;
    for (int i = 0; i < count; i++) {
        if (!pm_is_regular(from[i]) || pm_is_symlink(from[i])) {
            break;
        }
        if (pm_is_regular(to[i])) {           // 目标已存在，拒绝覆盖
            break;
        }
        if (rename(from[i], to[i]) != 0) {
            break;
        }
        done++;
    }
    if (done == count) return PM_OK;

    // 回滚
    for (int i = done - 1; i >= 0; i--) {
        if (rename(to[i], from[i]) != 0) {
            // 回滚失败：保持原状，向上层报告 IO 错误
        }
    }
    return PM_ERR_IO;
}

int pm_switch(const char *dir, const char *ident, int enable, int *moved) {
    char from[2][PM_PATH_MAX];
    char to[2][PM_PATH_MAX];
    int count = 0;
    int rc = pm_plan_switch(dir, ident, enable, from, to, &count);
    if (rc != PM_OK) return rc;
    rc = pm_apply_plan(from, to, count);
    if (rc == PM_OK && moved) *moved = count;
    return rc;
}

static int cmp_ids(const void *a, const void *b) {
    return strcmp((const char *)a, (const char *)b);
}

int pm_scan_ids(const char *dir, char ids[][PM_ID_MAX + 1], int max_ids) {
    if (!dir || !ids || max_ids <= 0) return PM_ERR_USAGE;
    if (!pm_is_dir(dir)) return PM_ERR_NO_DIR;

    DIR *dp = opendir(dir);
    if (!dp) return PM_ERR_NO_DIR;

    int count = 0;
    struct dirent *entry;
    while ((entry = readdir(dp)) != NULL) {
        const char *name = entry->d_name;
        size_t nameLen = strlen(name);
        size_t baseLen = 0;

        size_t dylibLen = strlen(kDylibSuffix);
        size_t disabledLen = strlen(kDisabledSuffix);
        if (nameLen > dylibLen + disabledLen &&
            strcmp(name + nameLen - dylibLen - disabledLen, ".dylib.disabled") == 0) {
            baseLen = nameLen - dylibLen - disabledLen;
        } else if (nameLen > dylibLen && strcmp(name + nameLen - dylibLen, kDylibSuffix) == 0) {
            baseLen = nameLen - dylibLen;
        } else {
            continue;
        }
        if (baseLen == 0 || baseLen > PM_ID_MAX) continue;

        char ident[PM_ID_MAX + 1];
        memcpy(ident, name, baseLen);
        ident[baseLen] = '\0';
        if (!pm_valid_id(ident)) continue;

        int dup = 0;
        for (int i = 0; i < count; i++) {
            if (strcmp(ids[i], ident) == 0) { dup = 1; break; }
        }
        if (dup) continue;
        if (count >= max_ids) {
            closedir(dp);
            return PM_ERR_TOOMANY;
        }
        strcpy(ids[count], ident);
        count++;
    }
    closedir(dp);

    qsort(ids, (size_t)count, PM_ID_MAX + 1, cmp_ids);
    return count;
}
