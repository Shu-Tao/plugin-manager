#include "PMArchiveOps.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <dlfcn.h>
#endif

// ---------------------------------------------------------------------------
// libarchive 最小声明（SDK 不带 archive.h，按 tbd 导出手工声明）
// ---------------------------------------------------------------------------

typedef struct archive archive_t;
typedef struct archive_entry archive_entry_t;

#define PM_AR_READ  1
#define PM_AE_IFREG 0100000
#define PM_AE_IFDIR 0040000

typedef struct {
    void *handle;
    int ready;

    archive_t *(*read_new)(void);
    int (*read_support_filter_all)(archive_t *);
    int (*read_support_format_all)(archive_t *);
    int (*read_support_format_ar)(archive_t *);
    int (*read_support_format_tar)(archive_t *);
    int (*read_open_filename)(archive_t *, const char *, size_t);
    int (*read_open_memory)(archive_t *, const void *, size_t);
    int (*read_next_header)(archive_t *, archive_entry_t **);
    long long (*read_data)(archive_t *, void *, size_t);
    int (*read_close)(archive_t *);
    int (*read_free)(archive_t *);
    const char *(*error_string)(archive_t *);

    const char *(*entry_pathname)(archive_entry_t *);
    long long (*entry_size)(archive_entry_t *);
    unsigned int (*entry_filetype)(archive_entry_t *);

    archive_t *(*write_new)(void);
    int (*write_set_format_zip)(archive_t *);
    int (*write_add_filter_none)(archive_t *);
    int (*write_open_filename)(archive_t *, const char *);
    int (*write_header)(archive_t *, archive_entry_t *);
    long long (*write_data)(archive_t *, const void *, size_t);
    int (*write_close)(archive_t *);
    int (*write_free)(archive_t *);

    archive_entry_t *(*entry_new)(void);
    void (*entry_free)(archive_entry_t *);
    void (*entry_set_pathname)(archive_entry_t *, const char *);
    void (*entry_set_size)(archive_entry_t *, long long);
    void (*entry_set_filetype)(archive_entry_t *, unsigned int);
    void (*entry_set_perm)(archive_entry_t *, int);
    void (*entry_set_mtime)(archive_entry_t *, long);
} pm_ar_api;

static pm_ar_api gAr;
static int gArState = 0;   // 0=未尝试 1=成功 -1=失败

#if defined(__APPLE__)
static void *pm_sym(void *h, const char *name) {
    return dlsym(h, name);
}
#endif

static int pm_ar_load(void) {
    if (gArState != 0) return gArState == 1 ? PM_AR_OK : PM_AR_ERR_UNAVAILABLE;

#if defined(__APPLE__)
    // 依次尝试：无版本号 → 具体版本 → 绝对路径
    const char *candidates[] = {
        "libarchive.2.dylib", "libarchive.dylib",
        "/usr/lib/libarchive.2.dylib",
        "/var/jb/usr/lib/libarchive.2.dylib",
        NULL
    };
    void *h = NULL;
    for (int i = 0; candidates[i]; i++) {
        h = dlopen(candidates[i], RTLD_LAZY | RTLD_LOCAL);
        if (h) break;
    }
    if (!h) { gArState = -1; return PM_AR_ERR_UNAVAILABLE; }

    gAr.handle = h;
    gAr.read_new                 = pm_sym(h, "archive_read_new");
    gAr.read_support_filter_all  = pm_sym(h, "archive_read_support_filter_all");
    gAr.read_support_format_all  = pm_sym(h, "archive_read_support_format_all");
    gAr.read_support_format_ar   = pm_sym(h, "archive_read_support_format_ar");
    gAr.read_support_format_tar  = pm_sym(h, "archive_read_support_format_tar");
    gAr.read_open_filename       = pm_sym(h, "archive_read_open_filename");
    gAr.read_open_memory         = pm_sym(h, "archive_read_open_memory");
    gAr.read_next_header         = pm_sym(h, "archive_read_next_header");
    gAr.read_data                = pm_sym(h, "archive_read_data");
    gAr.read_close               = pm_sym(h, "archive_read_close");
    gAr.read_free                = pm_sym(h, "archive_read_free");
    gAr.error_string             = pm_sym(h, "archive_error_string");

    gAr.entry_pathname           = pm_sym(h, "archive_entry_pathname");
    gAr.entry_size               = pm_sym(h, "archive_entry_size");
    gAr.entry_filetype           = pm_sym(h, "archive_entry_filetype");

    gAr.write_new                = pm_sym(h, "archive_write_new");
    gAr.write_set_format_zip     = pm_sym(h, "archive_write_set_format_zip");
    gAr.write_add_filter_none    = pm_sym(h, "archive_write_add_filter_none");
    gAr.write_open_filename      = pm_sym(h, "archive_write_open_filename");
    gAr.write_header             = pm_sym(h, "archive_write_header");
    gAr.write_data               = pm_sym(h, "archive_write_data");
    gAr.write_close              = pm_sym(h, "archive_write_close");
    gAr.write_free               = pm_sym(h, "archive_write_free");

    gAr.entry_new                = pm_sym(h, "archive_entry_new");
    gAr.entry_free               = pm_sym(h, "archive_entry_free");
    gAr.entry_set_pathname       = pm_sym(h, "archive_entry_set_pathname");
    gAr.entry_set_size           = pm_sym(h, "archive_entry_set_size");
    gAr.entry_set_filetype       = pm_sym(h, "archive_entry_set_filetype");
    gAr.entry_set_perm           = pm_sym(h, "archive_entry_set_perm");
    gAr.entry_set_mtime          = pm_sym(h, "archive_entry_set_mtime");

    if (!gAr.read_new || !gAr.read_next_header || !gAr.read_data ||
        !gAr.entry_pathname || !gAr.entry_size) {
        dlclose(h);
        gAr.handle = NULL;
        gArState = -1;
        return PM_AR_ERR_UNAVAILABLE;
    }
    gAr.ready = 1;
    gArState = 1;
    return PM_AR_OK;
#else
    gArState = -1;
    return PM_AR_ERR_UNAVAILABLE;
#endif
}

int pm_archive_available(void) {
    return pm_ar_load() == PM_AR_OK ? 1 : 0;
}

// ---------------------------------------------------------------------------
// 路径安全
// ---------------------------------------------------------------------------

/// 把 relPath 拼到 baseDir 下；拒绝绝对路径、..、以及超长
int pm_safe_subpath(const char *baseDir, const char *relPath, char *out, size_t cap) {
    if (!baseDir || !relPath || !out || cap == 0) return PM_AR_ERR_USAGE;
    if (relPath[0] == '/') return PM_AR_ERR_BADPATH;          // 绝对路径拒绝
    if (strstr(relPath, "..")) return PM_AR_ERR_BADPATH;      // 穿越拒绝
    if (strlen(baseDir) + strlen(relPath) + 2 > cap) return PM_AR_ERR_NOSPACE;

    int n = snprintf(out, cap, "%s/%s", baseDir, relPath);
    if (n < 0 || (size_t)n >= cap) return PM_AR_ERR_NOSPACE;
    return PM_AR_OK;
}

static int pm_mkdirs(const char *path) {
    char tmp[1024];
    size_t len = strlen(path);
    if (len == 0 || len >= sizeof(tmp)) return -1;
    memcpy(tmp, path, len + 1);

    for (size_t i = 1; i < len; i++) {
        if (tmp[i] == '/') {
            tmp[i] = '\0';
            struct stat st;
            if (stat(tmp, &st) != 0) {
                if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
            }
            tmp[i] = '/';
        }
    }
    struct stat st;
    if (stat(tmp, &st) != 0) {
        if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
    }
    return 0;
}

void pm_entry_list_free(pm_entry_list *list) {
    if (!list) return;
    free(list->items);
    list->items = NULL;
    list->count = 0;
    list->capacity = 0;
}

static int pm_list_push(pm_entry_list *list, const char *name, unsigned long long size) {
    if (!list || !name) return PM_AR_ERR_USAGE;
    if (list->count >= PM_AR_MAX_ENTRIES) return PM_AR_ERR_TOO_BIG;
    if (list->count == list->capacity) {
        int cap = list->capacity ? list->capacity * 2 : 8;
        pm_entry *next = realloc(list->items, (size_t)cap * sizeof(pm_entry));
        if (!next) return PM_AR_ERR_IO;
        list->items = next;
        list->capacity = cap;
    }
    pm_entry *e = &list->items[list->count];
    memset(e, 0, sizeof(*e));
    strncpy(e->name, name, sizeof(e->name) - 1);
    e->size = size;
    list->count++;
    return PM_AR_OK;
}

// ---------------------------------------------------------------------------
// 从内存 buffer 读取嵌套 tar
// ---------------------------------------------------------------------------

/// 把 ar 成员（control.tar.xz / data.tar.xz）整段读进内存
static int pm_read_member_mem(archive_t *ar, archive_entry_t *entry,
                              const char *wantName, unsigned char **outBuf,
                              size_t *outLen) {
    const char *name = gAr.entry_pathname(entry);
    if (!name) return PM_AR_ERR_FORMAT;
    // ar 成员的路径可能带 ./ 前缀，做一次宽松匹配
    const char *base = name;
    while (base[0] == '.' && base[1] == '/') base += 2;
    if (strcmp(base, wantName) != 0 && strncmp(base, wantName, strlen(wantName)) != 0) {
        return PM_AR_ERR_FORMAT;   // 不是要找的成员
    }

    long long declared = gAr.entry_size(entry);
    size_t cap = (declared > 0 && declared < (long long)PM_AR_MAX_TOTAL_BYTES)
                     ? (size_t)declared + 1 : 0;
    if (cap == 0) return PM_AR_ERR_TOO_BIG;

    unsigned char *buf = malloc(cap);
    if (!buf) return PM_AR_ERR_IO;

    size_t total = 0;
    for (;;) {
        if (total >= cap) {
            // 实际比声明大，扩容（仍受总量上限约束）
            if (cap >= PM_AR_MAX_TOTAL_BYTES) { free(buf); return PM_AR_ERR_TOO_BIG; }
            size_t ncap = cap * 2;
            unsigned char *nb = realloc(buf, ncap);
            if (!nb) { free(buf); return PM_AR_ERR_IO; }
            buf = nb; cap = ncap;
        }
        long long got = gAr.read_data(ar, buf + total, cap - total);
        if (got < 0) { free(buf); return PM_AR_ERR_IO; }
        if (got == 0) break;
        total += (size_t)got;
    }
    *outBuf = buf;
    *outLen = total;
    return PM_AR_OK;
}

static int pm_open_deb(const char *debPath, archive_t **outAr) {
    if (pm_ar_load() != PM_AR_OK) return PM_AR_ERR_UNAVAILABLE;
    if (!debPath) return PM_AR_ERR_USAGE;

    archive_t *ar = gAr.read_new();
    if (!ar) return PM_AR_ERR_IO;

    // deb = ar 容器；内部成员是 xz 压缩的 tar，filter 必须全开
    if (gAr.read_support_filter_all) gAr.read_support_filter_all(ar);
    if (gAr.read_support_format_ar) gAr.read_support_format_ar(ar);
    if (gAr.read_support_format_tar) gAr.read_support_format_tar(ar);

    if (gAr.read_open_filename(ar, debPath, 10240) != 0) {
        if (gAr.read_free) gAr.read_free(ar);
        return PM_AR_ERR_OPEN;
    }
    *outAr = ar;
    return PM_AR_OK;
}

int pm_deb_members(const char *debPath, pm_entry_list *out) {
    if (!out) return PM_AR_ERR_USAGE;
    memset(out, 0, sizeof(*out));

    archive_t *ar = NULL;
    int rc = pm_open_deb(debPath, &ar);
    if (rc != PM_AR_OK) return rc;

    archive_entry_t *entry = NULL;
    while (gAr.read_next_header(ar, &entry) == 0) {
        const char *name = gAr.entry_pathname(entry);
        if (!name) continue;
        const char *base = name;
        while (base[0] == '.' && base[1] == '/') base += 2;
        long long sz = gAr.entry_size(entry);
        pm_list_push(out, base, sz > 0 ? (unsigned long long)sz : 0);
    }
    if (gAr.read_close) gAr.read_close(ar);
    if (gAr.read_free) gAr.read_free(ar);
    return PM_AR_OK;
}

int pm_deb_control(const char *debPath, char *buf, size_t cap) {
    if (!buf || cap == 0) return PM_AR_ERR_USAGE;
    buf[0] = '\0';

    archive_t *outer = NULL;
    int rc = pm_open_deb(debPath, &outer);
    if (rc != PM_AR_OK) return rc;

    unsigned char *payload = NULL;
    size_t payloadLen = 0;

    archive_entry_t *entry = NULL;
    while (gAr.read_next_header(outer, &entry) == 0) {
        const char *name = gAr.entry_pathname(entry);
        if (!name) continue;
        const char *base = name;
        while (base[0] == '.' && base[1] == '/') base += 2;
        if (strncmp(base, "control.tar", 11) == 0) {
            rc = pm_read_member_mem(outer, entry, base, &payload, &payloadLen);
            break;
        }
    }
    if (gAr.read_close) gAr.read_close(outer);
    if (gAr.read_free) gAr.read_free(outer);
    if (!payload) return PM_AR_ERR_FORMAT;

    // 嵌套 tar：从内存打开，找 ./control
    archive_t *inner = gAr.read_new();
    if (!inner) { free(payload); return PM_AR_ERR_IO; }
    if (gAr.read_support_filter_all) gAr.read_support_filter_all(inner);
    if (gAr.read_support_format_tar) gAr.read_support_format_tar(inner);

    rc = PM_AR_ERR_FORMAT;
    if (gAr.read_open_memory(inner, payload, payloadLen) == 0) {
        archive_entry_t *e2 = NULL;
        while (gAr.read_next_header(inner, &e2) == 0) {
            const char *n2 = gAr.entry_pathname(e2);
            if (!n2) continue;
            const char *b2 = n2;
            while (b2[0] == '.' && b2[1] == '/') b2 += 2;
            if (strcmp(b2, "control") != 0) continue;

            size_t total = 0;
            char chunk[1024];
            long long got;
            while ((got = gAr.read_data(inner, chunk, sizeof(chunk))) > 0) {
                size_t take = (size_t)got;
                if (total + take >= cap) take = cap - 1 - total;
                if (take > 0) {
                    memcpy(buf + total, chunk, take);
                    total += take;
                }
                if (total >= cap - 1) break;
            }
            buf[total] = '\0';
            rc = PM_AR_OK;
            break;
        }
    }
    if (gAr.read_close) gAr.read_close(inner);
    if (gAr.read_free) gAr.read_free(inner);
    free(payload);
    return rc;
}
int pm_deb_count_files(const char *debPath, int *filesOut) {
    if (!filesOut) return PM_AR_ERR_USAGE;
    *filesOut = 0;

    archive_t *outer = NULL;
    int rc = pm_open_deb(debPath, &outer);
    if (rc != PM_AR_OK) return rc;

    unsigned char *payload = NULL;
    size_t payloadLen = 0;
    char memberName[64] = {0};

    archive_entry_t *entry = NULL;
    while (gAr.read_next_header(outer, &entry) == 0) {
        const char *name = gAr.entry_pathname(entry);
        if (!name) continue;
        const char *base = name;
        while (base[0] == '.' && base[1] == '/') base += 2;
        if (strncmp(base, "data.tar", 8) == 0) {
            strncpy(memberName, base, sizeof(memberName) - 1);
            rc = pm_read_member_mem(outer, entry, base, &payload, &payloadLen);
            break;
        }
    }
    if (gAr.read_close) gAr.read_close(outer);
    if (gAr.read_free) gAr.read_free(outer);
    if (!payload) return PM_AR_ERR_FORMAT;

    int count = 0;
    archive_t *inner = gAr.read_new();
    if (inner) {
        if (gAr.read_support_filter_all) gAr.read_support_filter_all(inner);
        if (gAr.read_support_format_tar) gAr.read_support_format_tar(inner);
        if (gAr.read_open_memory(inner, payload, payloadLen) == 0) {
            archive_entry_t *e2 = NULL;
            while (gAr.read_next_header(inner, &e2) == 0) {
                const char *n2 = gAr.entry_pathname(e2);
                if (!n2) continue;
                unsigned int ft = gAr.entry_filetype ? gAr.entry_filetype(e2) : 0;
                if (ft == PM_AE_IFDIR) continue;
                count++;
                if (count >= PM_AR_MAX_ENTRIES) break;
            }
        }
        if (gAr.read_close) gAr.read_close(inner);
        if (gAr.read_free) gAr.read_free(inner);
    }
    free(payload);
    *filesOut = count;
    return PM_AR_OK;
}

/// 判断条目是否属于"插件文件"（dylibOnly 模式用）
static int pm_is_plugin_entry(const char *rel) {
    if (!rel) return 0;
    size_t n = strlen(rel);
    const char *suffixes[] = { ".dylib", ".plist", ".dylib.disabled", ".plist.disabled", NULL };
    for (int i = 0; suffixes[i]; i++) {
        size_t sl = strlen(suffixes[i]);
        if (n > sl && strcmp(rel + n - sl, suffixes[i]) == 0) return 1;
    }
    // 也保留 DynamicLibraries 下的全部内容
    if (strstr(rel, "DynamicLibraries/")) return 1;
    if (strstr(rel, "TweakInject/")) return 1;
    if (strstr(rel, "Library/MobileSubstrate/")) return 1;
    return 0;
}

int pm_deb_extract(const char *debPath, const char *destDir,
                   int dylibOnly, pm_extract_result *out) {
    if (!destDir) return PM_AR_ERR_USAGE;
    if (out) memset(out, 0, sizeof(*out));
    if (pm_ar_load() != PM_AR_OK) return PM_AR_ERR_UNAVAILABLE;

    if (pm_mkdirs(destDir) != 0) return PM_AR_ERR_IO;

    archive_t *outer = NULL;
    int rc = pm_open_deb(debPath, &outer);
    if (rc != PM_AR_OK) return rc;

    unsigned char *payload = NULL;
    size_t payloadLen = 0;
    char memberName[64] = {0};

    archive_entry_t *entry = NULL;
    while (gAr.read_next_header(outer, &entry) == 0) {
        const char *name = gAr.entry_pathname(entry);
        if (!name) continue;
        const char *base = name;
        while (base[0] == '.' && base[1] == '/') base += 2;
        if (strncmp(base, "data.tar", 8) == 0) {
            strncpy(memberName, base, sizeof(memberName) - 1);
            rc = pm_read_member_mem(outer, entry, base, &payload, &payloadLen);
            break;
        }
    }
    if (gAr.read_close) gAr.read_close(outer);
    if (gAr.read_free) gAr.read_free(outer);
    if (!payload) return PM_AR_ERR_FORMAT;

    int extracted = 0;
    int skipped = 0;
    unsigned long long totalBytes = 0;

    archive_t *inner = gAr.read_new();
    if (!inner) { free(payload); return PM_AR_ERR_IO; }
    if (gAr.read_support_filter_all) gAr.read_support_filter_all(inner);
    if (gAr.read_support_format_tar) gAr.read_support_format_tar(inner);

    if (gAr.read_open_memory(inner, payload, payloadLen) != 0) {
        if (gAr.read_free) gAr.read_free(inner);
        free(payload);
        return PM_AR_ERR_FORMAT;
    }

    archive_entry_t *e2 = NULL;
    while (gAr.read_next_header(inner, &e2) == 0) {
        const char *rel = gAr.entry_pathname(e2);
        if (!rel || !*rel) { skipped++; continue; }

        // 去掉 tar 常见的 ./ 前缀
        const char *clean = rel;
        while (clean[0] == '.' && clean[1] == '/') clean += 2;
        if (clean[0] == '\0') { skipped++; continue; }

        // 去掉 deb 包里的绝对根前缀，避免把系统文件写到 destDir 外
        while (clean[0] == '/') clean++;

        unsigned int ft = gAr.entry_filetype ? gAr.entry_filetype(e2) : 0;

        if (ft == PM_AE_IFDIR) {
            char dirPath[1024];
            if (pm_safe_subpath(destDir, clean, dirPath, sizeof(dirPath)) == PM_AR_OK) {
                pm_mkdirs(dirPath);
            } else {
                skipped++;
            }
            continue;
        }

        if (dylibOnly && !pm_is_plugin_entry(clean)) { skipped++; continue; }

        long long declared = gAr.entry_size(e2);
        if (declared > (long long)PM_AR_MAX_FILE_BYTES) { skipped++; continue; }
        if (totalBytes + (unsigned long long)(declared > 0 ? declared : 0) > PM_AR_MAX_TOTAL_BYTES) {
            skipped++;
            break;   // 总量到顶，停止
        }

        char outPath[1024];
        if (pm_safe_subpath(destDir, clean, outPath, sizeof(outPath)) != PM_AR_OK) {
            skipped++;
            continue;
        }

        // 建父目录
        char parent[1024];
        strncpy(parent, outPath, sizeof(parent) - 1);
        parent[sizeof(parent) - 1] = '\0';
        char *slash = strrchr(parent, '/');
        if (slash) { *slash = '\0'; pm_mkdirs(parent); }

        int fd = open(outPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) { skipped++; continue; }

        unsigned long long written = 0;
        int failed = 0;
        char chunk[16384];
        for (;;) {
            long long got = gAr.read_data(inner, chunk, sizeof(chunk));
            if (got < 0) { failed = 1; break; }
            if (got == 0) break;
            if (written + (unsigned long long)got > PM_AR_MAX_FILE_BYTES) { failed = 1; break; }
            ssize_t w = write(fd, chunk, (size_t)got);
            if (w != (ssize_t)got) { failed = 1; break; }
            written += (unsigned long long)got;
        }
        close(fd);

        if (failed) {
            unlink(outPath);
            skipped++;
            continue;
        }
        extracted++;
        totalBytes += written;
    }

    if (gAr.read_close) gAr.read_close(inner);
    if (gAr.read_free) gAr.read_free(inner);
    free(payload);

    if (out) {
        out->extracted = extracted;
        out->skipped = skipped;
        out->bytes = totalBytes;
        snprintf(out->detail, sizeof(out->detail), "extracted=%d skipped=%d bytes=%llu member=%s",
                 extracted, skipped, totalBytes, memberName);
    }
    return PM_AR_OK;
}

int pm_zip_pack(const char *const *paths, int count, const char *outZip) {
    if (!paths || count <= 0 || !outZip) return PM_AR_ERR_USAGE;
    if (pm_ar_load() != PM_AR_OK) return PM_AR_ERR_UNAVAILABLE;
    if (!gAr.write_new || !gAr.write_set_format_zip || !gAr.entry_new) return PM_AR_ERR_UNAVAILABLE;

    archive_t *ar = gAr.write_new();
    if (!ar) return PM_AR_ERR_IO;
    gAr.write_set_format_zip(ar);
    if (gAr.write_add_filter_none) gAr.write_add_filter_none(ar);

    if (gAr.write_open_filename(ar, outZip) != 0) {
        if (gAr.write_free) gAr.write_free(ar);
        return PM_AR_ERR_OPEN;
    }

    int added = 0;
    for (int i = 0; i < count; i++) {
        const char *p = paths[i];
        if (!p) continue;
        struct stat st;
        if (stat(p, &st) != 0 || !S_ISREG(st.st_mode)) continue;
        if ((unsigned long long)st.st_size > PM_AR_MAX_FILE_BYTES) continue;

        FILE *fp = fopen(p, "rb");
        if (!fp) continue;

        archive_entry_t *e = gAr.entry_new();
        if (!e) { fclose(fp); continue; }

        const char *leaf = strrchr(p, '/');
        leaf = leaf ? leaf + 1 : p;
        gAr.entry_set_pathname(e, leaf);
        gAr.entry_set_size(e, st.st_size);
        if (gAr.entry_set_filetype) gAr.entry_set_filetype(e, PM_AE_IFREG);
        if (gAr.entry_set_perm) gAr.entry_set_perm(e, 0644);
        if (gAr.entry_set_mtime) gAr.entry_set_mtime(e, (long)st.st_mtime);

        if (gAr.write_header(ar, e) == 0) {
            char chunk[16384];
            size_t got;
            int ok = 1;
            while ((got = fread(chunk, 1, sizeof(chunk), fp)) > 0) {
                if (gAr.write_data(ar, chunk, got) < 0) { ok = 0; break; }
            }
            if (ok) added++;
        }
        if (gAr.entry_free) gAr.entry_free(e);
        fclose(fp);
    }

    if (gAr.write_close) gAr.write_close(ar);
    if (gAr.write_free) gAr.write_free(ar);
    return added > 0 ? PM_AR_OK : PM_AR_ERR_IO;
}
