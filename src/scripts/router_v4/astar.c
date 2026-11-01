// astar.c : grid A* for the PCB router (2 layers, 90-degree moves, layer 0 horizontal / layer 1 vertical preferred)
// build: gcc -O3 -shared -fPIC -o astar.so astar.c
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>

typedef struct { float f; int32_t idx; } HE;
static HE *heap; static size_t hn, hcap;
static void hpush(float f,int32_t idx){
    if(hn==hcap){ hcap=hcap?hcap*2:1<<20; heap=realloc(heap,hcap*sizeof(HE)); }
    size_t i=hn++;
    while(i){ size_t p=(i-1)/2; if(heap[p].f<=f) break; heap[i]=heap[p]; i=p; }
    heap[i].f=f; heap[i].idx=idx;
}
static HE hpop(void){
    HE top=heap[0]; HE last=heap[--hn]; size_t i=0;
    for(;;){ size_t a=2*i+1,b=a+1,m=i; float fm=last.f;
        if(a<hn && heap[a].f<fm){ m=a; fm=heap[a].f; }
        if(b<hn && heap[b].f<fm){ m=b; }
        if(m==i) break; heap[i]=heap[m]; i=m; }
    heap[i]=last; return top;
}

/* bt[2][ny][nx] blocked for track; bv[ny][nx] blocked for via; ct[2][ny][nx] cell cost; cvia[ny][nx] via cost;
   H[ny][nx] heuristic (distance to goal in cells); src/goal[2][ny][nx]; field[ny][nx] no horizontal moves.
   out: path as (l,iy,ix) triplets, goal first; returns length (triplets) or 0 if none; expanded in *ne. */
int astar(int nx,int ny,int wx0,int wx1,int wy0,int wy1,
          const uint8_t *bt,const uint8_t *bv,const float *ct,const float *cvia,const float *H,
          const uint8_t *src,const uint8_t *goal,float against,float bend,const uint8_t *field,
          int32_t *out,int maxlen,int64_t *ne,int diag)
{
    size_t N=(size_t)nx*ny, N2=2*N;
    float *dist=malloc(N2*sizeof(float)); int32_t *prev=malloc(N2*sizeof(int32_t)); uint8_t *closed=calloc(N2,1);
    for(size_t i=0;i<N2;i++) dist[i]=INFINITY;
    memset(prev,-1,N2*sizeof(int32_t));
    hn=0;
    for(int l=0;l<2;l++) for(int iy=wy0;iy<wy1;iy++) for(int ix=wx0;ix<wx1;ix++){
        size_t c=(size_t)iy*nx+ix, s=l*N+c;
        if(src[s] && !bt[s]){ dist[s]=0; hpush(H[c],(int32_t)s); }
    }
    int64_t cnt=0; int32_t end=-1;
    while(hn){
        HE e=hpop(); size_t s=e.idx;
        if(closed[s]) continue; closed[s]=1; cnt++;
        if(goal[s]){ end=(int32_t)s; break; }
        int l=s>=N; size_t c=s-l*N; int iy=c/nx, ix=c%nx; float d=dist[s];
        float cv = l==0?against:1.0f, ch = l==0?1.0f:against;
        int pdy=0,pdx=0; int32_t p=prev[s];
        if(p>=0 && (p>=(int32_t)N)==l){ size_t pc=p-l*N; pdy=iy-(int)(pc/nx); pdx=ix-(int)(pc%nx); }
        const int dys[8]={1,-1,0,0,1,1,-1,-1}, dxs[8]={0,0,1,-1,1,-1,1,-1};
        int nk=diag?8:4;
        for(int k=0;k<nk;k++){
            int dy=dys[k],dx=dxs[k]; int jy=iy+dy,jx=ix+dx;
            if(jy<wy0||jy>=wy1||jx<wx0||jx>=wx1) continue;
            size_t jc=(size_t)jy*nx+jx, js=l*N+jc;
            if(bt[js]) continue;
            if(dx && (field[c]||field[jc])) continue;
            float step;
            if(dy&&dx){ if(bt[l*N+(size_t)iy*nx+jx]||bt[l*N+(size_t)jy*nx+ix]) continue; step=1.41421356f*(0.5f*(cv+ch)); }
            else step=dx?ch:cv;
            float nd=d+step*ct[js];
            if(p>=0 && (pdy||pdx) && (pdy!=dy||pdx!=dx)) nd+=bend;
            if(nd<dist[js]){ dist[js]=nd; prev[js]=(int32_t)s; hpush(nd+H[jc],(int32_t)js); }
        }
        if(!bv[c]){
            int m=1-l; size_t ms=m*N+c;
            if(!bt[ms]){ float nd=d+cvia[c]; if(nd<dist[ms]){ dist[ms]=nd; prev[ms]=(int32_t)s; hpush(nd+H[c],(int32_t)ms); } }
        }
    }
    *ne=cnt; int len=0;
    if(end>=0){
        int32_t s=end;
        while(s>=0 && len<maxlen){ int l=s>=(int32_t)N; size_t c=s-l*N; out[3*len]=l; out[3*len+1]=c/nx; out[3*len+2]=c%nx; len++; s=prev[s]; }
    }
    free(dist); free(prev); free(closed);
    return len;
}
