/*
 * c/secret_guard.c - Kimi Code PreToolUse secret guard and stream redactor.
 *
 * Build:
 *   clang -O2 -std=c11 -Wall -Wextra c/secret_guard.c -o bin/secret_guard
 *
 * Modes:
 *   secret_guard          hook mode. Reads a PreToolUse payload on stdin.
 *                         allow -> no output, exit 0.
 *                         block -> deny JSON on stdout, one line on stderr, exit 2.
 *   secret_guard redact   filter mode. Reads plain text on stdin and writes it
 *                         back with every detected secret replaced by
 *                         [REDACTED:<label>]. Always exits 0.
 *
 * Fail-open: a malformed or empty payload allows the tool call. Nothing here
 * ever prints a secret value; the log records only the rule and the tool name.
 */
#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

/* MinGW declares mkdir(const char *) with one argument; POSIX wants two. */
#ifdef _WIN32
#include <direct.h>
#define sg_mkdir(p) _mkdir(p)
#else
#define sg_mkdir(p) mkdir((p), 0700)
#endif

#define SG_MAX_INPUT (32u * 1024u * 1024u)
#define MAX_TOKENS 256

/* ------------------------------------------------------------------ */
/* growable byte buffer                                               */
/* ------------------------------------------------------------------ */

typedef struct {
    char *data;
    size_t len;
    size_t cap;
} buf_t;

static void buf_init(buf_t *b) {
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
}

static void buf_free(buf_t *b) {
    free(b->data);
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
}

static int buf_grow(buf_t *b, size_t extra) {
    if (b->len + extra + 1 <= b->cap) return 1;
    size_t cap = b->cap ? b->cap : 4096;
    while (cap < b->len + extra + 1) {
        if (cap > SIZE_MAX / 2) return 0;
        cap *= 2;
    }
    char *p = realloc(b->data, cap);
    if (!p) return 0;
    b->data = p;
    b->cap = cap;
    return 1;
}

static int buf_add(buf_t *b, const char *s, size_t n) {
    if (n == 0) return 1;
    if (!buf_grow(b, n)) return 0;
    memcpy(b->data + b->len, s, n);
    b->len += n;
    b->data[b->len] = '\0';
    return 1;
}

static int buf_addc(buf_t *b, char c) {
    return buf_add(b, &c, 1);
}

static int buf_terminate(buf_t *b) {
    if (!buf_grow(b, 0)) return 0;
    b->data[b->len] = '\0';
    return 1;
}

static int read_stream(FILE *in, buf_t *b) {
    char chunk[65536];
    size_t got;
    while ((got = fread(chunk, 1, sizeof chunk, in)) > 0) {
        if (b->len + got > SG_MAX_INPUT) return 0;
        if (!buf_add(b, chunk, got)) return 0;
    }
    return buf_terminate(b);
}

/* ------------------------------------------------------------------ */
/* hit list                                                           */
/* ------------------------------------------------------------------ */

typedef struct {
    size_t start;
    size_t end;
    const char *label;
} hit_t;

typedef struct {
    hit_t *v;
    size_t n;
    size_t cap;
} hits_t;

static void hits_init(hits_t *h) {
    h->v = NULL;
    h->n = 0;
    h->cap = 0;
}

static void hits_free(hits_t *h) {
    free(h->v);
    h->v = NULL;
    h->n = 0;
    h->cap = 0;
}

static int hits_add(hits_t *h, size_t start, size_t end, const char *label) {
    if (h->n == h->cap) {
        size_t cap = h->cap ? h->cap * 2 : 16;
        hit_t *p = realloc(h->v, cap * sizeof *p);
        if (!p) return 0;
        h->v = p;
        h->cap = cap;
    }
    h->v[h->n].start = start;
    h->v[h->n].end = end;
    h->v[h->n].label = label;
    h->n++;
    return 1;
}

static int hit_cmp(const void *a, const void *b) {
    const hit_t *x = a;
    const hit_t *y = b;
    if (x->start < y->start) return -1;
    if (x->start > y->start) return 1;
    if (x->end > y->end) return -1;
    if (x->end < y->end) return 1;
    return 0;
}

/* Keep the leftmost, then longest, non-overlapping spans. */
static void hits_resolve(hits_t *h) {
    if (h->n < 2) return;
    qsort(h->v, h->n, sizeof(hit_t), hit_cmp);
    size_t w = 0;
    for (size_t r = 0; r < h->n; r++) {
        if (w > 0 && h->v[r].start < h->v[w - 1].end) continue;
        h->v[w++] = h->v[r];
    }
    h->n = w;
}

/* ------------------------------------------------------------------ */
/* character helpers                                                  */
/* ------------------------------------------------------------------ */

static int is_word(int c) {
    return isalnum((unsigned char)c) || c == '_';
}

static int is_body_char(int c) {
    return isalnum((unsigned char)c) || c == '-' || c == '_';
}

static int is_token_char(int c) {
    return isalnum((unsigned char)c) || c == '-' || c == '.' || c == '_' ||
           c == '~' || c == '+' || c == '/' || c == '=';
}

static int is_hex(int c) {
    return isxdigit((unsigned char)c) != 0;
}

static int hexval(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int mem_ci_eq(const char *a, const char *b, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (tolower((unsigned char)a[i]) != tolower((unsigned char)b[i])) return 0;
    }
    return 1;
}

static size_t find_sub(const char *s, size_t n, size_t from, const char *needle) {
    size_t m = strlen(needle);
    if (m == 0 || from >= n || n - from < m) return SIZE_MAX;
    for (size_t i = from; i + m <= n; i++) {
        if (s[i] == needle[0] && memcmp(s + i, needle, m) == 0) return i;
    }
    return SIZE_MAX;
}

static size_t find_sub_range(const char *s, size_t from, size_t to, const char *needle) {
    size_t m = strlen(needle);
    if (m == 0 || to <= from || to - from < m) return SIZE_MAX;
    for (size_t i = from; i + m <= to; i++) {
        if (s[i] == needle[0] && memcmp(s + i, needle, m) == 0) return i;
    }
    return SIZE_MAX;
}

/* ------------------------------------------------------------------ */
/* 1. provider key prefixes                                           */
/* ------------------------------------------------------------------ */

typedef struct {
    const char *prefix;
    size_t min_body;
    int dot_body; /* '.' also belongs to the body (SendGrid)            */
    int hex_body; /* body is a run of hex digits at least min_body long */
    const char *label;
} prefix_rule;

static const prefix_rule PREFIXES[] = {
    {"sk-svcacct-", 20, 0, 0, "openai-key"},
    {"github_pat_", 20, 0, 0, "github-token"},
    {"sk-or-v1-", 20, 0, 0, "openrouter-key"},
    {"dckr_pat_", 20, 0, 0, "dockerhub-token"},
    {"sk-proj-", 20, 0, 0, "openai-key"},
    {"sk-ant-", 20, 0, 0, "anthropic-key"},
    {"sk_live_", 10, 0, 0, "stripe-key"},
    {"sk_test_", 10, 0, 0, "stripe-key"},
    {"rk_live_", 10, 0, 0, "stripe-key"},
    {"rk_test_", 10, 0, 0, "stripe-key"},
    {"pk_live_", 10, 0, 0, "stripe-key"},
    {"pk_test_", 10, 0, 0, "stripe-key"},
    {"glpat-", 20, 0, 0, "gitlab-token"},
    {"glptt-", 20, 0, 0, "gitlab-token"},
    {"gloas-", 20, 0, 0, "gitlab-token"},
    {"nvapi-", 20, 0, 0, "nvidia-key"},
    {"pplx-", 20, 0, 0, "perplexity-key"},
    {"xoxb-", 10, 0, 0, "slack-token"},
    {"xoxp-", 10, 0, 0, "slack-token"},
    {"xoxa-", 10, 0, 0, "slack-token"},
    {"xoxs-", 10, 0, 0, "slack-token"},
    {"xoxr-", 10, 0, 0, "slack-token"},
    {"xapp-", 10, 0, 0, "slack-token"},
    {"pypi-", 20, 0, 0, "pypi-token"},
    {"csk-", 20, 0, 0, "cerebras-key"},
    {"xai-", 20, 0, 0, "xai-key"},
    {"gsk_", 20, 0, 0, "groq-key"},
    {"npm_", 20, 0, 0, "npm-token"},
    {"sbp_", 20, 0, 0, "supabase-token"},
    {"ya29.", 20, 0, 0, "google-oauth-token"},
    {"hf_", 20, 0, 0, "huggingface-token"},
    {"r8_", 20, 0, 0, "replicate-token"},
    {"ghp_", 20, 0, 0, "github-token"},
    {"gho_", 20, 0, 0, "github-token"},
    {"ghu_", 20, 0, 0, "github-token"},
    {"ghs_", 20, 0, 0, "github-token"},
    {"ghr_", 20, 0, 0, "github-token"},
    {"AKIA", 16, 0, 0, "aws-access-key"},
    {"ASIA", 16, 0, 0, "aws-access-key"},
    {"AIza", 30, 0, 0, "google-api-key"},
    {"SG.", 20, 1, 0, "sendgrid-key"},
    {"AC", 32, 0, 1, "twilio-key"},
    {"sk-", 20, 0, 0, "openai-style-key"},
};

#define NPREFIXES (sizeof PREFIXES / sizeof PREFIXES[0])

static void scan_providers(const char *s, size_t n, hits_t *hits) {
    size_t i = 0;
    while (i < n) {
        if (i > 0 && is_word((unsigned char)s[i - 1])) {
            i++;
            continue;
        }
        const prefix_rule *best = NULL;
        size_t best_len = 0;
        for (size_t r = 0; r < NPREFIXES; r++) {
            const prefix_rule *rule = &PREFIXES[r];
            size_t plen = strlen(rule->prefix);
            if (rule->prefix[0] != s[i]) continue;
            if (i + plen > n) continue;
            if (memcmp(s + i, rule->prefix, plen) != 0) continue;

            size_t j = i + plen;
            if (rule->hex_body) {
                size_t k = 0;
                while (j + k < n && is_hex((unsigned char)s[j + k])) k++;
                if (k < rule->min_body) continue;
                size_t total = plen + k;
                if (total > best_len) {
                    best = rule;
                    best_len = total;
                }
                continue;
            }
            while (j < n &&
                   (is_body_char((unsigned char)s[j]) || (rule->dot_body && s[j] == '.'))) {
                j++;
            }
            if (j - (i + plen) < rule->min_body) continue;
            if (j - i > best_len) {
                best = rule;
                best_len = j - i;
            }
        }
        if (best) {
            hits_add(hits, i, i + best_len, best->label);
            i += best_len;
        } else {
            i++;
        }
    }
}

/* ------------------------------------------------------------------ */
/* 2. PEM private key blocks                                          */
/* ------------------------------------------------------------------ */

#define PEM_SLACK (64u * 1024u)

static void scan_private_keys(const char *s, size_t n, hits_t *hits) {
    size_t i = 0;
    while (i < n) {
        size_t begin = find_sub(s, n, i, "-----BEGIN ");
        if (begin == SIZE_MAX) break;

        size_t line_end = begin;
        while (line_end < n && s[line_end] != '\n') line_end++;
        if (find_sub_range(s, begin, line_end, "PRIVATE KEY-----") == SIZE_MAX) {
            i = begin + 11;
            continue;
        }

        size_t limit = n;
        if (limit - begin > PEM_SLACK) limit = begin + PEM_SLACK;
        size_t end = line_end < n ? line_end : n;
        size_t e = find_sub(s, limit, line_end, "-----END ");
        while (e != SIZE_MAX) {
            size_t e_line_end = e;
            while (e_line_end < limit && s[e_line_end] != '\n') e_line_end++;
            size_t marker = find_sub_range(s, e, e_line_end, "PRIVATE KEY-----");
            if (marker != SIZE_MAX) {
                end = marker + strlen("PRIVATE KEY-----");
                break;
            }
            e = find_sub(s, limit, e + 10, "-----END ");
        }
        if (end <= begin) end = line_end;
        hits_add(hits, begin, end, "private-key");
        i = end;
    }
}

/* ------------------------------------------------------------------ */
/* 3. JWT                                                             */
/* ------------------------------------------------------------------ */

static void scan_jwt(const char *s, size_t n, hits_t *hits) {
    for (size_t i = 0; i + 3 < n; i++) {
        if (i > 0 && is_word((unsigned char)s[i - 1])) continue;
        if (memcmp(s + i, "eyJ", 3) != 0) continue;

        size_t j = i + 3;
        size_t c1 = 0;
        while (j < n && is_body_char((unsigned char)s[j])) {
            j++;
            c1++;
        }
        if (c1 < 8 || j >= n || s[j] != '.') continue;
        j++;
        size_t c2 = 0;
        while (j < n && is_body_char((unsigned char)s[j])) {
            j++;
            c2++;
        }
        if (c2 < 8 || j >= n || s[j] != '.') continue;
        j++;
        size_t c3 = 0;
        while (j < n && is_body_char((unsigned char)s[j])) {
            j++;
            c3++;
        }
        if (c3 < 8) continue;
        hits_add(hits, i, j, "jwt");
        i = j;
    }
}

/* ------------------------------------------------------------------ */
/* 4. Bearer tokens                                                   */
/* ------------------------------------------------------------------ */

static void scan_bearer(const char *s, size_t n, hits_t *hits) {
    for (size_t i = 0; i + 6 < n; i++) {
        if (i > 0 && is_word((unsigned char)s[i - 1])) continue;
        if (!mem_ci_eq(s + i, "bearer", 6)) continue;

        size_t j = i + 6;
        if (j < n && (is_word((unsigned char)s[j]) || s[j] == '-')) continue;
        if (j >= n || (s[j] != ' ' && s[j] != '\t')) continue;
        while (j < n && (s[j] == ' ' || s[j] == '\t')) j++;

        size_t t0 = j;
        while (j < n && is_token_char((unsigned char)s[j])) j++;
        if (j - t0 < 24) continue;
        hits_add(hits, t0, j, "bearer-token");
        i = j;
    }
}

/* ------------------------------------------------------------------ */
/* 5. URL credentials (mask the password only)                        */
/* ------------------------------------------------------------------ */

static void scan_url_creds(const char *s, size_t n, hits_t *hits) {
    for (size_t i = 0; i + 4 < n; i++) {
        if (i > 0 && is_word((unsigned char)s[i - 1])) continue;
        if (!isalpha((unsigned char)s[i])) continue;

        size_t k = i;
        while (k < n && (isalnum((unsigned char)s[k]) || s[k] == '+' || s[k] == '.' ||
                         s[k] == '-')) {
            k++;
        }
        if (k - i < 2 || k - i > 24) continue;
        if (k + 3 > n || memcmp(s + k, "://", 3) != 0) continue;

        size_t auth_start = k + 3;
        size_t auth_end = auth_start;
        while (auth_end < n) {
            char c = s[auth_end];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '/' || c == '?' ||
                c == '#' || c == '"' || c == '\'' || c == '>' || c == ')' || c == '\0') {
                break;
            }
            auth_end++;
        }

        size_t at = SIZE_MAX;
        for (size_t x = auth_start; x < auth_end; x++) {
            if (s[x] == '@') at = x;
        }
        if (at == SIZE_MAX) continue;

        size_t colon = SIZE_MAX;
        for (size_t x = auth_start; x < at; x++) {
            if (s[x] == ':') {
                colon = x;
                break;
            }
        }
        if (colon == SIZE_MAX) continue;

        size_t pstart = colon + 1;
        if (at < pstart + 3) continue;
        int all_digits = 1;
        for (size_t x = pstart; x < at; x++) {
            if (!isdigit((unsigned char)s[x])) {
                all_digits = 0;
                break;
            }
        }
        if (all_digits) continue;

        hits_add(hits, pstart, at, "url-credentials");
        i = auth_end;
    }
}

/* ------------------------------------------------------------------ */
/* 6. name = value context rules                                      */
/* ------------------------------------------------------------------ */

typedef struct {
    const char *name;
    const char *label;
} name_rule;

static const name_rule NAME_RULES[] = {
    {"client_secret", "client_secret"},
    {"encryption_key", "encryption_key"},
    {"private_key", "private_key"},
    {"refresh_token", "refresh_token"},
    {"access_token", "access_token"},
    {"signing_key", "signing_key"},
    {"session_key", "session_key"},
    {"secret_key", "secret_key"},
    {"access_key", "access_key"},
    {"auth_token", "auth_token"},
    {"credential", "credential"},
    {"authorization", "authorization"},
    {"password", "password"},
    {"apikey", "apikey"},
    {"api_key", "api_key"},
    {"api-key", "api-key"},
    {"passwd", "passwd"},
    {"secret", "secret"},
    {"token", "token"},
    {"pwd", "pwd"},
};

#define NNAME_RULES (sizeof NAME_RULES / sizeof NAME_RULES[0])

static const char *PLACEHOLDERS[] = {
    "your_", "example", "placeholder", "changeme", "xxxx", "dummy",
    "redacted", "todo", "sample", "test", "fake", "none", "null",
    "true", "false", NULL,
};

static const char *ENV_REFS[] = {
    "process.env", "os.environ", "env.", "getenv", "ENV[", "System.getenv", NULL,
};

static int starts_with_ci(const char *s, size_t n, const char *prefix) {
    size_t m = strlen(prefix);
    return n >= m && mem_ci_eq(s, prefix, m);
}

static int value_is_placeholder(const char *v, size_t n) {
    char low[256];
    size_t m = n < sizeof low - 1 ? n : sizeof low - 1;
    for (size_t i = 0; i < m; i++) low[i] = (char)tolower((unsigned char)v[i]);
    low[m] = '\0';
    for (int i = 0; PLACEHOLDERS[i]; i++) {
        if (strstr(low, PLACEHOLDERS[i]) != NULL) return 1;
    }
    return 0;
}

static int value_is_env_ref(const char *v, size_t n) {
    if (n == 0) return 0;
    if (v[0] == '$' || v[0] == '%' || v[0] == '<') return 1;
    for (int i = 0; ENV_REFS[i]; i++) {
        if (starts_with_ci(v, n, ENV_REFS[i])) return 1;
    }
    return 0;
}

static int value_is_secretish(const char *v, size_t n) {
    if (n < 12) return 0;
    if (value_is_env_ref(v, n)) return 0;
    if (value_is_placeholder(v, n)) return 0;

    unsigned char seen[256];
    memset(seen, 0, sizeof seen);
    int distinct = 0;
    int cls[4] = {0, 0, 0, 0};
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)v[i];
        if (!seen[c]) {
            seen[c] = 1;
            distinct++;
        }
        if (c >= 'a' && c <= 'z') cls[0] = 1;
        else if (c >= 'A' && c <= 'Z') cls[1] = 1;
        else if (c >= '0' && c <= '9') cls[2] = 1;
        else cls[3] = 1;
    }
    if (distinct < 6) return 0;
    if (cls[0] + cls[1] + cls[2] + cls[3] < 2) return 0;
    return 1;
}

static int is_value_delim(int c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '"' || c == '\'' ||
           c == ',' || c == ';' || c == ')' || c == ']' || c == '}' || c == '&' ||
           c == '|' || c == '>' || c == '<' || c == '`' || c == '\\' || c == '\0';
}

static void scan_context(const char *s, size_t n, hits_t *hits) {
    size_t i = 0;
    while (i < n) {
        if (i > 0 && is_word((unsigned char)s[i - 1])) {
            i++;
            continue;
        }
        int matched = 0;
        for (size_t r = 0; r < NNAME_RULES && !matched; r++) {
            const name_rule *rule = &NAME_RULES[r];
            size_t nl = strlen(rule->name);
            if (i + nl > n) continue;
            if (!mem_ci_eq(s + i, rule->name, nl)) continue;

            size_t j = i + nl;
            if (j < n && (s[j] == '"' || s[j] == '\'')) j++;
            while (j < n && (s[j] == ' ' || s[j] == '\t')) j++;
            if (j >= n || (s[j] != '=' && s[j] != ':')) continue;
            j++;
            while (j < n && (s[j] == ' ' || s[j] == '\t')) j++;

            size_t vstart = j;
            size_t vend = j;
            if (j < n && (s[j] == '"' || s[j] == '\'')) {
                char quote = s[j];
                vstart = j + 1;
                vend = vstart;
                while (vend < n && s[vend] != quote && s[vend] != '\n') vend++;
                if (vend >= n || s[vend] != quote) continue;
            } else {
                while (vend < n && !is_value_delim((unsigned char)s[vend])) vend++;
            }

            if (vend <= vstart) continue;
            if (!value_is_secretish(s + vstart, vend - vstart)) continue;

            hits_add(hits, vstart, vend, rule->label);
            i = vend;
            matched = 1;
        }
        if (!matched) i++;
    }
}

/* ------------------------------------------------------------------ */
/* known-secret fingerprints (40-bit, SHA-256)                         */
/* ------------------------------------------------------------------ */

typedef unsigned int u32;

static const u32 K256[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu, 0x59f111f1u,
    0x923f82a4u, 0xab1c5ed5u, 0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u, 0xe49b69c1u, 0xefbe4786u,
    0x0fc19dc6u, 0x240ca1ccu, 0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u,
    0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u, 0xa2bfe8a1u, 0xa81a664bu,
    0xc24b8b70u, 0xc76c51a3u, 0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au,
    0x5b9cca4fu, 0x682e6ff3u, 0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u
};

static u32 ror32(u32 x, int n) { return (x >> n) | (x << (32 - n)); }

static void sha256_block(u32 h[8], const unsigned char *p) {
    u32 w[64];
    for (int i = 0; i < 16; i++) {
        w[i] = ((u32)p[i * 4] << 24) | ((u32)p[i * 4 + 1] << 16) |
               ((u32)p[i * 4 + 2] << 8) | (u32)p[i * 4 + 3];
    }
    for (int i = 16; i < 64; i++) {
        u32 s0 = ror32(w[i - 15], 7) ^ ror32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        u32 s1 = ror32(w[i - 2], 17) ^ ror32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    u32 a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (int i = 0; i < 64; i++) {
        u32 s1 = ror32(e, 6) ^ ror32(e, 11) ^ ror32(e, 25);
        u32 ch = (e & f) ^ (~e & g);
        u32 t1 = hh + s1 + ch + K256[i] + w[i];
        u32 s0 = ror32(a, 2) ^ ror32(a, 13) ^ ror32(a, 22);
        u32 maj = (a & b) ^ (a & c) ^ (b & c);
        u32 t2 = s0 + maj;
        hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d;
    h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

static void sha256(const char *s, size_t n, unsigned char out[32]) {
    u32 h[8] = {0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
                0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u};
    size_t i = 0;
    for (; i + 64 <= n; i += 64) sha256_block(h, (const unsigned char *)s + i);
    unsigned char tail[128];
    size_t rem = n - i;
    if (rem) memcpy(tail, s + i, rem);
    tail[rem] = 0x80;
    size_t total = rem + 1;
    while (total % 64 != 56) tail[total++] = 0;
    unsigned long long bits = (unsigned long long)n * 8u;
    for (int k = 0; k < 8; k++) tail[total + k] = (unsigned char)(bits >> (56 - 8 * k));
    total += 8;
    for (size_t off = 0; off < total; off += 64) sha256_block(h, tail + off);
    for (int k = 0; k < 8; k++) {
        out[k * 4] = (unsigned char)(h[k] >> 24);
        out[k * 4 + 1] = (unsigned char)(h[k] >> 16);
        out[k * 4 + 2] = (unsigned char)(h[k] >> 8);
        out[k * 4 + 3] = (unsigned char)h[k];
    }
}

static void fp40(const char *s, size_t n, char out[11]) {
    unsigned char d[32];
    static const char hexd[] = "0123456789abcdef";
    sha256(s, n, d);
    for (int i = 0; i < 5; i++) {
        out[i * 2] = hexd[d[i] >> 4];
        out[i * 2 + 1] = hexd[d[i] & 15];
    }
    out[10] = '\0';
}

#define FP_TOKEN_MIN 16
#define FP_TOKEN_MAX 512
#define FP_REG_MAX 8192

static char FP_REG[FP_REG_MAX][11];
static size_t FP_REG_N;
static int FP_LOADED;

static const char *fp_registry_path(void) {
    static char path[1024];
    const char *env = getenv("SECRET_GUARD_FINGERPRINTS");
    if (env && *env) return env;
    const char *root = getenv("KIMI_CODE_HOME");
    const char *suffix = "";
    if (!root || !*root) {
        root = getenv("HOME");
        suffix = "/.kimi-code";
    }
    if (!root || !*root) return NULL;
    snprintf(path, sizeof path, "%s%s/secret-fingerprints.txt", root, suffix);
    return path;
}

static void fp_registry_load(void) {
    if (FP_LOADED) return;
    FP_LOADED = 1;
    const char *p = fp_registry_path();
    if (!p) return;
    FILE *f = fopen(p, "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof line, f) && FP_REG_N < FP_REG_MAX) {
        size_t n = 0;
        while (line[n] && !isspace((unsigned char)line[n]) && line[n] != '#') n++;
        if (n != 10) continue;
        int ok = 1;
        for (size_t i = 0; i < 10; i++) {
            if (!is_hex((unsigned char)line[i])) { ok = 0; break; }
        }
        if (!ok) continue;
        for (size_t i = 0; i < 10; i++) {
            FP_REG[FP_REG_N][i] = (char)tolower((unsigned char)line[i]);
        }
        FP_REG[FP_REG_N][10] = '\0';
        FP_REG_N++;
    }
    fclose(f);
}

static int fp_known(const char *fp) {
    for (size_t i = 0; i < FP_REG_N; i++) {
        if (memcmp(FP_REG[i], fp, 10) == 0) return 1;
    }
    return 0;
}

static void scan_fingerprints(const char *s, size_t n, hits_t *hits) {
    fp_registry_load();
    if (FP_REG_N == 0) return;
    size_t i = 0;
    while (i < n) {
        if (!is_token_char((unsigned char)s[i])) { i++; continue; }
        size_t start = i;
        while (i < n && is_token_char((unsigned char)s[i])) i++;
        size_t len = i - start;
        if (len < FP_TOKEN_MIN || len > FP_TOKEN_MAX) continue;
        char fp[11];
        fp40(s + start, len, fp);
        if (fp_known(fp)) hits_add(hits, start, i, "known-secret");
    }
}

static void detect_content(const char *s, size_t n, hits_t *hits);

static int fingerprint_mode(int secrets_only) {
    buf_t in;
    buf_init(&in);
    if (!read_stream(stdin, &in) || in.len == 0) {
        buf_free(&in);
        return 0;
    }
    if (secrets_only) {
        hits_t hits;
        hits_init(&hits);
        detect_content(in.data, in.len, &hits);
        char seen[512][11];
        size_t seen_n = 0;
        for (size_t i = 0; i < hits.n; i++) {
            size_t start = hits.v[i].start;
            size_t end = hits.v[i].end;
            if (end <= start || end > in.len) continue;
            char fp[11];
            fp40(in.data + start, end - start, fp);
            int dup = 0;
            for (size_t k = 0; k < seen_n; k++) {
                if (memcmp(seen[k], fp, 10) == 0) { dup = 1; break; }
            }
            if (dup) continue;
            if (seen_n < 512) memcpy(seen[seen_n++], fp, 11);
            printf("%s\n", fp);
        }
        fflush(stdout);
        hits_free(&hits);
        buf_free(&in);
        return 0;
    }
    char seen[512][11];
    size_t seen_n = 0;
    size_t i = 0;
    while (i < in.len) {
        if (!is_token_char((unsigned char)in.data[i])) { i++; continue; }
        size_t start = i;
        while (i < in.len && is_token_char((unsigned char)in.data[i])) i++;
        size_t len = i - start;
        if (len < FP_TOKEN_MIN || len > FP_TOKEN_MAX) continue;
        char fp[11];
        fp40(in.data + start, len, fp);
        int dup = 0;
        for (size_t k = 0; k < seen_n; k++) {
            if (memcmp(seen[k], fp, 10) == 0) { dup = 1; break; }
        }
        if (dup) continue;
        if (seen_n < 512) memcpy(seen[seen_n++], fp, 11);
        printf("%s\n", fp);
    }
    fflush(stdout);
    buf_free(&in);
    return 0;
}

/* ------------------------------------------------------------------ */
/* content detection                                                  */
/* ------------------------------------------------------------------ */

static void detect_content(const char *s, size_t n, hits_t *hits) {
    if (n == 0) return;
    scan_private_keys(s, n, hits);
    scan_providers(s, n, hits);
    scan_jwt(s, n, hits);
    scan_bearer(s, n, hits);
    scan_url_creds(s, n, hits);
    scan_context(s, n, hits);
    scan_fingerprints(s, n, hits);
    hits_resolve(hits);
}

/* ------------------------------------------------------------------ */
/* redact mode                                                        */
/* ------------------------------------------------------------------ */

static int redact_mode(void) {
    buf_t in;
    buf_init(&in);
    if (!read_stream(stdin, &in)) {
        buf_free(&in);
        return 0;
    }
    if (in.len == 0) {
        buf_free(&in);
        return 0;
    }

    hits_t hits;
    hits_init(&hits);
    detect_content(in.data, in.len, &hits);

    buf_t out;
    buf_init(&out);
    size_t pos = 0;
    for (size_t i = 0; i < hits.n; i++) {
        if (hits.v[i].start > in.len || hits.v[i].end > in.len) continue;
        if (!buf_add(&out, in.data + pos, hits.v[i].start - pos)) break;
        if (!buf_add(&out, "[REDACTED:", 10)) break;
        if (!buf_add(&out, hits.v[i].label, strlen(hits.v[i].label))) break;
        if (!buf_addc(&out, ']')) break;
        pos = hits.v[i].end;
    }
    buf_add(&out, in.data + pos, in.len - pos);

    if (out.len > 0) fwrite(out.data, 1, out.len, stdout);
    fflush(stdout);

    hits_free(&hits);
    buf_free(&out);
    buf_free(&in);
    return 0;
}

/* ------------------------------------------------------------------ */
/* minimal JSON reader                                                */
/* ------------------------------------------------------------------ */

static const char *jskip_ws(const char *p, const char *e) {
    while (p < e && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
    return p;
}

static const char *jskip_string(const char *p, const char *e) {
    if (p >= e || *p != '"') return NULL;
    p++;
    while (p < e) {
        if (*p == '\\') {
            p += 2;
            continue;
        }
        if (*p == '"') return p + 1;
        p++;
    }
    return NULL;
}

static const char *jskip_value(const char *p, const char *e, int depth) {
    if (depth > 64) return NULL;
    p = jskip_ws(p, e);
    if (p >= e) return NULL;
    if (*p == '"') return jskip_string(p, e);
    if (*p == '{' || *p == '[') {
        char open = *p;
        char close = (open == '{') ? '}' : ']';
        int d = 0;
        while (p < e) {
            if (*p == '"') {
                const char *q = jskip_string(p, e);
                if (!q) return NULL;
                p = q;
                continue;
            }
            if (*p == open) d++;
            else if (*p == close) {
                d--;
                if (d == 0) return p + 1;
            }
            p++;
        }
        return NULL;
    }
    const char *start = p;
    while (p < e && !isspace((unsigned char)*p) && *p != ',' && *p != '}' && *p != ']') p++;
    return p > start ? p : NULL;
}

static int jget_string(const char *p, const char *e, buf_t *out) {
    if (p >= e || *p != '"') return 0;
    p++;
    while (p < e) {
        char c = *p;
        if (c == '"') return buf_terminate(out);
        if (c == '\\' && p + 1 < e) {
            p++;
            switch (*p) {
                case 'n': if (!buf_addc(out, '\n')) return 0; break;
                case 't': if (!buf_addc(out, '\t')) return 0; break;
                case 'r': if (!buf_addc(out, '\r')) return 0; break;
                case 'b': if (!buf_addc(out, '\b')) return 0; break;
                case 'f': if (!buf_addc(out, '\f')) return 0; break;
                case 'u': {
                    int ok = p + 4 < e;
                    unsigned v = 0;
                    for (int k = 1; ok && k <= 4; k++) {
                        int h = hexval((unsigned char)p[k]);
                        if (h < 0) ok = 0;
                        else v = v * 16 + (unsigned)h;
                    }
                    if (ok) {
                        if (!buf_addc(out, v < 0x80 ? (char)v : '?')) return 0;
                        p += 4;
                    }
                    break;
                }
                default: if (!buf_addc(out, *p)) return 0; break;
            }
            p++;
            continue;
        }
        if (!buf_addc(out, c)) return 0;
        p++;
    }
    return 0;
}

/* Return the start of the value of `want` in the object at obj, or NULL. */
static const char *find_member(const char *obj, const char *e, const char *want) {
    if (obj >= e || *obj != '{') return NULL;
    size_t wl = strlen(want);
    const char *p = obj + 1;
    while (p < e) {
        p = jskip_ws(p, e);
        if (p >= e || *p == '}') return NULL;
        if (*p == ',') {
            p++;
            continue;
        }
        if (*p != '"') return NULL;
        const char *key = p + 1;
        const char *after = jskip_string(p, e);
        if (!after) return NULL;
        size_t klen = (size_t)(after - 1 - key);
        p = jskip_ws(after, e);
        if (p >= e || *p != ':') return NULL;
        p = jskip_ws(p + 1, e);
        if (klen == wl && memcmp(key, want, wl) == 0) return p;
        p = jskip_value(p, e, 0);
        if (!p) return NULL;
    }
    return NULL;
}

typedef void (*kv_cb)(void *ctx, const char *key, size_t klen, const char *val, size_t vlen);

static void walk_value(const char *v, const char *e, const char *key, size_t klen, kv_cb cb,
                       void *ctx, buf_t *scratch, int depth);

static void walk_members(const char *v, const char *e, kv_cb cb, void *ctx, buf_t *scratch,
                         int depth) {
    const char *p = v + 1;
    while (p < e) {
        p = jskip_ws(p, e);
        if (p >= e || *p == '}') return;
        if (*p == ',') {
            p++;
            continue;
        }
        if (*p != '"') return;
        const char *key = p + 1;
        const char *after = jskip_string(p, e);
        if (!after) return;
        size_t klen = (size_t)(after - 1 - key);
        p = jskip_ws(after, e);
        if (p >= e || *p != ':') return;
        p = jskip_ws(p + 1, e);
        walk_value(p, e, key, klen, cb, ctx, scratch, depth + 1);
        p = jskip_value(p, e, depth + 1);
        if (!p) return;
    }
}

static void walk_value(const char *v, const char *e, const char *key, size_t klen, kv_cb cb,
                       void *ctx, buf_t *scratch, int depth) {
    if (depth > 32) return;
    v = jskip_ws(v, e);
    if (v >= e) return;
    if (*v == '{') {
        walk_members(v, e, cb, ctx, scratch, depth);
        return;
    }
    if (*v == '[') {
        const char *p = v + 1;
        while (p < e) {
            p = jskip_ws(p, e);
            if (p >= e || *p == ']') return;
            if (*p == ',') {
                p++;
                continue;
            }
            walk_value(p, e, key, klen, cb, ctx, scratch, depth + 1);
            p = jskip_value(p, e, depth + 1);
            if (!p) return;
        }
        return;
    }
    if (*v == '"') {
        scratch->len = 0;
        if (!jget_string(v, e, scratch)) return;
        if (scratch->len > 0) cb(ctx, key, klen, scratch->data, scratch->len);
    }
}

/* ------------------------------------------------------------------ */
/* path rules                                                         */
/* ------------------------------------------------------------------ */

static int ends_with(const char *s, const char *suffix) {
    size_t n = strlen(s);
    size_t m = strlen(suffix);
    return n >= m && memcmp(s + n - m, suffix, m) == 0;
}

static const char *HOME_FRAGMENTS[] = {
    ".ssh/",           ".aws/",
    ".gnupg/",         ".kube/",
    ".docker/config.json", ".config/gh/",
    ".kimi-code/credentials/", ".kimi-code/config.toml",
    ".kimi-code/server.token", ".codex/auth.json",
    ".cargo/credentials", ".m2/settings.xml",
    NULL,
};

static const char *CRED_BASENAMES[] = {
    ".npmrc",          ".netrc",
    "_netrc",          ".pypirc",
    ".git-credentials", ".htpasswd",
    "id_rsa",          "id_dsa",
    "id_ecdsa",        "id_ed25519",
    "server.token",    "auth.json",
    "application_default_credentials.json",
    "credentials.json", "credentials.yaml",
    "credentials.yml",  "credentials.toml",
    "credentials.ini",  "secrets.json",
    "secrets.yaml",     "secrets.yml",
    "secrets.toml",
    NULL,
};

static const char *CRED_EXTENSIONS[] = {
    ".pem", ".p12", ".pfx", ".jks", ".keystore", ".kdbx", ".kdb", ".ppk", ".asc", ".gpg", ".ovpn",
    NULL,
};

static int env_family(const char *base) {
    if (strcmp(base, ".env") == 0) return 1;
    if (strncmp(base, ".env.", 5) != 0) return 0;
    const char *rest = base + 5;
    if (strcmp(rest, "example") == 0 || strcmp(rest, "sample") == 0 ||
        strcmp(rest, "template") == 0 || strcmp(rest, "dist") == 0) {
        return 0;
    }
    return 1;
}

static int path_is_credential(const char *val, size_t len) {
    char p[1024];
    char low[1024];
    size_t n = len;
    if (n == 0) return 0;
    if (n > sizeof p - 1) {
        val += n - (sizeof p - 1);
        n = sizeof p - 1;
    }

    size_t s = 0;
    while (s < n) {
        char c = val[s];
        if (c == ' ' || c == '\t' || c == '"' || c == '\'' || c == '`' || c == '\n' ||
            c == '\r') {
            s++;
            continue;
        }
        break;
    }
    size_t t = n;
    while (t > s) {
        char c = val[t - 1];
        if (c == ' ' || c == '\t' || c == '"' || c == '\'' || c == '`' || c == '\n' ||
            c == '\r' || c == ',' || c == ';' || c == ')') {
            t--;
            continue;
        }
        break;
    }
    if (t <= s) return 0;
    n = t - s;
    memcpy(p, val + s, n);
    p[n] = '\0';
    for (size_t i = 0; i < n; i++) low[i] = (char)tolower((unsigned char)p[i]);
    low[n] = '\0';

    for (int i = 0; HOME_FRAGMENTS[i]; i++) {
        const char *frag = HOME_FRAGMENTS[i];
        if (strstr(low, frag) != NULL) return 1;
        size_t fl = strlen(frag);
        if (frag[fl - 1] != '/') continue;
        size_t touch = fl - 1;
        if (n == touch && memcmp(low, frag, touch) == 0) return 1;
        if (n > touch && low[n - touch - 1] == '/' && memcmp(low + n - touch, frag, touch) == 0) {
            return 1;
        }
    }

    const char *base = strrchr(low, '/');
    base = base ? base + 1 : low;

    if (env_family(base)) return 1;
    for (int i = 0; CRED_BASENAMES[i]; i++) {
        if (strcmp(base, CRED_BASENAMES[i]) == 0) return 1;
    }
    if (strncmp(base, "service-account", 15) == 0 && ends_with(base, ".json")) return 1;
    for (int i = 0; CRED_EXTENSIONS[i]; i++) {
        if (ends_with(base, CRED_EXTENSIONS[i])) return 1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* shell command inspection                                           */
/* ------------------------------------------------------------------ */

static const char *READER_VERBS[] = {
    "cat", "head", "tail", "less", "more", "bat", "source", "strings",
    "xxd", "od", "base64", "cp", "scp", "rsync", "tar", "zip",
    "curl", "wget", NULL,
};

static const char *SEARCH_VERBS[] = {
    "grep", "rg", "ag", "ack", "sed", "awk", "find", "cut", "jq", NULL,
};

static int in_list(const char *word, const char *const *list) {
    for (int i = 0; list[i]; i++) {
        if (strcmp(word, list[i]) == 0) return 1;
    }
    return 0;
}

static int file_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0;
}

static int command_reads_credential(const char *cmd, size_t len) {
    char buf[8192];
    char store[8192];
    char *tokens[MAX_TOKENS];
    size_t nt = 0;
    size_t n = len < sizeof buf - 1 ? len : sizeof buf - 1;

    if (len == 0) return 0;
    memcpy(buf, cmd, n);
    buf[n] = '\0';

    const char *pipe = strchr(buf, '|');
    if (pipe && (strstr(pipe, "redact") != NULL || strstr(pipe, "fingerprint") != NULL)) return 0;

    const char *p = buf;
    size_t sp = 0;
    while (*p && nt < MAX_TOKENS) {
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
        if (!*p) break;
        size_t start = sp;
        char quote = 0;
        if (*p == '\'' || *p == '"') {
            quote = *p;
            p++;
        }
        while (*p) {
            if (quote) {
                if (*p == quote) {
                    p++;
                    break;
                }
                if (sp < sizeof store - 1) store[sp++] = *p;
                p++;
                continue;
            }
            if (*p == '\'' || *p == '"') {
                quote = *p;
                p++;
                continue;
            }
            if (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') break;
            if (*p == '\\' && p[1]) p++;
            if (sp < sizeof store - 1) store[sp++] = *p;
            p++;
        }
        if (sp == start) continue;
        store[sp++] = '\0';
        tokens[nt++] = store + start;
    }
    if (nt == 0) return 0;

    for (size_t i = 0; i < nt; i++) {
        const char *t = tokens[i];
        if (strcmp(t, "-c") == 0 || strcmp(t, "--count") == 0 || strcmp(t, "-l") == 0 ||
            strcmp(t, "--files-with-matches") == 0 || strcmp(t, "-q") == 0 ||
            strcmp(t, "--quiet") == 0 || strcmp(t, "--silent") == 0) {
            return 0;
        }
    }

    int reader = 0;
    int search = 0;
    for (size_t i = 0; i < nt; i++) {
        const char *base = tokens[i];
        const char *slash = strrchr(base, '/');
        if (slash) base = slash + 1;
        if (in_list(base, READER_VERBS)) reader = 1;
        if (in_list(base, SEARCH_VERBS)) search = 1;
    }
    if (!reader && !search) return 0;

    for (size_t i = 0; i < nt; i++) {
        const char *t = tokens[i];
        if (t[0] == '-') continue;
        const char *base = t;
        const char *slash = strrchr(base, '/');
        if (slash) base = slash + 1;
        if (in_list(base, READER_VERBS) || in_list(base, SEARCH_VERBS)) continue;
        if (strcmp(t, ">") == 0 || strcmp(t, ">>") == 0 || strcmp(t, "<") == 0 ||
            strcmp(t, "|") == 0) {
            continue;
        }
        if (reader) {
            if (path_is_credential(t, strlen(t))) return 1;
            continue;
        }
        int candidate = strchr(t, '/') != NULL || t[0] == '~' || file_exists(t);
        if (candidate && path_is_credential(t, strlen(t))) return 1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* hook mode                                                          */
/* ------------------------------------------------------------------ */

static const char *PATH_FIELDS[] = {
    "path", "file_path", "filePath", "paths", "file", "glob",
    "file_pattern", "path_filter", "directory", "dir", "root",
    "repo_path", "source", "cwd", NULL,
};

static int key_matches(const char *k, size_t klen, const char *want) {
    size_t wl = strlen(want);
    return klen == wl && strncasecmp(k, want, wl) == 0;
}

static int key_is_path_field(const char *k, size_t klen) {
    for (int i = 0; PATH_FIELDS[i]; i++) {
        if (key_matches(k, klen, PATH_FIELDS[i])) return 1;
    }
    return 0;
}

static int key_is_command(const char *k, size_t klen) {
    return key_matches(k, klen, "command") || key_matches(k, klen, "cmd") ||
           key_matches(k, klen, "script");
}

static void lower_copy(const char *src, size_t len, char *out, size_t cap) {
    size_t n = len < cap - 1 ? len : cap - 1;
    for (size_t i = 0; i < n; i++) out[i] = (char)tolower((unsigned char)src[i]);
    out[n] = '\0';
}

static int tool_reads_content(const char *name) {
    static const char *const needles[] = {
        "bash", "shell", "exec", "read", "cat", "grep", "search_code",
        "get_code_snippet", "index", "open", "preview", "notebook", NULL,
    };
    char low[256];
    lower_copy(name, strlen(name), low, sizeof low);
    for (int i = 0; needles[i]; i++) {
        if (strstr(low, needles[i]) != NULL) return 1;
    }
    return 0;
}

static int tool_is_shell(const char *name) {
    char low[256];
    lower_copy(name, strlen(name), low, sizeof low);
    return strstr(low, "bash") != NULL || strstr(low, "shell") != NULL ||
           strstr(low, "exec") != NULL;
}

typedef struct {
    int shell_tool;
    size_t seen;
    hits_t *hits;
} walk_ctx;

static void inspect_cb(void *vctx, const char *key, size_t klen, const char *val, size_t vlen) {
    walk_ctx *ctx = vctx;
    if (ctx->seen++ > 2048) return;
    if (key_is_path_field(key, klen)) {
        if (path_is_credential(val, vlen)) hits_add(ctx->hits, 0, 0, "credential-path");
        return;
    }
    if (ctx->shell_tool && key_is_command(key, klen)) {
        if (command_reads_credential(val, vlen)) hits_add(ctx->hits, 0, 0, "credential-path");
    }
}

static int payload_tool_name(const char *obj, const char *end, char *out, size_t cap) {
    static const char *const keys[] = {"tool_name", "tool", "name", NULL};
    out[0] = '\0';
    for (int i = 0; keys[i]; i++) {
        const char *v = find_member(obj, end, keys[i]);
        if (!v) continue;
        buf_t b;
        buf_init(&b);
        if (jget_string(v, end, &b) && b.len > 0) {
            size_t c = b.len < cap - 1 ? b.len : cap - 1;
            memcpy(out, b.data, c);
            out[c] = '\0';
            buf_free(&b);
            return 1;
        }
        buf_free(&b);
    }
    return 0;
}

/* Walk every string inside the arguments object, including a JSON-encoded one. */
static void inspect_arguments(const char *v, const char *end, walk_ctx *ctx) {
    buf_t scratch;
    buf_init(&scratch);
    walk_value(v, end, NULL, 0, inspect_cb, ctx, &scratch, 0);
    buf_free(&scratch);
}

static void ensure_dir(const char *path) {
    struct stat st;
    if (stat(path, &st) == 0) return;
    if (sg_mkdir(path) == 0) return;
    if (errno != ENOENT) return;
    char parent[1024];
    snprintf(parent, sizeof parent, "%s", path);
    char *slash = strrchr(parent, '/');
    if (slash && slash != parent) {
        *slash = '\0';
        if (sg_mkdir(parent) != 0) {
            /* keep going: fopen below simply fails and logging is best effort */
        }
    }
    if (sg_mkdir(path) != 0) {
        /* best effort */
    }
}

static void log_block(const char *rule, const char *tool) {
    const char *base = getenv("KIMI_CODE_HOME");
    char dir[1024];
    if (base && *base) {
        snprintf(dir, sizeof dir, "%s/logs", base);
    } else {
        const char *home = getenv("HOME");
        if (!home || !*home) return;
        snprintf(dir, sizeof dir, "%s/.kimi-code/logs", home);
    }
    ensure_dir(dir);

    char path[1200];
    snprintf(path, sizeof path, "%s/secret-guard.log", dir);
    FILE *f = fopen(path, "a");
    if (!f) return;

    char clean[64];
    size_t c = 0;
    for (const char *p = tool; *p && c + 1 < sizeof clean; p++) {
        clean[c++] = (unsigned char)*p < 0x20 ? '_' : *p;
    }
    clean[c] = '\0';

    fprintf(f, "BLOCK %s tool=%s\n", rule, c > 0 ? clean : "unknown");
    fclose(f);
}

static int emit_deny(const char *rule, const char *tool) {
    char reason[320];
    if (strcmp(rule, "credential-path") == 0) {
        snprintf(reason, sizeof reason,
                 "Blocked: credential or private-key path. Do not read .env, key, or "
                 "secret-store files; pipe the content through secret_guard redact if a "
                 "value must be inspected.");
    } else if (strcmp(rule, "known-secret") == 0) {
        snprintf(reason, sizeof reason,
                 "Blocked: this value matches a fingerprint in your secret registry, so it "
                 "has already leaked once. Rotate it, keep the plaintext out of tool calls, "
                 "and pipe text through secret_guard redact if you must inspect it.");
    } else {
        snprintf(reason, sizeof reason,
                 "Blocked: tool input contains a value that looks like a %s. Remove the "
                 "secret, or pipe it through secret_guard redact first.",
                 rule);
    }
    printf("{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\","
           "\"permissionDecisionReason\":\"%s\"}}\n",
           reason);
    fflush(stdout);
    fprintf(stderr, "secret-guard: blocked %s (tool=%s)\n", rule,
            tool[0] ? tool : "unknown");
    log_block(rule, tool);
    return 2;
}

static int hook_mode(void) {
    buf_t in;
    buf_init(&in);
    if (!read_stream(stdin, &in)) {
        buf_free(&in);
        return 0;
    }
    if (in.len == 0) {
        buf_free(&in);
        return 0;
    }

    const char *end = in.data + in.len;
    const char *root = memchr(in.data, '{', in.len);
    if (!root) {
        buf_free(&in);
        return 0;
    }

    char tool[128];
    int have_tool = payload_tool_name(root, end, tool, sizeof tool);
    if (!have_tool) tool[0] = '\0';

    hits_t hits;
    hits_init(&hits);
    detect_content(in.data, in.len, &hits);

    const char *rule = hits.n > 0 ? hits.v[0].label : NULL;

    if (!rule && have_tool && tool_reads_content(tool)) {
        static const char *const arg_keys[] = {"tool_input", "input", "parameters", "args", NULL};
        hits_t paths;
        hits_init(&paths);
        walk_ctx ctx;
        ctx.shell_tool = tool_is_shell(tool);
        ctx.seen = 0;
        ctx.hits = &paths;

        for (int i = 0; arg_keys[i] && paths.n == 0; i++) {
            const char *v = find_member(root, end, arg_keys[i]);
            if (!v) continue;
            if (*v == '{' || *v == '[') {
                inspect_arguments(v, end, &ctx);
            } else if (*v == '"') {
                buf_t raw;
                buf_init(&raw);
                if (jget_string(v, end, &raw) && raw.len > 2 && raw.data[0] == '{') {
                    inspect_arguments(raw.data, raw.data + raw.len, &ctx);
                }
                buf_free(&raw);
            }
        }

        if (paths.n > 0) rule = "credential-path";
        hits_free(&paths);
    }

    hits_free(&hits);
    buf_free(&in);

    if (rule) return emit_deny(rule, tool);
    return 0;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "redact") == 0) return redact_mode();
    if (argc > 1 && strcmp(argv[1], "fingerprint") == 0) {
        return fingerprint_mode(argc > 2 && strcmp(argv[2], "--secrets") == 0);
    }
    return hook_mode();
}
