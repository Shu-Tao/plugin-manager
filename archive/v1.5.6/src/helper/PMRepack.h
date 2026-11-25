//
//  PMRepack.h — 从已装文件重新打包 deb
//
//  插件装到设备后原始 .deb 常常已从 apt 缓存清除，但 dpkg 数据库仍完整记录
//  该包的所有文件清单与元信息。据此可用 dpkg-deb 重建一个可安装的 .deb。
//
//  注意：重建包不含 maintainer scripts（postinst/prerm），因为系统不保存它们。
//  纯 dylib + plist 的插件不受影响；需要安装脚本的包行为可能不完整。
//

#ifndef PM_REPACK_H
#define PM_REPACK_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    PM_RP_OK = 0,
    PM_RP_ERR_USAGE = -1,
    PM_RP_ERR_NO_DPKG = -2,       // 找不到 dpkg-deb
    PM_RP_ERR_NO_PACKAGE = -3,    // status 里没有该包
    PM_RP_ERR_NO_LIST = -4,       // 缺少 .list
    PM_RP_ERR_IO = -5,
    PM_RP_ERR_TOO_BIG = -6,
    PM_RP_ERR_BUILD = -7,         // dpkg-deb 执行失败
};

#define PM_RP_MAX_TOTAL (512ULL * 1024 * 1024)   // 512 MB 上限

typedef struct {
    char package[128];
    char version[64];
    char architecture[64];
    char maintainer[128];
    char description[512];
    char depends[512];
    int fileCount;
    unsigned long long totalBytes;
} pm_pkg_meta;

/// 从 /var/lib/dpkg/status 读出指定包的元信息
int pm_repack_read_meta(const char *statusPath, const char *package, pm_pkg_meta *out);

/// 统计 .list 里登记的文件数（跳过目录与 dpkg 自身记录）
int pm_repack_count_files(const char *listPath, int *countOut);

/// 重新打包：stagingDir 需可写；dpkg-deb 路径由调用方给出
int pm_repack_build(const char *statusPath, const char *listPath,
                    const char *package, const char *stagingDir,
                    const char *outDeb, const char *dpkgDebPath,
                    pm_pkg_meta *outMeta);

/// 找 dpkg-deb 可执行文件；找到返回 1 并写入 buf
int pm_repack_find_dpkg_deb(char *buf, size_t cap);

#ifdef __cplusplus
}
#endif

#endif
