//
//  PMFsOps.h — 文件系统核心操作（不含 Foundation，可在宿主机原生编译做单元测试）
//  约定：所有返回值 0 表示成功，负数为错误码（见 PM_ERR_*）。
//

#ifndef PM_FS_OPS_H
#define PM_FS_OPS_H

#ifdef __cplusplus
extern "C" {
#endif

#define PM_ID_MAX 128
#define PM_PATH_MAX 1024
#define PM_MAX_PLUGINS 4096

enum {
    PM_OK = 0,
    PM_ERR_USAGE = -1,
    PM_ERR_BAD_ID = -2,
    PM_ERR_NO_DIR = -3,
    PM_ERR_NOENT = -4,
    PM_ERR_NOSTATE = -5,
    PM_ERR_IO = -6,
    PM_ERR_TOOMANY = -7,
};

/// 插件标识白名单：字母数字 . _ + - ，长度 1..128
int pm_valid_id(const char *ident);

/// 是否为目录（跟随符号链接判断目标类型）
int pm_is_dir(const char *path);

/// 普通文件（不含符号链接）
int pm_is_regular(const char *path);

/// 符号链接
int pm_is_symlink(const char *path);

/// 规划一次开关：把 dylib 与（存在的）plist 的目标路径写进 plan。
/// plan 形如 [["/dir/X.dylib.disabled", "/dir/X.dylib"], ["...","..."]]，每项 from/to。
/// 返回值：0 成功；否则错误码。成功时 *count 为 1 或 2。
int pm_plan_switch(const char *dir, const char *ident, int enable,
                   char from[2][PM_PATH_MAX], char to[2][PM_PATH_MAX], int *count);

/// 执行计划（逐条 rename），任一步失败则回滚已完成的步骤。返回 0 或 PM_ERR_IO。
int pm_apply_plan(char from[2][PM_PATH_MAX], char to[2][PM_PATH_MAX], int count);

/// 扫描目录，收集插件标识（去重，按字典序）。返回收集数量；错误时返回负值。
int pm_scan_ids(const char *dir, char ids[][PM_ID_MAX + 1], int max_ids);

/// 一站式开关：规划 + 执行。成功返回 0，*moved 返回实际改名的文件数。
int pm_switch(const char *dir, const char *ident, int enable, int *moved);

#ifdef __cplusplus
}
#endif

#endif
