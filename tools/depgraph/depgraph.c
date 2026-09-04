/* depgraph: generic dependency-graph operations over Registry package names.
 *
 * Knows nothing about Registry, TOML, or any distro's packaging tools —
 * it's the one piece of workflow-build-kit's graph logic (connected
 * components / cycle-tolerant topological order / Kahn's-algorithm
 * layering) that's genuinely awkward to get right in bash: it needs real
 * recursion and backtracking over sets, and bash has no real call stack for
 * that (only global associative arrays threaded through "recursive"
 * function calls, a known source of aliasing bugs for exactly this kind of
 * logic). Everything else in workflow-build-kit is bash+jq on purpose; this
 * is the one intentional exception. Semantics are a direct C port of the
 * three graph functions in the old scripts/registry/aur_graph.py
 * (connected_components / topo_order / layered_order).
 *
 * Input (stdin): one line per known package, `name<TAB>dep1,dep2,dep3`
 * (deps comma-separated, field may be empty/absent for a package with no
 * tracked dependencies). Dependency names are expected to already be
 * restricted by the caller to names that are themselves tracked packages —
 * same restriction aur_graph.py's build_graph applies before handing a
 * graph to any of these algorithms.
 *
 * Usage:
 *   depgraph components --subset <file>
 *   depgraph toposort   --subset <file>
 *   depgraph layers      --subset <file> --max-layers N
 *
 * --subset <file>: newline-separated package names the operation applies
 * to (a connected component, or "everything currently changed", etc).
 * Omit to operate over every name seen on stdin.
 */
#define _POSIX_C_SOURCE 200809L /* strdup, strtok_r — POSIX, not plain C11 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_NODES 2048
#define MAX_LINE 8192

static char *g_names[MAX_NODES];
static int g_count = 0;
static unsigned char g_adj[MAX_NODES][MAX_NODES]; /* g_adj[i][j] = i depends on j */

static void die(const char *msg) {
    fprintf(stderr, "depgraph: %s\n", msg);
    exit(1);
}

static char *xstrdup(const char *s) {
    char *d = strdup(s);
    if (!d) die("out of memory");
    return d;
}

static int intern(const char *name) {
    for (int i = 0; i < g_count; i++)
        if (strcmp(g_names[i], name) == 0) return i;
    if (g_count >= MAX_NODES) die("too many nodes (increase MAX_NODES)");
    g_names[g_count] = xstrdup(name);
    return g_count++;
}

static char *trim(char *s) {
    size_t n = strlen(s);
    while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == '\r')) s[--n] = '\0';
    return s;
}

/* Reads the full graph from stdin into g_names/g_adj. */
static void read_graph(void) {
    char line[MAX_LINE];
    while (fgets(line, sizeof line, stdin)) {
        trim(line);
        if (line[0] == '\0') continue;

        char *tab = strchr(line, '\t');
        char *deps = NULL;
        if (tab) {
            *tab = '\0';
            deps = tab + 1;
        }
        int id = intern(line);

        if (deps && *deps) {
            char *saveptr = NULL;
            char *tok = strtok_r(deps, ",", &saveptr);
            while (tok) {
                int dep_id = intern(tok);
                g_adj[id][dep_id] = 1;
                tok = strtok_r(NULL, ",", &saveptr);
            }
        }
    }
}

/* Reads a subset file (newline-separated names) into an id array, sorted
 * alphabetically by name (mirrors aur_graph.py's `sorted(names)`). Any name
 * not already known from stdin is interned fresh (an isolated node with no
 * declared deps of its own) rather than rejected. */
static int cmp_id_by_name(const void *a, const void *b) {
    int ia = *(const int *)a, ib = *(const int *)b;
    return strcmp(g_names[ia], g_names[ib]);
}

static int read_subset(const char *path, int **out_ids) {
    FILE *f = path ? fopen(path, "r") : NULL;
    int *ids = malloc(sizeof(int) * MAX_NODES);
    if (!ids) die("out of memory");
    int n = 0;

    if (!path) {
        for (int i = 0; i < g_count; i++) ids[n++] = i;
    } else {
        if (!f) die("cannot open --subset file");
        char line[MAX_LINE];
        while (fgets(line, sizeof line, f)) {
            trim(line);
            if (line[0] == '\0') continue;
            if (n >= MAX_NODES) die("too many nodes in --subset (increase MAX_NODES)");
            ids[n++] = intern(line);
        }
        fclose(f);
    }

    qsort(ids, n, sizeof(int), cmp_id_by_name);
    *out_ids = ids;
    return n;
}

/* ---- components ---- */
static void cmd_components(const int *subset, int subset_n) {
    unsigned char *visited = calloc((size_t)g_count, 1);
    int *stack = malloc(sizeof(int) * (size_t)subset_n);
    int *component = malloc(sizeof(int) * (size_t)subset_n);
    if (!visited || !stack || !component) die("out of memory");

    for (int s = 0; s < subset_n; s++) {
        int start = subset[s];
        if (visited[start]) continue;

        /* visited[] is set at push time (not pop time) so every subset
         * member is pushed at most once — bounds the stack to subset_n. */
        int sp = 0, cn = 0;
        stack[sp++] = start;
        visited[start] = 1;
        while (sp > 0) {
            int n = stack[--sp];
            component[cn++] = n;
            for (int j = 0; j < subset_n; j++) {
                int m = subset[j];
                if (visited[m]) continue;
                if (g_adj[n][m] || g_adj[m][n]) {
                    visited[m] = 1;
                    stack[sp++] = m;
                }
            }
        }

        qsort(component, cn, sizeof(int), cmp_id_by_name);
        for (int i = 0; i < cn; i++) {
            fputs(g_names[component[i]], stdout);
            if (i + 1 < cn) fputc(' ', stdout);
        }
        fputc('\n', stdout);
    }

    free(visited);
    free(stack);
    free(component);
}

/* ---- toposort ---- */
static const int *g_topo_subset;
static int g_topo_subset_n;
static int *g_topo_visited; /* 0=unvisited 1=in_progress 2=done */
static int *g_topo_order;
static int g_topo_order_n;

static void topo_visit(int n) {
    if (g_topo_visited[n] == 2 || g_topo_visited[n] == 1) return;
    g_topo_visited[n] = 1;

    /* deps of n, restricted to subset, visited in sorted-name order */
    int deps[MAX_NODES], dn = 0;
    for (int j = 0; j < g_topo_subset_n; j++) {
        int m = g_topo_subset[j];
        if (g_adj[n][m]) deps[dn++] = m;
    }
    qsort(deps, dn, sizeof(int), cmp_id_by_name);
    for (int i = 0; i < dn; i++) topo_visit(deps[i]);

    g_topo_visited[n] = 2;
    g_topo_order[g_topo_order_n++] = n;
}

static void cmd_toposort(const int *subset, int subset_n) {
    g_topo_subset = subset;
    g_topo_subset_n = subset_n;
    g_topo_visited = calloc((size_t)g_count, sizeof(int));
    g_topo_order = malloc(sizeof(int) * (size_t)subset_n);
    g_topo_order_n = 0;
    if (!g_topo_visited || !g_topo_order) die("out of memory");

    for (int i = 0; i < subset_n; i++) topo_visit(subset[i]);

    for (int i = 0; i < g_topo_order_n; i++)
        printf("%s\n", g_names[g_topo_order[i]]);

    free(g_topo_visited);
    free(g_topo_order);
}

/* ---- layers ---- */
/* Computes every layer before printing anything: resolve_build_order.py's
 * caller only ever sees complete JSON on success or a bare stderr message
 * on failure, never a truncated array — match that exactly rather than
 * streaming partial JSON that then aborts mid-object. */
static void cmd_layers(const int *subset, int subset_n, int max_layers) {
    unsigned char *remaining = calloc((size_t)g_count, 1);
    unsigned char *placed = calloc((size_t)g_count, 1);
    int *layer = malloc(sizeof(int) * (size_t)subset_n);
    int **layers_buf = malloc(sizeof(int *) * (size_t)(max_layers > 0 ? max_layers : 1));
    int *layers_len = malloc(sizeof(int) * (size_t)(max_layers > 0 ? max_layers : 1));
    if (!remaining || !placed || !layer || !layers_buf || !layers_len) die("out of memory");

    for (int i = 0; i < subset_n; i++) remaining[subset[i]] = 1;
    int remaining_count = subset_n;
    int layer_idx = 0;

    while (remaining_count > 0) {
        if (layer_idx >= max_layers) {
            fprintf(stderr, "depgraph: dependency graph needs more than %d build layers "
                             "(likely a cycle, or a chain deeper than expected)\n", max_layers);
            exit(1);
        }

        int ln = 0;
        for (int i = 0; i < subset_n; i++) {
            int n = subset[i];
            if (!remaining[n]) continue;
            int ready = 1;
            for (int j = 0; j < subset_n; j++) {
                int m = subset[j];
                if (g_adj[n][m] && remaining[m] && !placed[m]) { ready = 0; break; }
            }
            if (ready) layer[ln++] = n;
        }
        if (ln == 0) {
            fprintf(stderr, "depgraph: cannot make progress ordering the remaining packages "
                             "— dependency cycle among tracked packages\n");
            exit(1);
        }
        qsort(layer, ln, sizeof(int), cmp_id_by_name);

        layers_buf[layer_idx] = malloc(sizeof(int) * (size_t)ln);
        if (!layers_buf[layer_idx]) die("out of memory");
        memcpy(layers_buf[layer_idx], layer, sizeof(int) * (size_t)ln);
        layers_len[layer_idx] = ln;

        for (int i = 0; i < ln; i++) {
            placed[layer[i]] = 1;
            remaining[layer[i]] = 0;
            remaining_count--;
        }
        layer_idx++;
    }

    printf("[");
    for (int li = 0; li < layer_idx; li++) {
        printf("%s[", li ? "," : "");
        for (int i = 0; i < layers_len[li]; i++)
            printf("%s\"%s\"", i ? "," : "", g_names[layers_buf[li][i]]);
        printf("]");
        free(layers_buf[li]);
    }
    printf("]\n");

    free(remaining);
    free(placed);
    free(layer);
    free(layers_buf);
    free(layers_len);
}

int main(int argc, char **argv) {
    if (argc < 2) die("usage: depgraph <components|toposort|layers> [--subset FILE] [--max-layers N]");

    const char *cmd = argv[1];
    const char *subset_path = NULL;
    int max_layers = 5;

    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--subset") == 0 && i + 1 < argc) {
            subset_path = argv[++i];
        } else if (strcmp(argv[i], "--max-layers") == 0 && i + 1 < argc) {
            max_layers = atoi(argv[++i]);
        } else {
            die("unrecognized argument");
        }
    }

    read_graph();

    int *subset;
    int subset_n = read_subset(subset_path, &subset);

    if (strcmp(cmd, "components") == 0) {
        cmd_components(subset, subset_n);
    } else if (strcmp(cmd, "toposort") == 0) {
        cmd_toposort(subset, subset_n);
    } else if (strcmp(cmd, "layers") == 0) {
        cmd_layers(subset, subset_n, max_layers);
    } else {
        die("unknown command (expected components, toposort, or layers)");
    }

    return 0;
}
