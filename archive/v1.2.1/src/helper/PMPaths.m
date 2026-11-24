#import "PMPaths.h"
#import <sys/stat.h>
#import <stdlib.h>
#import <limits.h>

static BOOL PMStatKind(NSString *path, mode_t wantMask, mode_t wantType) {
    if (path.length == 0) return NO;
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) return NO;
    if ((st.st_mode & S_IFMT) != wantType) return NO;
    return (st.st_mode & wantMask) == wantMask;
}

BOOL PMIsSymlink(NSString *path) {
    if (path.length == 0) return NO;
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) return NO;
    return (st.st_mode & S_IFMT) == S_IFLNK;
}

BOOL PMIsRegularFile(NSString *path) { return PMStatKind(path, 0, S_IFREG); }
BOOL PMIsDirectory(NSString *path) { return PMStatKind(path, 0, S_IFDIR); }

NSString *PMJBRoot(void) {
    static NSString *root = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        root = PMIsDirectory(@"/var/jb") ? @"/var/jb" : @"";
    });
    return root;
}

static NSString *PMRealPath(NSString *path) {
    char buf[PATH_MAX];
    if (realpath(path.fileSystemRepresentation, buf) == NULL) return nil;
    return [NSString stringWithUTF8String:buf];
}

FOUNDATION_EXPORT NSString *PMResolveInjectDirectory(void) {
    NSArray<NSString *> *candidates = @[
        @"/var/jb/usr/lib/TweakInject",
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries",
        @"/usr/lib/TweakInject",
        @"/Library/MobileSubstrate/DynamicLibraries",
    ];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *cand in candidates) {
        if (!PMIsDirectory(cand)) continue;
        NSString *real = PMRealPath(cand) ?: cand;
        if ([seen containsObject:real]) continue;
        [seen addObject:real];
        return real;
    }
    return nil;
}
