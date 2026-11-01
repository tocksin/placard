// pfcommon.h : cost / blocking rules shared by the CPU (pfcpu.c) and CUDA (pfgpu.cu) negotiated routers.
// Grid: 2 layers (0 = F.Cu horizontal preferred, 1 = B.Cu vertical preferred), cell index c = y*nx+x, s = l*N+c.
#ifndef PFCOMMON_H
#define PFCOMMON_H
#ifdef __CUDACC_RTC__
typedef int int32_t; typedef short int16_t; typedef unsigned char uint8_t;
#else
#include <stdint.h>
#endif
#ifndef DEVFN
#define DEVFN static inline
#endif
typedef struct {
    int n;                 // net number
    int wx0, wy0, ww, wh;  // window (cells)
    int ngroups;           // groups to join
    long long off;         // offset of this net's window arrays (in window cell-layers = 2*ww*wh)
    long long qoff;        // offset of this net's two queues (each 2*ww*wh ints)
    long long poff;        // offset of this net's path buffer (ints, triplets l,y,x with -1 separators)
    int pcap;              // path buffer capacity (ints)
    float pres, viacost, against, ring, soft, bend;
    int hard;              // 1: cells occupied by other new routes are blocked; 0: they cost pres*occ
    int maxsweeps;
    int busid; float busgain;   // bus attraction: cells in the band next to sibling routes cost *busgain
} NetJob;
typedef struct {           // global board maps, all ny*nx (per layer arrays are 2*ny*nx)
    int nx, ny;
    const int32_t *own_t; const uint8_t *mul_t; const int32_t *cop;
    const int32_t *own_v; const uint8_t *mul_v;
    const uint8_t *edge_t; const uint8_t *edge_v; const uint8_t *field;
    const float *hist; const float *hist_v; const int16_t *occ_t; const int16_t *occ_v;
    const uint8_t *soft_t; const uint8_t *soft_v;   // rippable copper (cost 'soft' instead of blocked), may be NULL
    const int16_t *bus;    // bus id of the band next to routed bus members (per layer), may be NULL
} Maps;
#define INFBITS 0x7f800000u
/* occ = occupancy by OTHER nets' routes at this cell (global count minus the net's own previous route) */
DEVFN int blocked_t(const Maps *m, const NetJob *j, long long s, long long c, int occ) {
    int o = m->own_t[s];
    if (m->mul_t[s] || m->edge_t[c]) return 1;
    if (o && o != j->n) { if (m->soft_t && m->soft_t[s]) return 0; return 1; }
    if (j->hard && occ > 0) { if (m->soft_t && m->soft_t[s]) return 0; return 1; }
    return 0;
}
DEVFN int blocked_v(const Maps *m, const NetJob *j, long long c, int occ) {
    int o = m->own_v[c];
    if (m->mul_v[c] || m->edge_v[c]) return 1;
    if (o && o != j->n) { if (m->soft_v && m->soft_v[c]) return 0; return 1; }
    if (j->hard && occ > 0) { if (m->soft_v && m->soft_v[c]) return 0; return 1; }
    return 0;
}
DEVFN float cell_cost(const Maps *m, const NetJob *j, long long s, long long c, uint8_t state, int occ) {
    float k = 1.0f + m->hist[s] + j->pres * (float)occ;
    int o = m->own_t[s];
    if ((o == j->n && m->cop[s] != j->n) || (state & 2)) k += j->ring;
    if (m->soft_t && m->soft_t[s] && ((o && o != j->n) || (j->hard && occ > 0))) k += j->soft;
    if (m->bus && j->busid > 0 && m->bus[s] == j->busid) k *= j->busgain;
    return k;
}
DEVFN float via_cost(const Maps *m, const NetJob *j, long long c, int occ) {
    float k = j->viacost * (1.0f + m->hist_v[c] + j->pres * (float)occ);
    int o = m->own_v[c];
    if (m->soft_v && m->soft_v[c] && ((o && o != j->n) || (j->hard && occ > 0))) k += j->viacost * j->soft;
    return k;
}
#endif
