/*
 * c/selfcheck.h - sampled allocation self-check shared by both hook binaries.
 *
 * Every 10th run of a hook counts its own allocations and frees. If anything
 * is still live at exit, the run writes a one-line report the user can paste
 * into the plugin issue tracker; a clean run only appends to the log.
 *
 * Counting, not leak-detector: macOS ASan has no LeakSanitizer and a shipped
 * hook cannot depend on a debugger. The counter catches the common case - a
 * buffer or hit list whose owner forgot its free path.
 *
 * Define before including:
 *   SG_TOOL     binary name used in the report       (default "hook")
 *   SG_VERSION  plugin version, checked by the tests (default "dev")
 *   SG_JSON     1 = print the report as a hook JSON message, 0 = plain text
 *
 * Environment:
 *   KIMI_CODE_HOME / HOME   where logs/ and the run counter live
 *   SG_SELFCHECK_STATE      override the counter file path (tests)
 *   SG_SELFTEST_LEAK        deliberately leak one block (tests only)
 */
#ifndef SG_SELFCHECK_H
#define SG_SELFCHECK_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef SG_VERSION
#define SG_VERSION "dev"
#endif
#ifndef SG_TOOL
#define SG_TOOL "hook"
#endif
#ifndef SG_JSON
#define SG_JSON 0
#endif

#define SG_RUNS_EVERY 10

#if defined(_WIN32)
#define sg_sc_platform "windows"
#include <direct.h>
#include <sys/stat.h>
#define sg_sc_mkdir(p) _mkdir(p)
#elif defined(__APPLE__)
#define sg_sc_platform "darwin"
#include <sys/stat.h>
#define sg_sc_mkdir(p) mkdir((p), 0700)
#else
#define sg_sc_platform "linux"
#include <sys/stat.h>
#define sg_sc_mkdir(p) mkdir((p), 0700)
#endif

#if defined(__aarch64__) || defined(_M_ARM64)
#define sg_sc_arch "arm64"
#else
#define sg_sc_arch "x86_64"
#endif

static unsigned long sg_sc_allocs;
static unsigned long sg_sc_frees;
static unsigned long sg_sc_live;
static int sg_sc_armed;

#if defined(__GNUC__) || defined(__clang__)
#define SG_SC_UNUSED __attribute__((unused))
#else
#define SG_SC_UNUSED
#endif

static SG_SC_UNUSED void *sg_sc_track_malloc(size_t n) {
    void *p = malloc(n);
    if (p != NULL) {
        sg_sc_allocs++;
        sg_sc_live++;
    }
    return p;
}

static SG_SC_UNUSED void *sg_sc_track_realloc(void *p, size_t n) {
    void *q = realloc(p, n);
    if (q != NULL && p == NULL) {
        sg_sc_allocs++;
        sg_sc_live++;
    }
    return q;
}

static SG_SC_UNUSED void sg_sc_track_free(void *p) {
    if (p != NULL) {
        sg_sc_frees++;
        if (sg_sc_live > 0) sg_sc_live--;
    }
    free(p);
}

#define malloc(n) sg_sc_track_malloc(n)
#define realloc(p, n) sg_sc_track_realloc((p), (n))
#define free(p) sg_sc_track_free(p)

static const char *sg_sc_state_path(void) {
    static char path[1024];
    const char *override = getenv("SG_SELFCHECK_STATE");
    if (override != NULL && override[0] != '\0') return override;
    const char *root = getenv("KIMI_CODE_HOME");
    const char *suffix = "";
    if (root == NULL || root[0] == '\0') {
        root = getenv("HOME");
        suffix = "/.kimi-code";
    }
    if (root == NULL || root[0] == '\0') return NULL;
    snprintf(path, sizeof path, "%s%s/logs", root, suffix);
    sg_sc_mkdir(path);
    snprintf(path, sizeof path, "%s%s/logs/%s.runs", root, suffix, SG_TOOL);
    return path;
}

static void sg_sc_start(void) {
    const char *path = sg_sc_state_path();
    if (path == NULL) return;
    unsigned long runs = 0;
    FILE *in = fopen(path, "r");
    if (in != NULL) {
        if (fscanf(in, "%lu", &runs) != 1) runs = 0;
        fclose(in);
    }
    runs = (runs + 1) % 100000;
    FILE *out = fopen(path, "w");
    if (out != NULL) {
        fprintf(out, "%lu\n", runs);
        fclose(out);
    }
    sg_sc_armed = (runs % SG_RUNS_EVERY) == 0;
}

static void sg_sc_end(void) {
    if (!sg_sc_armed) return;
    if (getenv("SG_SELFTEST_LEAK") != NULL) {
        void *planted = malloc(64);
        (void)planted;
    }
    if (sg_sc_live == 0) {
        const char *path = sg_sc_state_path();
        if (path == NULL) return;
        char log_path[1060];
        snprintf(log_path, sizeof log_path, "%.1024s.log", path);
        FILE *log = fopen(log_path, "a");
        if (log != NULL) {
            fprintf(log, "selfcheck ok allocs=%lu frees=%lu version=%s %s-%s\n",
                    sg_sc_allocs, sg_sc_frees, SG_VERSION, sg_sc_platform, sg_sc_arch);
            fclose(log);
        }
        return;
    }
    const char *path = sg_sc_state_path();
    if (path != NULL) {
        char log_path[1060];
        snprintf(log_path, sizeof log_path, "%.1024s.log", path);
        FILE *log = fopen(log_path, "a");
        if (log != NULL) {
            fprintf(log, "selfcheck LEAK live=%lu allocs=%lu frees=%lu version=%s %s-%s\n",
                    sg_sc_live, sg_sc_allocs, sg_sc_frees, SG_VERSION, sg_sc_platform,
                    sg_sc_arch);
            fclose(log);
        }
    }
    if (SG_JSON) {
        printf("{\"message\":\"%s self-check found a leak: live=%lu allocs=%lu frees=%lu "
               "version=%s %s-%s. Paste this line into "
               "https://github.com/thiensubs/kimi-plugin-codebase-memory/issues\"}\n",
               SG_TOOL, sg_sc_live, sg_sc_allocs, sg_sc_frees, SG_VERSION, sg_sc_platform,
               sg_sc_arch);
    } else {
        printf("[%s self-check] leak detected: live=%lu allocs=%lu frees=%lu version=%s "
               "%s-%s - paste this line into the plugin issue tracker\n",
               SG_TOOL, sg_sc_live, sg_sc_allocs, sg_sc_frees, SG_VERSION, sg_sc_platform,
               sg_sc_arch);
    }
    fflush(stdout);
}

#if defined(__GNUC__) || defined(__clang__)
__attribute__((constructor)) static void sg_sc_ctor(void) { sg_sc_start(); }
__attribute__((destructor)) static void sg_sc_dtor(void) { sg_sc_end(); }
#endif

#endif
