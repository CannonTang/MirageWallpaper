// windows/compat/unistd.h ────────────────────────────────────────────────────
// Minimal POSIX <unistd.h> compatibility shim for Windows (clang / MSVC).
// Placed in windows/compat/ and prepended to the include search path so that
//   #include <unistd.h>
// in existing cross-platform sources finds this file instead of failing.
//
// Only the subset actually referenced by SceneRenderer is implemented here.
// ────────────────────────────────────────────────────────────────────────────
#pragma once

#include <io.h>      // _sopen_s, _close, _O_WRONLY, _O_CREAT, _O_EXCL, _O_BINARY
#include <fcntl.h>   // O_WRONLY, O_CREAT, O_EXCL  (POSIX aliases provided by MSVC)
#include <direct.h>  // _mkdir
#include <cstdio>    // FILE, _fdopen
#include <cstring>   // strlen, strcmp
#include <cerrno>    // errno, EINVAL, EEXIST
#include <cstdlib>   // rand_s, errno_t

// ── Missing POSIX open-flags ─────────────────────────────────────────────────
#ifndef O_NOFOLLOW
// Windows NTFS has no kernel-level symlink-follow toggle at open(2) time.
// Treating the flag as a no-op is acceptable: the dump paths are derived
// from content hashes in a user-writable temp directory, and NTFS reparse
// attacks are out of scope for a wallpaper renderer.
#  define O_NOFOLLOW 0
#endif
#ifndef O_NOATIME
#  define O_NOATIME 0
#endif

// ── open / close / fdopen ─────────────────────────────────────────────────────
// MSVC exposes only the underscore variants; define the bare POSIX names in
// the global namespace so that unqualified or ::-qualified calls compile.
#ifndef _WIN_COMPAT_OPEN_DEFINED
#define _WIN_COMPAT_OPEN_DEFINED

#ifdef __cplusplus
inline int open(const char* path, int oflag, int /*pmode*/ = 0) noexcept {
    int fd = -1;
    _sopen_s(&fd, path,
             oflag | _O_BINARY,   // always binary; POSIX has no text mode
             _SH_DENYNO,
             _S_IREAD | _S_IWRITE);
    return fd;
}
inline int   close (int fd)               noexcept { return _close(fd); }
inline FILE* fdopen(int fd, const char* m) noexcept { return _fdopen(fd, m); }
#endif  // __cplusplus

#endif  // _WIN_COMPAT_OPEN_DEFINED

// ── mkdtemp ───────────────────────────────────────────────────────────────────
#ifndef _WIN_COMPAT_MKDTEMP_DEFINED
#define _WIN_COMPAT_MKDTEMP_DEFINED

#ifdef __cplusplus
inline char* mkdtemp(char* tmpl) noexcept {
    if (!tmpl) { errno = EINVAL; return nullptr; }
    const std::size_t len = std::strlen(tmpl);
    if (len < 6 || std::strcmp(tmpl + len - 6, "XXXXXX") != 0) {
        errno = EINVAL;
        return nullptr;
    }
    // 36-character alphabet → 36^6 ≈ 2.1 billion unique directories
    static constexpr char kAlpha[] = "abcdefghijklmnopqrstuvwxyz0123456789";
    constexpr int         kN       = sizeof(kAlpha) - 1;  // 36

    for (int attempts = 0; attempts < 256; ++attempts) {
        unsigned r = 0;
        if (rand_s(&r) != 0) { errno = EACCES; return nullptr; }
        for (int i = 0; i < 6; ++i, r /= kN)
            tmpl[len - 6 + i] = kAlpha[r % kN];
        if (_mkdir(tmpl) == 0) return tmpl;  // success
        if (errno != EEXIST) return nullptr; // unexpected error
    }
    errno = EEXIST;
    return nullptr;
}
#endif  // __cplusplus

#endif  // _WIN_COMPAT_MKDTEMP_DEFINED

// ── std::filesystem::path::native() ──────────────────────────────────────────
// On Windows, path::native() returns std::wstring (value_type = wchar_t in
// the MSVC STL).  ShaderCompiler.cpp was written against POSIX semantics where
// native() and string() both return std::string.  Map the call to string()
// which returns a narrow (UTF-8 / ANSI) std::string on every platform.
//
// This #define is scoped to translation units that include <unistd.h> — in
// practice, only ShaderCompiler.cpp.
#if defined(_WIN32) || defined(_WIN64)
#  ifndef _WIN_COMPAT_PATH_NATIVE_DEFINED
#  define _WIN_COMPAT_PATH_NATIVE_DEFINED
#  define native() string()
#  endif
#endif
