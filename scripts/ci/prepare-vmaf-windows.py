#!/usr/bin/env python3
"""Apply Windows-only VMAF compatibility fixes and emit private build shims."""
import argparse
import pathlib
import re


UNISTD_HEADER = r'''#ifndef VMAF_WINDOWS_UNISTD_H
#define VMAF_WINDOWS_UNISTD_H
#include <io.h>
#include <direct.h>
#include <sys/stat.h>
#include <windows.h>
#ifndef isatty
#define isatty _isatty
#endif
#ifndef fileno
#define fileno _fileno
#endif
static __inline unsigned int sleep(unsigned int seconds) { Sleep(seconds * 1000u); return 0; }
static __inline void usleep(unsigned int microseconds) { Sleep((microseconds + 999u) / 1000u); }
#endif
'''

PTHREAD_HEADER = r'''#ifndef VMAF_WINDOWS_PTHREAD_H
#define VMAF_WINDOWS_PTHREAD_H
#include <windows.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef SRWLOCK pthread_mutex_t;
typedef CONDITION_VARIABLE pthread_cond_t;
typedef struct VmafThread *pthread_t;
typedef int pthread_mutexattr_t;
typedef int pthread_condattr_t;
#define PTHREAD_MUTEX_INITIALIZER SRWLOCK_INIT
#define PTHREAD_COND_INITIALIZER CONDITION_VARIABLE_INIT
int pthread_mutex_init(pthread_mutex_t *, const pthread_mutexattr_t *);
int pthread_mutex_destroy(pthread_mutex_t *);
int pthread_mutex_lock(pthread_mutex_t *);
int pthread_mutex_unlock(pthread_mutex_t *);
int pthread_cond_init(pthread_cond_t *, const pthread_condattr_t *);
int pthread_cond_destroy(pthread_cond_t *);
int pthread_cond_wait(pthread_cond_t *, pthread_mutex_t *);
int pthread_cond_signal(pthread_cond_t *);
int pthread_cond_broadcast(pthread_cond_t *);
int pthread_create(pthread_t *, const void *, void *(*)(void *), void *);
int pthread_join(pthread_t, void **);
int pthread_detach(pthread_t);
void pthread_exit(void *);
#ifdef __cplusplus
}
#endif
#endif
'''

# _beginthreadex initializes the CRT; a trampoline preserves pointer-width returns.
PTHREAD_SOURCE = r'''#include "pthread.h"
#include <process.h>
#include <stdlib.h>
#include <errno.h>
struct VmafThread {
    HANDLE handle;
    void *(*function)(void *);
    void *argument;
    void *result;
    LONG references;
};
static __declspec(thread) struct VmafThread *current_thread;
static void release_thread(struct VmafThread *t) {
    if (InterlockedDecrement(&t->references) == 0) free(t);
}
static unsigned __stdcall start_thread(void *argument) {
    struct VmafThread *t = argument;
    current_thread = t;
    t->result = t->function(t->argument);
    release_thread(t);
    return 0;
}
int pthread_mutex_init(pthread_mutex_t *m, const pthread_mutexattr_t *a) { (void)a; InitializeSRWLock(m); return 0; }
int pthread_mutex_destroy(pthread_mutex_t *m) { (void)m; return 0; }
int pthread_mutex_lock(pthread_mutex_t *m) { AcquireSRWLockExclusive(m); return 0; }
int pthread_mutex_unlock(pthread_mutex_t *m) { ReleaseSRWLockExclusive(m); return 0; }
int pthread_cond_init(pthread_cond_t *c, const pthread_condattr_t *a) { (void)a; InitializeConditionVariable(c); return 0; }
int pthread_cond_destroy(pthread_cond_t *c) { (void)c; return 0; }
int pthread_cond_wait(pthread_cond_t *c, pthread_mutex_t *m) { return SleepConditionVariableSRW(c, m, INFINITE, 0) ? 0 : EINVAL; }
int pthread_cond_signal(pthread_cond_t *c) { WakeConditionVariable(c); return 0; }
int pthread_cond_broadcast(pthread_cond_t *c) { WakeAllConditionVariable(c); return 0; }
int pthread_create(pthread_t *out, const void *a, void *(*f)(void *), void *arg) {
    struct VmafThread *t;
    (void)a;
    if (!out || !f) return EINVAL;
    t = calloc(1, sizeof(*t));
    if (!t) return ENOMEM;
    t->function = f; t->argument = arg; t->references = 2;
    t->handle = (HANDLE)_beginthreadex(NULL, 0, start_thread, t, 0, NULL);
    if (!t->handle) { free(t); return EAGAIN; }
    *out = t;
    return 0;
}
int pthread_join(pthread_t t, void **result) {
    if (!t || WaitForSingleObject(t->handle, INFINITE) != WAIT_OBJECT_0) return EINVAL;
    if (result) *result = t->result;
    CloseHandle(t->handle);
    release_thread(t);
    return 0;
}
int pthread_detach(pthread_t t) {
    if (!t || !CloseHandle(t->handle)) return EINVAL;
    release_thread(t);
    return 0;
}
void pthread_exit(void *result) {
    if (current_thread) {
        current_thread->result = result;
        release_thread(current_thread);
    }
    _endthreadex(0);
}
'''


def prepare(source, compat, architecture, cuda=False, include_dirs=()):
    source, compat = pathlib.Path(source), pathlib.Path(compat)
    if not (source / 'src').is_dir():
        raise ValueError('source must be the VMAF libvmaf directory')
    compat.mkdir(parents=True, exist_ok=True)
    (compat / "pthread.h").write_text(PTHREAD_HEADER, encoding="utf-8")
    (compat / "pthread_shim.c").write_text(PTHREAD_SOURCE, encoding="utf-8")
    (compat / "unistd.h").write_text(UNISTD_HEADER, encoding="utf-8")
    attributes = source / "src/compat/msvc/common/attributes.h"
    attributes.parent.mkdir(parents=True, exist_ok=True)
    if not attributes.exists():
        attributes.write_text("#ifndef VMAF_MSVC_ATTRIBUTES_H\n#define VMAF_MSVC_ATTRIBUTES_H\n#include <stddef.h>\n#define ALIGN(n) __declspec(align(n))\n#endif\n", encoding="utf-8")

    for relative in ("src/libvmaf.c", "src/predict.c", "src/read_json_model.c", "src/feature/integer_vif.h", "src/feature/integer_vif.c", "src/feature/integer_adm.c", "src/log.c", "src/feature/cuda/integer_adm_cuda.c", "src/feature/mkdirp.c", "src/feature/mkdirp.h", "src/feature/arm64/adm_neon.c", "src/feature/integer_adm.h", "src/meson.build"):
        path = source / relative
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        text = text.replace("#ifdef HAVE_ALLOCA_H", "#if defined(HAVE_ALLOCA_H) && HAVE_ALLOCA_H")
        if relative in ("src/libvmaf.c", "src/predict.c", "src/read_json_model.c"):
            replacements = {
                "double scores[model_collection->cnt];": "double *scores = (double *)_alloca(model_collection->cnt * sizeof(double));",
                "char name[name_sz];": "char *name = (char *)_alloca(name_sz);",
                "char cfg_name[cfg_name_sz];": "char *cfg_name = (char *)_alloca(cfg_name_sz);",
                "char generated_key[generated_key_sz];": "char *generated_key = (char *)_alloca(generated_key_sz);",
            }
            if any(old in text for old in replacements) and "#include <malloc.h>" not in text:
                text = "#include <malloc.h>\n" + text
            for old, new in replacements.items():
                text = text.replace(old, new)
        if relative in ("src/feature/integer_vif.h", "src/log.c", "src/feature/cuda/integer_adm_cuda.c"):
            text = text.replace("#ifdef _MSC_VER\n", "#if defined(_MSC_VER) && !defined(__clang__)\n")
        if relative == "src/feature/integer_vif.c":
            text = re.sub(r"data \+= (.+?);", r"data = (void *)((unsigned char *)data + \1);", text)
        if architecture == "x64" and relative == "src/feature/integer_adm.c" and "__builtin_clz(" in text and "#define __builtin_clz" not in text:
            text = "#if defined(_MSC_VER) && !defined(__clang__)\n#include <intrin.h>\n#define __builtin_clz(x) __lzcnt(x)\n#endif\n" + text
        if architecture == "arm64" and relative in ("src/feature/integer_vif.h", "src/feature/integer_adm.c"):
            text = text.replace("__lzcnt64(", "_CountLeadingZeros64(").replace("__lzcnt(", "_CountLeadingZeros(")
            if relative == "src/feature/integer_adm.c":
                text = text.replace("__builtin_clz(", "_CountLeadingZeros(")
            if "#include <intrin.h>" not in text:
                text = "#include <intrin.h>\n" + text
        if relative in ("src/feature/mkdirp.c", "src/feature/mkdirp.h", "src/log.c", "src/feature/cuda/integer_adm_cuda.c"):
            if "#ifndef VMAF_MODE_T" not in text:
                text = text.replace("#include <sys/types.h>", "#include <sys/types.h>\n#ifndef VMAF_MODE_T\n#define VMAF_MODE_T\ntypedef int mode_t;\n#endif")
            text = text.replace("int rc = mkdir(pathname);", "int rc = _mkdir(pathname);")
        if relative == "src/feature/arm64/adm_neon.c" and architecture == "arm64":
            text = text.replace("const int32x4_t lanes = { 0, 1, 2, 3 };", "const int32_t lane_values[4] = {0, 1, 2, 3};\n    const int32x4_t lanes = vld1q_s32(lane_values);")
            text = text.replace("const float32x4_t result = {\n        (float)vgetq_lane_s64(lo, 0), (float)vgetq_lane_s64(lo, 1),\n        (float)vgetq_lane_s64(hi, 0), (float)vgetq_lane_s64(hi, 1)\n    };", "const float result_values[4] = {\n        (float)vgetq_lane_s64(lo, 0), (float)vgetq_lane_s64(lo, 1),\n        (float)vgetq_lane_s64(hi, 0), (float)vgetq_lane_s64(hi, 1)\n    };\n    const float32x4_t result = vld1q_f32(result_values);")
        if cuda and relative == "src/feature/integer_adm.h":
            text = re.sub(r"\.\w+\s*=\s*", "", text)
        if cuda and relative == "src/meson.build" and "# windows-private-includes" not in text:
            extra = "\n                # windows-private-includes\n" + "".join("                '-I', '" + str(directory).replace("\\", "/").replace("'", "\\'") + "',\n" for directory in (compat, *include_dirs))
            old = "'-I', '../src/' + cuda_dir,"
            if old not in text:
                raise ValueError("VMAF CUDA include command changed; cannot inject private headers")
            text = text.replace(old, old + extra, 1)
        path.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("compat", type=pathlib.Path)
    parser.add_argument("--architecture", choices=("x64", "arm64"), required=True)
    parser.add_argument("--cuda", action="store_true")
    parser.add_argument("--include-dir", action="append", default=[])
    args = parser.parse_args()
    prepare(args.source, args.compat, args.architecture, args.cuda, args.include_dir)
