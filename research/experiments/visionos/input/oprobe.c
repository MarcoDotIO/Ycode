// oprobe: guest command-line probe (simctl spawn), OBS-VISION-POSE 2026-11-01, our code.
// Builds Orientation events (IOHIDFamily type 10) in several ways and prints, for each, which
// constructors exist (dlsym) and the values read back from fields (10 << 16) | 0..15 plus the
// event's own description. Shows which construction keeps a quaternion (orientation type 3).
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>
typedef void *E;
typedef E (*Create)(CFAllocatorRef, uint32_t, uint64_t, uint32_t);
typedef E (*Q4)(CFAllocatorRef, uint64_t, double, double, double, double, uint32_t);
typedef double (*GetF)(E, uint32_t); typedef CFIndex (*GetI)(E, uint32_t);
typedef void (*SetF)(E, uint32_t, double); typedef void (*SetI)(E, uint32_t, CFIndex);
static GetF getF; static GetI getI;
static void show(const char *what, E e){
  printf("== %s: %s\n", what, e ? "event" : "NULL"); if(!e) return;
  for(uint32_t i=0;i<16;i++){ uint32_t f=(10u<<16)|i; double d=getF(e,f); CFIndex n=getI(e,f); if(d!=0||n!=0) printf("   field %u: float %.6f int %ld\n",i,d,(long)n); }
  CFStringRef s=CFCopyDescription(e); char b[4096]; if(s&&CFStringGetCString(s,b,sizeof b,kCFStringEncodingUTF8)){ const char *p=strstr(b,"Orientation type"); printf("   %s\n", p?p:"(no orientation type line)"); } if(s) CFRelease(s);
}
int main(void){
  void *k=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_NOW);
  const char *names[]={"IOHIDEventCreateOrientationEvent","IOHIDEventCreatePolarOrientationEvent","IOHIDEventCreateQuaternionOrientationEvent",
    "IOHIDEventCreateOrientationEventWithQuaternion","IOHIDEventCreateTiltOrientationEvent","IOHIDEventCreateDeviceOrientationEventWithUsage",
    "IOHIDEventCreateEulerOrientationEvent",NULL};
  for(int i=0;names[i];i++) printf("dlsym %s: %s\n",names[i],dlsym(k,names[i])?"present":"absent");
  getF=(GetF)dlsym(k,"IOHIDEventGetFloatValue"); getI=(GetI)dlsym(k,"IOHIDEventGetIntegerValue");
  Create c=(Create)dlsym(k,"IOHIDEventCreate"); SetF sf=(SetF)dlsym(k,"IOHIDEventSetFloatValue"); SetI si=(SetI)dlsym(k,"IOHIDEventSetIntegerValue");
  double w=0.965926,x=0,y=0.258819,z=0;
  E a=c(NULL,10,0,0); si(a,(10u<<16)|3,3); for(int i=0;i<4;i++) sf(a,(10u<<16)|(8+i),(double[]){w,x,y,z}[i]); show("generic create, int field 3 = 3, floats 8..11",a);
  E b=c(NULL,10,0,0); for(int i=0;i<4;i++) sf(b,(10u<<16)|(8+i),(double[]){w,x,y,z}[i]); si(b,(10u<<16)|3,3); show("generic create, floats 8..11, then int field 3 = 3",b);
  E d=c(NULL,10,0,0); sf(d,(10u<<16)|3,3); for(int i=0;i<4;i++) sf(d,(10u<<16)|(8+i),(double[]){w,x,y,z}[i]); show("generic create, float field 3 = 3, floats 8..11",d);
  Q4 q=(Q4)dlsym(k,"IOHIDEventCreateQuaternionOrientationEvent");
  if(q){ E e=q(NULL,0,w,x,y,z,0); show("quaternion constructor (w, x, y, z)",e); E g=q(NULL,0,x,y,z,w,0); show("quaternion constructor (x, y, z, w)",g);
    if(e){ sf(e,(10u<<16)|9,0.5); show("quaternion constructor then float field 9 = 0.5",e);} }
  return 0;
}
