#include "PMRepack.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define PM_LINE_MAX 1024

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

static char *pm_trim(char *s) {
    if (!s) return s;
    while (*s == ' ' || *s == '\t' || *s == '\r' || *s == '\n') s++;
    char *end = s + strlen(s);
    while (end > s && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r' || end[-1] == '\n')) {
        end--;
    }
    *end = '\0';
    return s;
}

static int pm_is_dir(const char *p) {
    struct stat st;
    return p && stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

static int pm_is_reg(const char *p) {
    struct stat st;
    return p && lstat(p, &st) == 0 && S_ISREG(st.st_mode);
}

static int pm_mkdirs(const char *path) {
    char tmp[1024];
    size_t len = strlen(path);
    if (len == 0 || len >= sizeof(tmp)) return -1;
    memcpy(tmp, path, len + 1);
    for (size_t i = 1; i < len; i++) {
        if (tmp[i] == '/') {
            tmp[i] = '\0';
            if (!pm_is_dir(tmp)) mkdir(tmp, 0755);
            tmp[i] = '/';
        }
    }
    if (!pm_is_dir(tmp)) mkdir(tmp, 0755);
    return 0;
}

// ---------------------------------------------------------------------------
// status 解析
// ---------------------------------------------------------------------------

int pm_repack_read_meta(const char *statusPath, const char *package, pm_pkg_meta *out) {
    if (!statusPath || !package || !out) return PM_RP_ERR_USAGE;
    if (!pm_is_reg(statusPath)) return PM_RP_ERR_NO_PACKAGE;

    FILE *fp = fopen(statusPath, "rb");
    if (!fp) return PM_RP_ERR_IO;

    memset(out, 0, sizeof(*out));

    char line[PM_LINE_MAX];
    int inSection = 0;      // 是否处在目标包段落
    int found = 0;

    while (fgets(line, sizeof(line), fp)) {
        char *t = pm_trim(line);

        if (t[0] == '\0') {
            // 段落结束
            if (inSection && found) break;
            inSection = 0;
            continue;
        }

        // 字段名: 值
        char *colon = strchr(t, ':');
        if (!colon) continue;
        *colon = '\0';
        char *key = pm_trim(t);
        char *val = pm_trim(colon + 1);

        if (strcmp(key, "Package") == 0) {
            inSection = (strcmp(val, package) == 0);
            if (inSection) {
                snprintf(out->package, sizeof(out->package), "%s", val);
                found = 1;
            }
            continue;
        }

        if (!inSection) continue;

        if (strcmp(key, "Version") == 0) {
            snprintf(out->version, sizeof(out->version), "%s", val);
        } else if (strcmp(key, "Architecture") == 0) {
            snprintf(out->architecture, sizeof(out->architecture), "%s", val);
        } else if (strcmp(key, "Maintainer") == 0) {
            snprintf(out->maintainer, sizeof(out->maintainer), "%s", val);
        } else if (strcmp(key, "Description") == 0) {
            snprintf(out->description, sizeof(out->description), "%s", val);
        } else if (strcmp(key, "Depends") == 0) {
            snprintf(out->depends, sizeof(out->depends), "%s", val);
        }
    }

    fclose(fp);
    if (!found) return PM_RP_ERR_NO_PACKAGE;
    if (out->architecture[0] == '\0') snprintf(out->architecture, sizeof(out->architecture), "iphoneos-arm64");
    if (out->version[0] == '\0') snprintf(out->version, sizeof(out->version), "0");
    return PM_RP_OK;
}

// ---------------------------------------------------------------------------
// list 解析
// ---------------------------------------------------------------------------

/// 是否应从重打包中跳过的路径（dpkg 自身记录、临时文件）
static int pm_skip_path(const char *p) {
    if (!p || p[0] != '/') return 1;
    if (strncmp(p, "/var/lib/dpkg/", 14) == 0) return 1;
    if (strncmp(p, "/var/lib/apt/", 13) == 0) return 1;
    if (strncmp(p, "/tmp/", 5) == 0) return 1;
    if (strncmp(p, "/var/tmp/", 9) == 0) return 1;
    return 0;
}

int pm_repack_count_files(const char *listPath, int *countOut) {
    if (!listPath || !countOut) return PM_RP_ERR_USAGE;
    *countOut = 0;
    if (!pm_is_reg(listPath)) return PM_RP_ERR_NO_LIST;

    FILE *fp = fopen(listPath, "rb");
    if (!fp) return PM_RP_ERR_IO;

    char line[PM_LINE_MAX];
    int n = 0;
    while (fgets(line, sizeof(line), fp)) {
        char *t = pm_trim(line);
        if (t[0] == '\0') continue;
        if (pm_skip_path(t)) continue;
        if (pm_is_reg(t)) n++;
    }
    fclose(fp);
    *countOut = n;
    return PM_RP_OK;
}

// ---------------------------------------------------------------------------
// 执行外部命令
// ---------------------------------------------------------------------------

int pm_repack_find_dpkg_deb(char *buf, size_t cap) {
    if (!buf || cap == 0) return 0;
    const char *cands[] = {
        "/var/jb/usr/bin/dpkg-deb",
        "/var/jb/usr/local/bin/dpkg-deb",
        "/usr/bin/dpkg-deb",
        "/usr/local/bin/dpkg-deb",
        "/var/jb/usr/bin/dpkg",
        NULL
    };
    for (int i = 0; cands[i]; i++) {
        struct stat st;
        if (stat(cands[i], &st) != 0) continue;
        if ((st.st_mode & S_IFMT) != S_IFREG) continue;
        if (access(cands[i], X_OK) != 0) continue;
        // dpkg 本体不能直接 -b，只有 dpkg-deb 才行
        if (strstr(cands[i], "dpkg-deb") == NULL) continue;
        snprintf(buf, cap, "%s", cands[i]);
        return 1;
    }
    return 0;
}

static int pm_run(const char *exe, char *const argv[]) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        execv(exe, argv);
        _exit(127);
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return -1;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return -1;
}

// ---------------------------------------------------------------------------
// 构建
// ---------------------------------------------------------------------------

static int pm_copy_file(const char *src, const char *dst) {
    FILE *in = fopen(src, "rb");
    if (!in) return -1;

    char parent[1024];
    snprintf(parent, sizeof(parent), "%s", dst);
    char *slash = strrchr(parent, '/');
    if (slash) {
        *slash = '\0';
        pm_mkdirs(parent);
    }

    FILE *out = fopen(dst, "wb");
    if (!out) { fclose(in); return -1; }

    char chunk[65536];
    size_t got;
    while ((got = fread(chunk, 1, sizeof(chunk), in)) > 0) {
        if (fwrite(chunk, 1, got, out) != got) { fclose(in); fclose(out); return -1; }
    }
    fclose(in);
    fclose(out);

    // 保留原权限
    struct stat st;
    if (stat(src, &st) == 0) chmod(dst, st.st_mode & 07777);
    return 0;
}

int pm_repack_build(const char *statusPath, const char *listPath,
                    const char *package, const char *stagingDir,
                    const char *outDeb, const char *dpkgDebPath,
                    pm_pkg_meta *outMeta) {
    if (!statusPath || !listPath || !package || !stagingDir || !outDeb) return PM_RP_ERR_USAGE;

    pm_pkg_meta meta;
    int rc = pm_repack_read_meta(statusPath, package, &meta);
    if (rc != PM_RP_OK) return rc;

    if (!pm_is_reg(listPath)) return PM_RP_ERR_NO_LIST;

    if (pm_mkdirs(stagingDir) != 0) return PM_RP_ERR_IO;

    char debianDir[1024];
    snprintf(debianDir, sizeof(debianDir), "%s/DEBIAN", stagingDir);
    pm_mkdirs(debianDir);

    // control 文件
    char controlPath[1200];
    snprintf(controlPath, sizeof(controlPath), "%s/control", debianDir);
    FILE *cf = fopen(controlPath, "wb");
    if (!cf) return PM_RP_ERR_IO;

    fprintf(cf, "Package: %s\n", meta.package);
    fprintf(cf, "Name: %s\n", meta.package);
    fprintf(cf, "Version: %s\n", meta.version);
    fprintf(cf, "Architecture: %s\n", meta.architecture);
    if (meta.description[0]) fprintf(cf, "Description: %s\n", meta.description);
    if (meta.depends[0]) fprintf(cf, "Depends: %s\n", meta.depends);
    fprintf(cf, "Maintainer: %s\n", meta.maintainer[0] ? meta.maintainer : "unknown");
    fprintf(cf, "Section: Tweaks\n");
    fprintf(cf, "Priority: optional\n");
    fclose(cf);
    chmod(controlPath, 0644);

    // 拷文件
    FILE *lf = fopen(listPath, "rb");
    if (!lf) return PM_RP_ERR_IO;

    char line[PM_LINE_MAX];
    int copied = 0;
    unsigned long long total = 0;

    while (fgets(line, sizeof(line), lf)) {
        char *t = pm_trim(line);
        if (t[0] == '\0') continue;
        if (pm_skip_path(t)) continue;
        if (!pm_is_reg(t)) continue;

        struct stat st;
        if (stat(t, &st) != 0) continue;
        if (total + (unsigned long long)st.st_size > PM_RP_MAX_TOTAL) {
            fclose(lf);
            return PM_RP_ERR_TOO_BIG;
        }

        char dst[2048];
        snprintf(dst, sizeof(dst), "%s%s", stagingDir, t);
        if (pm_copy_file(t, dst) == 0) {
            copied++;
            total += (unsigned long long)st.st_size;
        }
    }
    fclose(lf);

    if (copied == 0) return PM_RP_ERR_NO_LIST;

    // 调 dpkg-deb -b
    char exe[512];
    if (dpkgDebPath && dpkgDebPath[0]) {
        snprintf(exe, sizeof(exe), "%s", dpkgDebPath);
    } else if (!pm_repack_find_dpkg_deb(exe, sizeof(exe))) {
        return PM_RP_ERR_NO_DPKG;
    }

    char *argv[] = { exe, "-b", (char *)stagingDir, (char *)outDeb, NULL };
    int code = pm_run(exe, argv);
    if (code != 0) return PM_RP_ERR_BUILD;

    if (outMeta) {
        meta.fileCount = copied;
        meta.totalBytes = total;
        *outMeta = meta;
    }
    return PM_RP_OK;
}
