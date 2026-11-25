//
//  PMArchiveOps.h — deb / tar / zip 操作（纯 C，libarchive 运行时加载）
//
//  设计要点：
//  1. 不在链接期硬依赖 libarchive。用 dlopen/dlsym 运行时解析，
//     设备缺库时只让文件管理功能不可用，插件开关照常工作。
//  2. 所有写操作限制在白名单目录内，条目路径含 .. 或绝对路径一律跳过。
//  3. 单文件与总量都有上限，防止解包炸弹。
//

#ifndef PM_ARCHIVE_OPS_H
#define PM_ARCHIVE_OPS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// 用独立区间，避免与 PMFsOps 的 PM_ERR_* 在 switch 里撞值
enum {
    PM_AR_OK = 0,
    PM_AR_ERR_UNAVAILABLE = -101,
    PM_AR_ERR_OPEN        = -102,
    PM_AR_ERR_FORMAT      = -103,
    PM_AR_ERR_IO          = -104,
    PM_AR_ERR_TOO_BIG     = -105,
    PM_AR_ERR_BADPATH     = -106,
    PM_AR_ERR_NOSPACE     = -107,
    PM_AR_ERR_USAGE       = -108,
};

#define PM_AR_MAX_FILE_BYTES   (64ULL * 1024 * 1024)
#define PM_AR_MAX_TOTAL_BYTES  (256ULL * 1024 * 1024)
#define PM_AR_MAX_ENTRIES      8000

typedef struct {
    char name[256];
    unsigned long long size;
} pm_entry;

typedef struct {
    pm_entry *items;
    int count;
    int capacity;
} pm_entry_list;

typedef struct {
    int extracted;
    int skipped;
    unsigned long long bytes;
    char detail[256];
} pm_extract_result;

int pm_archive_available(void);
int pm_deb_members(const char *debPath, pm_entry_list *out);
int pm_deb_control(const char *debPath, char *buf, size_t cap);
int pm_deb_count_files(const char *debPath, int *filesOut);
int pm_deb_extract(const char *debPath, const char *destDir, int dylibOnly, pm_extract_result *out);
int pm_zip_pack(const char *const *paths, int count, const char *outZip);

/// 解压 zip 到 destDir（与 deb 解包共用同一套路径安全与大小限制）
int pm_zip_extract(const char *zipPath, const char *destDir, pm_extract_result *out);
void pm_entry_list_free(pm_entry_list *list);
int pm_safe_subpath(const char *baseDir, const char *relPath, char *out, size_t cap);

#ifdef __cplusplus
}
#endif

#endif