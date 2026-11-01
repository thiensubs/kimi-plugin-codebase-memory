/*
 * cbm_nudge.c — per-prompt "graph first" nudge for Kimi Code.
 *
 * Build:
 *   clang -O2 -std=c11 c/cbm_nudge.c -o bin/cbm_nudge
 *
 * Reads the UserPromptSubmit hook payload on stdin and prints a short reminder
 * when the prompt asks about code structure; prints nothing otherwise.
 * It replaces `codebase-memory-mcp hook-augment --dialect kimi`, which on this
 * machine costs 2.13 s per prompt and emitted nothing.
 *
 * Real payload shape (kimi-code 2.4.1):
 *   {"hook_event_name":"UserPromptSubmit","session_id":"…","cwd":"…",
 *    "client_type":"kimi_code_cli","prompt":[{"type":"text","text":"…"}],
 *    "is_steer":false}
 * `prompt` is an array of content blocks, not a string.
 */
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SG_TOOL "cbm_nudge"
#define SG_VERSION "0.2.3"
#define SG_JSON 0
#include "selfcheck.h"

#define MAX_PAYLOAD 65536
#define PROMPT_MAX 8192
#define CWD_MAX 1024

static const char *KEYWORDS[] = {
    "where is", "where does", "who calls", "callers", "callees",
    "call chain", "call graph", "trace", "function", "class", "method",
    "symbol", "module", "architecture", "structure", "dead code",
    "unused", "refactor", "impact", "dependency", "dependencies",
    "who uses", "implemented", "codebase", "entry point", "implementation",
    NULL
};

static const char *PROMPT_KEYS[] = {
    "prompt", "user_prompt", "text", "message", "user_message", "query", NULL
};

static const char *CWD_KEYS[] = {
    "cwd", "workspace", "project_path", "working_directory", NULL
};

static char *read_all(FILE *in) {
    char *buf = malloc(MAX_PAYLOAD + 1);
    if (!buf) return NULL;
    size_t len = fread(buf, 1, MAX_PAYLOAD, in);
    buf[len] = '\0';
    return buf;
}

static void copy_escaped(const char **pp, char *out, size_t *n, size_t out_len) {
    const char *p = *pp;
    while (*p && *p != '"' && *n + 1 < out_len) {
        if (*p == '\\' && p[1]) {
            p++;
            switch (*p) {
                case 'n': out[(*n)++] = '\n'; break;
                case 't': out[(*n)++] = '\t'; break;
                case 'r': out[(*n)++] = '\r'; break;
                default: out[(*n)++] = *p; break;
            }
            p++;
            continue;
        }
        out[(*n)++] = *p++;
    }
    *pp = p;
}

static int extract_string_field(const char *json, const char *key, char *out, size_t out_len) {
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);

    const char *p = strstr(json, pattern);
    if (!p) return 0;
    p += strlen(pattern);

    while (*p == ' ' || *p == '\t') p++;
    if (*p != ':') return 0;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    if (*p != '"') return 0;
    p++;

    size_t n = 0;
    copy_escaped(&p, out, &n, out_len);
    out[n] = '\0';
    return 1;
}

static const char *match_bracket(const char *open) {
    int depth = 0;
    int in_str = 0;
    int esc = 0;

    for (const char *r = open; *r; r++) {
        if (in_str) {
            if (esc) esc = 0;
            else if (*r == '\\') esc = 1;
            else if (*r == '"') in_str = 0;
            continue;
        }
        if (*r == '"') {
            in_str = 1;
            continue;
        }
        if (*r == '[' || *r == '{') {
            depth++;
        } else if (*r == ']' || *r == '}') {
            depth--;
            if (depth == 0) return r;
        }
    }
    return NULL;
}

static int extract_prompt_text(const char *json, char *out, size_t out_len) {
    const char *p = strstr(json, "\"prompt\"");
    if (!p) return 0;
    p += strlen("\"prompt\"");

    while (*p == ' ' || *p == '\t') p++;
    if (*p != ':') return 0;
    p++;
    while (*p == ' ' || *p == '\t') p++;

    if (*p == '"') {
        size_t n = 0;
        p++;
        copy_escaped(&p, out, &n, out_len);
        out[n] = '\0';
        return 1;
    }
    if (*p != '[') return 0;

    const char *end = match_bracket(p);
    if (!end) return 0;

    size_t n = 0;
    int found = 0;
    const char *scan = p;
    while ((scan = strstr(scan, "\"text\"")) != NULL && scan < end) {
        const char *q = scan + strlen("\"text\"");
        while (*q == ' ' || *q == '\t') q++;
        if (*q != ':') {
            scan += 6;
            continue;
        }
        q++;
        while (*q == ' ' || *q == '\t') q++;
        if (*q != '"') {
            scan += 6;
            continue;
        }
        q++;
        size_t start = n;
        copy_escaped(&q, out, &n, out_len);
        if (n > start) {
            out[n++] = '\n';
            found = 1;
        }
        scan = q;
    }
    out[n] = '\0';
    return found;
}

static int extract_first(const char *json, const char **keys, char *out, size_t out_len) {
    for (int i = 0; keys[i]; i++) {
        if (extract_string_field(json, keys[i], out, out_len)) return 1;
    }
    return 0;
}

static void log_key_names(const char *payload) {
    const char *root = getenv("KIMI_CODE_HOME");
    const char *suffix = "";
    if (!root || !*root) {
        root = getenv("HOME");
        suffix = "/.kimi-code";
    }
    if (!root || !*root) return;

    char path[1024];
    snprintf(path, sizeof(path), "%s%s/logs/cbm-nudge.log", root, suffix);

    FILE *f = fopen(path, "a");
    if (!f) return;

    fputs("keys:", f);
    const char *p = payload;
    int count = 0;
    while ((p = strchr(p, '"')) != NULL && count < 40) {
        const char *q = strchr(p + 1, '"');
        if (!q) break;
        const char *r = q + 1;
        while (*r == ' ') r++;
        if (*r == ':') {
            char name[64];
            size_t n = (size_t)(q - p - 1);
            if (n > 0 && n < sizeof(name)) {
                memcpy(name, p + 1, n);
                name[n] = '\0';
                fprintf(f, " %s", name);
                count++;
            }
        }
        p = q + 1;
    }
    fputs("\n", f);
    fclose(f);
}

static int looks_like_code_question(const char *text) {
    char lower[PROMPT_MAX];
    size_t n = strlen(text);
    if (n >= sizeof(lower)) n = sizeof(lower) - 1;
    for (size_t i = 0; i < n; i++) {
        lower[i] = (char)tolower((unsigned char)text[i]);
    }
    lower[n] = '\0';

    for (int i = 0; KEYWORDS[i]; i++) {
        if (strstr(lower, KEYWORDS[i]) != NULL) return 1;
    }
    return 0;
}

int main(void) {
    char *payload = read_all(stdin);
    if (!payload) return 0;

    char prompt[PROMPT_MAX];
    char cwd[CWD_MAX];

    if (!extract_prompt_text(payload, prompt, sizeof(prompt)) &&
        !extract_first(payload, PROMPT_KEYS, prompt, sizeof(prompt))) {
        log_key_names(payload);
        free(payload);
        return 0;
    }
    if (!extract_first(payload, CWD_KEYS, cwd, sizeof(cwd))) {
        cwd[0] = '\0';
    }
    free(payload);

    if (!looks_like_code_question(prompt)) return 0;

    printf("[codebase graph] Structure question detected - query the graph before grepping.\n");
    printf("  search_graph(name_pattern=...) locates symbols, trace_path gives callers and callees,\n");
    printf("  get_code_snippet gives the exact source. Grep/Read are for literals and config only.\n");
    printf("  Call list_projects once and use the project whose root_path contains the cwd.\n");
    if (cwd[0] != '\0') {
        printf("  cwd: %s\n", cwd);
    }
    return 0;
}
