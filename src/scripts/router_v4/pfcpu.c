// pfcpu.c : CPU twin of pfgpu.cu. One net per OpenMP thread; each net joins its groups with a heap Dijkstra on its window.
// build: gcc -O3 -fopenmp -shared -fPIC -o pfcpu.so pfcpu.c
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <omp.h>
#include "pfcommon.h"
typedef struct { float f; int w; } HE;
typedef struct { HE *h; int n, cap; } Heap;
static void hpush(Heap *H, float f, int w) {
    if (H->n == H->cap) { H->cap = H->cap ? H->cap * 2 : 1 << 16; H->h = realloc(H->h, H->cap * sizeof(HE)); }
    int i = H->n++;
    while (i) { int p = (i - 1) / 2; if (H->h[p].f <= f) break; H->h[i] = H->h[p]; i = p; }
    H->h[i].f = f; H->h[i].w = w;
}
static HE hpop(Heap *H) {
    HE top = H->h[0]; HE last = H->h[--H->n]; int i = 0;
    for (;;) { int a = 2 * i + 1, b = a + 1, m = i; float fm = last.f;
        if (a < H->n && H->h[a].f < fm) { m = a; fm = H->h[a].f; }
        if (b < H->n && H->h[b].f < fm) { m = b; }
        if (m == i) break; H->h[i] = H->h[m]; i = m; }
    H->h[i] = last; return top;
}
/* per net arrays: dist float[W2], prev int[W2], gid short[W2], state u8[W2]; path int[pcap]; plen, status per net */
static void route_one(const Maps *m, const NetJob *j, float *dist, int *prev, const short *gid, unsigned char *state,
                      int *path, int *plen, int *status, unsigned char *closed)
{
    const int nx = m->nx; const long long N = (long long)nx * m->ny;
    const int ww = j->ww, wh = j->wh; const long long WC = (long long)ww * wh, W2 = 2 * WC;
    int remaining = j->ngroups, pl = 0; *status = 0; Heap H = {0, 0, 0};
    while (remaining > 1) {
        for (long long w = 0; w < W2; w++) { dist[w] = INFINITY; prev[w] = -1; closed[w] = 0; }
        H.n = 0;
        for (long long w = 0; w < W2; w++) if (state[w] & 1) {
            int l = (int)(w / WC); long long wc = w - l * WC; int y = (int)(wc / ww) + j->wy0, x = (int)(wc % ww) + j->wx0;
            long long c = (long long)y * nx + x, s = l * N + c;
            if (!blocked_t(m, j, s, c)) { dist[w] = 0; hpush(&H, 0, (int)w); }
        }
        int goal = -1; long long expanded = 0;
        while (H.n) {
            HE e = hpop(&H); int w = e.w;
            if (closed[w]) continue; closed[w] = 1; expanded++;
            if (gid[w] > 0 && !(state[w] & 1)) { goal = w; break; }
            float d = dist[w];
            int l = (int)(w / WC); long long wc = w - l * WC; int wy = (int)(wc / ww), wx = (int)(wc % ww);
            int y = wy + j->wy0, x = wx + j->wx0; long long c = (long long)y * nx + x;
            float cv = l == 0 ? j->against : 1.0f, ch = l == 0 ? 1.0f : j->against;
            int pdy = 0, pdx = 0, pw = prev[w];
            if (pw >= 0 && (pw / WC) == l) { long long pc = pw - l * WC; pdy = wy - (int)(pc / ww); pdx = wx - (int)(pc % ww); }
            for (int k = 0; k < 5; k++) {
                int dy = 0, dx = 0, nl = l; float nd;
                if (k == 0) dy = 1; else if (k == 1) dy = -1; else if (k == 2) dx = 1; else if (k == 3) dx = -1; else nl = 1 - l;
                int jy = wy + dy, jx = wx + dx;
                if (jy < 0 || jy >= wh || jx < 0 || jx >= ww) continue;
                long long jc = (long long)(jy + j->wy0) * nx + (jx + j->wx0), js = nl * N + jc; long long jw = nl * WC + (long long)jy * ww + jx;
                if (closed[jw]) continue;
                if (k < 4) {
                    if (blocked_t(m, j, js, jc)) continue;
                    if (dx && (m->field[c] || m->field[jc])) continue;
                    nd = d + (dx ? ch : cv) * cell_cost(m, j, js, jc, state[jw]);
                    if ((pdy || pdx) && (pdy != dy || pdx != dx)) nd += j->bend;
                } else {
                    if (blocked_v(m, j, c) || blocked_t(m, j, js, jc)) continue;
                    nd = d + via_cost(m, j, c);
                }
                if (nd < dist[jw]) { dist[jw] = nd; prev[jw] = w; hpush(&H, nd, (int)jw); }
            }
        }
        if (goal < 0) { *status = 1; break; }
        int hg = gid[goal]; int w = goal; int ok = 1;
        while (w >= 0) {
            int l = (int)(w / WC); long long wc = w - l * WC; int y = (int)(wc / ww) + j->wy0, x = (int)(wc % ww) + j->wx0;
            if (pl + 4 > j->pcap) { ok = 0; break; }
            path[pl++] = l; path[pl++] = y; path[pl++] = x; state[w] |= 1;
            if (dist[w] == 0) break;
            w = prev[w];
        }
        if (!ok) { *status = 2; break; }
        int ps = pl; path[pl++] = -1; remaining--;
        for (long long q = 0; q < W2; q++) if (gid[q] == hg) state[q] |= 1;
        // ring around the new path
        int pe = ps; int p0 = pe - 1; while (p0 >= 0 && path[p0] != -1) p0--; p0++;
        for (int pi = p0; pi < pe; pi += 3) {
            int l = path[pi], y = path[pi + 1], x = path[pi + 2];
            for (int dy = -3; dy <= 3; dy++) for (int dx = -3; dx <= 3; dx++) {
                int yy = y + dy - j->wy0, xx = x + dx - j->wx0;
                if (yy < 0 || yy >= wh || xx < 0 || xx >= ww) continue;
                long long q = l * WC + (long long)yy * ww + xx;
                if (!(state[q] & 1)) state[q] |= 2;
            }
        }
    }
    *plen = pl; free(H.h);
}
int route_nets_cpu(const Maps *m, const NetJob *jobs, int njobs, short *gid, unsigned char *state, int *path, int *plen, int *status, int nthreads)
{
    if (nthreads > 0) omp_set_num_threads(nthreads);
    #pragma omp parallel for schedule(dynamic, 1)
    for (int i = 0; i < njobs; i++) {
        const NetJob *j = &jobs[i]; long long W2 = 2LL * j->ww * j->wh;
        float *dist = malloc(W2 * sizeof(float)); int *prev = malloc(W2 * sizeof(int)); unsigned char *closed = malloc(W2);
        route_one(m, j, dist, prev, gid + j->off, state + j->off, path + j->poff, plen + i, status + i, closed);
        free(dist); free(prev); free(closed);
    }
    return 0;
}
