// pfgpu.cu : CUDA kernel, one thread block per net: joins the net's groups one by one with a parallel
// frontier shortest-path search (SPFA with Dijkstra-style termination) on the net's window. Built by cupy.RawModule.
#define DEVFN __device__ __forceinline__
#include "pfcommon.h"
#define QN_OFF 0
struct Work {              // per-net scratch (all sized 2*ww*wh unless noted)
    unsigned long long *dp;  // (dist bits << 32) | prev   (prev = window state index, 0xffffffff = none)
    short *gid; unsigned char *state; int *inq; short *ownocc; short *ownv;
    int *q0, *q1;            // queues (window state indices)
    int *path; int *plen; int *status;   // per net: path ints, length, status (0 ok, 1 fail, 2 path buffer full, 3 sweeps)
};
__device__ __forceinline__ unsigned int f2u(float f){ return __float_as_uint(f); }
__device__ __forceinline__ float u2f(unsigned int u){ return __uint_as_float(u); }

extern "C" __global__ void route_nets(const Maps maps, const NetJob *jobs, Work work, int *qn /* 2 per net */)
{
    const NetJob jb = jobs[blockIdx.x]; const Maps *m = &maps; const NetJob *j = &jb;
    const int nx = m->nx; const long long N = (long long)nx * m->ny;
    const int ww = j->ww, wh = j->wh; const long long WC = (long long)ww * wh, W2 = 2 * WC;
    unsigned long long *dp = work.dp + j->off; short *gid = work.gid + j->off; unsigned char *state = work.state + j->off;
    int *inq = work.inq + j->off; const short *ownocc = work.ownocc + j->off; const short *ownv = work.ownv + j->off / 2; int *qa = work.q0 + j->qoff, *qb = work.q1 + j->qoff;
    int *path = work.path + j->poff; int *plen = work.plen + blockIdx.x; int *status = work.status + blockIdx.x;
    int *qcnt = qn + 2 * blockIdx.x;
    __shared__ unsigned int s_fmin; __shared__ unsigned long long s_best; __shared__ int s_remaining; __shared__ int s_pl;
    __shared__ int s_hitg; __shared__ int s_stop; __shared__ int s_near; __shared__ float s_thr;
    const int tid = threadIdx.x, nt = blockDim.x;
    if (tid == 0) { s_remaining = j->ngroups; s_pl = 0; *status = 0; }
    __syncthreads();
    while (s_remaining > 1) {
        // init
        for (long long w = tid; w < W2; w += nt) { dp[w] = ((unsigned long long)INFBITS << 32) | 0xffffffffull; inq[w] = 0; }
        if (tid == 0) { qcnt[0] = 0; qcnt[1] = 0; s_best = ((unsigned long long)INFBITS << 32) | 0xffffffffull; s_fmin = INFBITS; s_stop = 0; }
        __syncthreads();
        for (long long w = tid; w < W2; w += nt) {
            if (state[w] & 1) {
                int l = (int)(w / WC); long long wc = w - l * WC; int y = (int)(wc / ww) + j->wy0, x = (int)(wc % ww) + j->wx0;
                long long c = (long long)y * nx + x, s = l * N + c;
                if (!blocked_t(m, j, s, c, m->occ_t[s] - ownocc[w])) { dp[w] = 0ull | 0xffffffffull; int k = atomicAdd(&qcnt[0], 1); qa[k] = (int)w; inq[w] = 1; }
            }
        }
        __syncthreads();
        int sweeps = 0; float thr = j->delta;   // near/far buckets: only entries below thr are relaxed, the rest are carried over
        while (1) {
            int qlen = qcnt[0];
            if (qlen == 0 || sweeps >= j->maxsweeps) break;
            if (tid == 0) { s_fmin = INFBITS; qcnt[1] = 0; s_near = 0; }
            __syncthreads();
            for (int qi = tid; qi < qlen; qi += nt) {
                int w = qa[qi];
                unsigned long long cur = dp[w]; unsigned int dbits = (unsigned int)(cur >> 32); float d = u2f(dbits);
                if (dbits >= (unsigned int)(s_best >> 32)) { inq[w] = 0; continue; }   // cannot improve the goal
                if (d >= thr) {   // far: carry over unrelaxed
                    int q = atomicAdd(&qcnt[1], 1); if (q < (int)W2) qb[q] = w; atomicMin(&s_fmin, dbits); continue;
                }
                inq[w] = 0; atomicAdd(&s_near, 1);
                int l = (int)(w / WC); long long wc = w - l * WC; int wy = (int)(wc / ww), wx = (int)(wc % ww);
                int y = wy + j->wy0, x = wx + j->wx0; long long c = (long long)y * nx + x;
                float cv = l == 0 ? j->against : 1.0f, ch = l == 0 ? 1.0f : j->against;
                int pdy = 0, pdx = 0; unsigned int pw = (unsigned int)(cur & 0xffffffffu);
                if (pw != 0xffffffffu && (int)(pw / WC) == l) { long long pc = pw - l * WC; pdy = wy - (int)(pc / ww); pdx = wx - (int)(pc % ww); }
                for (int k = 0; k < 5; k++) {
                    int dy = 0, dx = 0, nl = l; float step;
                    if (k == 0) dy = 1; else if (k == 1) dy = -1; else if (k == 2) dx = 1; else if (k == 3) dx = -1; else nl = 1 - l;
                    int jy = wy + dy, jx = wx + dx;
                    if (jy < 0 || jy >= wh || jx < 0 || jx >= ww) continue;
                    long long jc = (long long)(jy + j->wy0) * nx + (jx + j->wx0), js = nl * N + jc; long long jw = nl * WC + (long long)jy * ww + jx;
                    float nd; int oe = m->occ_t[js] - ownocc[jw];
                    if (k < 4) {
                        if (blocked_t(m, j, js, jc, oe)) continue;
                        if (dx && (m->field[c] || m->field[jc])) continue;
                        step = dx ? ch : cv; nd = d + step * cell_cost(m, j, js, jc, state[jw], oe);
                        if ((pdy || pdx) && (pdy != dy || pdx != dx)) nd += j->bend;
                    } else {
                        int ov = m->occ_v[c] - ownv[wc];
                        if (blocked_v(m, j, c, ov) || blocked_t(m, j, js, jc, oe)) continue;
                        nd = d + via_cost(m, j, c, ov);
                    }
                    unsigned long long nv = ((unsigned long long)f2u(nd) << 32) | (unsigned int)w;
                    unsigned long long old = atomicMin(dp + jw, nv);
                    if (nv < old) {
                        if (gid[jw] > 0 && !(state[jw] & 1)) { atomicMin(&s_best, ((unsigned long long)f2u(nd) << 32) | (unsigned int)jw); }
                        else if (atomicExch(&inq[jw], 1) == 0) { int q = atomicAdd(&qcnt[1], 1); if (q < (int)W2) qb[q] = (int)jw; atomicMin(&s_fmin, f2u(nd)); }
                        else atomicMin(&s_fmin, f2u(nd));
                    }
                }
            }
            __syncthreads();
            if (tid == 0) {
                if (qcnt[1] > (int)W2) qcnt[1] = (int)W2;
                int t = qcnt[0]; qcnt[0] = qcnt[1]; qcnt[1] = t;
                if (s_fmin >= (unsigned int)(s_best >> 32)) s_stop = 1;
                if (s_near == 0 && s_fmin < INFBITS) s_thr = u2f(s_fmin) + j->delta; else s_thr = thr;
            }
            __syncthreads();
            thr = s_thr;
            { int *t = qa; qa = qb; qb = t; }
            sweeps++;
            if (s_stop) break;
        }
        __syncthreads();
        // backtrace by thread 0
        if (tid == 0) {
            unsigned int gb = (unsigned int)(s_best >> 32);
            if (gb >= INFBITS) { *status = sweeps >= j->maxsweeps ? 3 : 1; s_remaining = 0; s_hitg = -1; }
            else {
                int w = (int)(s_best & 0xffffffffu); s_hitg = gid[w]; int pl = s_pl; int ok = 1;
                while (w != (int)0xffffffff) {
                    int l = (int)(w / WC); long long wc = w - l * WC; int y = (int)(wc / ww) + j->wy0, x = (int)(wc % ww) + j->wx0;
                    if (pl + 4 > j->pcap) { ok = 0; break; }
                    path[pl++] = l; path[pl++] = y; path[pl++] = x; state[w] |= 1;
                    unsigned long long cur = dp[w]; if ((unsigned int)(cur >> 32) == 0) break;
                    w = (int)(cur & 0xffffffffu);
                }
                if (!ok) { *status = 2; s_remaining = 0; } else { path[pl++] = -1; s_pl = pl; s_remaining--; }
                *plen = s_pl;
            }
        }
        __syncthreads();
        if (s_remaining <= 0) break;
        // the hit group becomes source; ring (state bit 1) around the new path cells
        int hg = s_hitg;
        for (long long w = tid; w < W2; w += nt) if (gid[w] == hg) state[w] |= 1;
        __syncthreads();
        {   // ring: cells within 3 of a new path cell on the same layer (not source)
            int pe = s_pl - 1; int ps = pe - 1; while (ps >= 0 && path[ps] != -1) ps--; ps++;
            for (int pi = ps + tid * 3; pi < pe; pi += nt * 3) {
                int l = path[pi], y = path[pi + 1], x = path[pi + 2];
                for (int dy = -3; dy <= 3; dy++) for (int dx = -3; dx <= 3; dx++) {
                    int yy = y + dy - j->wy0, xx = x + dx - j->wx0;
                    if (yy < 0 || yy >= wh || xx < 0 || xx >= ww) continue;
                    long long w = l * WC + (long long)yy * ww + xx;
                    if (!(state[w] & 1)) state[w] |= 2;
                }
            }
        }
        __syncthreads();
    }
}
