// bprobe: black-box signature probe for exported Indigo message builders (our code).
// Calls a builder with recognisable values in x0..x7 and v0..v7, in a forked child,
// and reports where those values land in the returned message.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <malloc/malloc.h>
#include <simd/simd.h>
#include <sys/wait.h>
#include <unistd.h>
typedef simd_float4 V;
typedef void *(*F)(uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,V,V,V,V,V,V,V,V);
static float bufs[8][256];
static void dump(const uint8_t *b, size_t n){ for(size_t i=0;i<n;i+=16){printf("  %04zx:",i);for(size_t j=i;j<i+16&&j<n;j++)printf(" %02x",b[j]);printf("\n");} }
static void annotate(const uint8_t *b, size_t n, uint64_t *x, int mode){
  for(size_t o=0;o+4<=n;o+=1){ float f; memcpy(&f,b+o,4); uint32_t u; memcpy(&u,b+o,4);
    if(f>=10.0f && f<90.0f && fmodf(f,1.0f)==0.5f){ int r=(int)(f/10)-1, l=(int)f%10; printf("  @0x%03zx float v%d lane %d (%.1f)\n",o,r,l,f);}
    else if(f>=1000.0f && f<9000.0f && fmodf(f,1.0f)==0.0f){ int r=(int)(f/1000)-1, k=(int)f%1000; printf("  @0x%03zx float *x%d [%d] (%.0f)\n",o,r,k,f);}
    if(mode!=0 && u>=0x11 && u<=0x88 && u%0x11==0) printf("  @0x%03zx u32 = x%d (0x%x)\n",o,u/0x11-1,u);
  }
  for(size_t o=0;o+8<=n;o+=1){ double d; memcpy(&d,b+o,8);
    if(d>=10.0 && d<90.0 && fmod(d,1.0)==0.5){ printf("  @0x%03zx double v%d lane %d (%.1f)\n",o,(int)(d/10)-1,(int)d%10,d);}
    else if(d>=1000.0&&d<9000.0&&fmod(d,1.0)==0.0){ printf("  @0x%03zx double *x%d [%d]\n",o,(int)(d/1000)-1,(int)d%1000);}
    uint64_t q; memcpy(&q,b+o,8); for(int i=0;i<8;i++) if(q==x[i] && x[i]>0x1000) printf("  @0x%03zx ptr x%d\n",o,i);
  }
}
int main(int argc, char **argv){
  setvbuf(stdout,NULL,_IOLBF,0);
  dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW);
  void *sk=dlopen("/Applications/Xcode.app/Contents/SharedFrameworks/SimulatorKit.framework/SimulatorKit", RTLD_NOW);
  void *pl=dlopen("/Applications/Xcode.app/Contents/SharedFrameworks/DeviceKit.framework/Versions/A/PlugIns/VisionDeviceKitExtension.devicekitplugin/Contents/MacOS/VisionDeviceKitExtension", RTLD_NOW);
  const char *name=argv[1]; int mode=atoi(argv[2]); // mode 0: x = pointers; 1: x = small ints 0x11..0x88; 2: x = 0
  F f=(F)dlsym(pl,name); if(!f) f=(F)dlsym(sk,name); if(!f){printf("no %s\n",name);return 1;}
  for(int i=0;i<8;i++) for(int j=0;j<256;j++) bufs[i][j]=(float)((i+1)*1000+j);
  uint64_t x[8]; for(int i=0;i<8;i++) x[i]= mode==0 ? (uint64_t)bufs[i] : mode==1 ? 0x11*(i+1) : 0;
  if(argc>3){ // explicit overrides: xN=value
    for(int a=3;a<argc;a++){ int r; unsigned long long v; if(sscanf(argv[a],"x%d=%lli",&r,&v)==2) x[r]=v; }
  }
  V v[8]; for(int i=0;i<8;i++) v[i]=(V){(i+1)*10+0.5f,(i+1)*10+1.5f,(i+1)*10+2.5f,(i+1)*10+3.5f};
  pid_t p=fork();
  if(p==0){ void *m=f(x[0],x[1],x[2],x[3],x[4],x[5],x[6],x[7],v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7]);
    size_t n=m?malloc_size(m):0; printf("%s mode %d -> %p size %zu\n",name,mode,m,n);
    if(m&&n){ dump(m,n); annotate(m,n,x,mode);} _exit(0);}
  int st; waitpid(p,&st,0); if(!WIFEXITED(st)) printf("%s mode %d: child died signal %d\n",name,mode,WTERMSIG(st));
  return 0; }
