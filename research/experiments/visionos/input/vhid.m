// vhid: Mac-side sender for the visionOS reference simulator (Ycode research probe, our code).
// Builds Indigo messages with the exported builders (SimulatorKit, Xcode's visionOS DeviceKit
// plug-in), optionally patches bytes, hex-dumps, and sends them through SimDeviceLegacyHIDClient.
//  vhid <udid> pose <target> tx ty tz qx qy qz qw          target 300 = PalomaPose service
//  vhid <udid> sel <target> ox oy oz dx dy dz              target 301 = SelectionStream service
//  vhid <udid> coll <target> ox oy oz dx dy dz selOnly lPinch lDirect lExtra rPinch rDirect
//                  ltx lty ltz lqx lqy lqz lqw rtx rty rtz rqx rqy rqz rqw   (ARG9 env = rExtra)
//  vhid <udid> dial <delta>  |  vhid <udid> button <source>  |  vhid <udid> key <usage>
//  vhid <udid> bdown <source>  |  vhid <udid> bup <source>   (button down / up alone; script mode for holds)
//  vhid <udid> script        reads the verbs above, one per line, from stdin; "sleep <ms>" lines pause
// env: PATCH="off=byte,..." ; TS_OFFSET_MS / TS_ABS / STAMP (see stamp()) ; DUMP=1 (print only, no device) ; VERBOSE=1 ; REPEAT=n ; GAP_US=n
// Never send target 0: the reference's backboardd raises an exception and exits.
#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <malloc/malloc.h>
#include <simd/simd.h>
typedef struct { simd_float3 o, d; } Ray;
typedef void *(*PoseF)(uint32_t, simd_float3, simd_quatf);
typedef void *(*SelF)(uint32_t, const Ray *);
typedef void *(*CollF)(uint32_t, const Ray *, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint64_t, simd_float3, simd_quatf, simd_float3, simd_quatf);
typedef void *(*ButtonF)(int32_t, int32_t, int32_t);
typedef void *(*KeyF)(int32_t, int32_t);
typedef void *(*DialF)(double);
typedef void *(*DialVF)(simd_float2);
static id client; static dispatch_queue_t q;
static void dump(void *m){ size_t n=malloc_size(m); const uint8_t*b=m; for(size_t i=0;i<n;i+=16){printf("  %04zx:",i);for(size_t j=i;j<i+16&&j<n;j++)printf(" %02x",b[j]);printf("\n");} }
static void patch(void *m){ const char *p=getenv("PATCH"); if(!p) return; char *s=strdup(p),*t; while((t=strsep(&s,","))){ unsigned o,v; if(sscanf(t,"%i=%i",&o,&v)==2) ((uint8_t*)m)[o]=(uint8_t)v; } }
#include <mach/mach_time.h>
// TS_OFFSET_MS=<ms> (OBS-VISION-FOV): rewrite the record's host time (0x24) as now + ms (negative = past); TS_ABS=<ticks> sets it outright;
// TS_SCALE=<k>: time since the first message scaled by k (k < 1: denser timestamps than sent, k > 1: sparser, in the future).
// STAMP=1 prints "SENT <mach time> <time in message>" for every message.
static void stamp(void *m){ uint64_t now=mach_absolute_time(); mach_timebase_info_data_t tb; mach_timebase_info(&tb);
  static uint64_t t0; if(!t0) t0=now;
  if(getenv("TS_ABS")) *(uint64_t*)((uint8_t*)m+0x24)=strtoull(getenv("TS_ABS"),NULL,0);
  else if(getenv("TS_SCALE")) *(uint64_t*)((uint8_t*)m+0x24)=t0+(uint64_t)((double)(now-t0)*atof(getenv("TS_SCALE")));
  else if(getenv("TS_OFFSET_MS")){ double ms=atof(getenv("TS_OFFSET_MS")); int64_t d=(int64_t)(ms*1e6*tb.denom/tb.numer); *(uint64_t*)((uint8_t*)m+0x24)=now+d; }
  if(getenv("STAMP")) printf("SENT %llu %llu\n",now,*(uint64_t*)((uint8_t*)m+0x24)); }
static void send1(void *m){ patch(m); stamp(m); if(getenv("VERBOSE")||getenv("DUMP")) dump(m); if(getenv("DUMP")){free(m);return;}
  dispatch_semaphore_t s=dispatch_semaphore_create(0);
  ((void(*)(id,SEL,void*,BOOL,dispatch_queue_t,id))objc_msgSend)(client,NSSelectorFromString(@"sendWithMessage:freeWhenDone:completionQueue:completion:"),m,YES,q,^(NSError*e){ if(e) printf("error %s\n",e.description.UTF8String); dispatch_semaphore_signal(s);});
  dispatch_semaphore_wait(s,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC)); }
#define F(i) ((float)atof(argv[a+(i)]))
#define I(i) ((uint32_t)strtoul(argv[a+(i)],NULL,0))
static void *sk,*pl;
static void *build(const char *verb, char **argv, int a);
int main(int argc,char**argv){ @autoreleasepool{ setvbuf(stdout,NULL,_IOLBF,0);
  int a=1; NSString *udid=@(argv[a++]); const char *verb=argv[a++];
  dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",RTLD_NOW);
  sk=dlopen("/Applications/Xcode.app/Contents/SharedFrameworks/SimulatorKit.framework/SimulatorKit",RTLD_NOW);
  pl=dlopen("/Applications/Xcode.app/Contents/SharedFrameworks/DeviceKit.framework/Versions/A/PlugIns/VisionDeviceKitExtension.devicekitplugin/Contents/MacOS/VisionDeviceKitExtension",RTLD_NOW);
  q=dispatch_queue_create("vhid",DISPATCH_QUEUE_SERIAL);
  if(!getenv("DUMP")){ NSError*e=nil;
    id ctx=((id(*)(id,SEL,NSString*,NSError**))objc_msgSend)(NSClassFromString(@"SimServiceContext"),NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:"),@"/Applications/Xcode.app/Contents/Developer",&e);
    id set=((id(*)(id,SEL,NSError**))objc_msgSend)(ctx,NSSelectorFromString(@"defaultDeviceSetWithError:"),&e);
    NSDictionary*by=((id(*)(id,SEL))objc_msgSend)(set,NSSelectorFromString(@"devicesByUDID"));
    id dev=by[[[NSUUID alloc]initWithUUIDString:udid]]; if(!dev){printf("no device\n");return 1;}
    client=((id(*)(id,SEL,id,NSError**))objc_msgSend)([NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient") alloc],NSSelectorFromString(@"initWithDevice:error:"),dev,&e);
    if(!client){printf("no client %s\n",e.description.UTF8String);return 1;} }
  if(!strcmp(verb,"script")){ char line[2048]; int n=0;
    while(fgets(line,sizeof line,stdin)){ char *args[64]; int c=0; char *t,*p=line; while((t=strsep(&p," \t\n"))) if(*t) args[c++]=t; if(!c) continue;
      if(!strcmp(args[0],"sleep")){ usleep(atoi(args[1])*1000); continue; }
      void *m=build(args[0],args,1); if(m){ send1(m); n++; } }
    printf("script sent %d\n",n); return 0; }
  int rep=getenv("REPEAT")?atoi(getenv("REPEAT")):1; int gap=getenv("GAP_US")?atoi(getenv("GAP_US")):16000;
  for(int r=0;r<rep;r++){ void *m=build(verb,argv,a); if(!m){printf("verb?\n");return 2;} send1(m); if(rep>1) usleep(gap); }
  usleep(100000); printf("sent %s x%d\n",verb,rep); return 0; } }

static void *build(const char *verb, char **argv, int a){ void *m=NULL;

    if(!strcmp(verb,"pose")){ PoseF f=dlsym(pl,"IndigoHIDMessageForPalomaPose"); m=f(I(0),(simd_float3){F(1),F(2),F(3)},simd_quaternion(F(4),F(5),F(6),F(7))); }
    else if(!strcmp(verb,"sel")){ SelF f=dlsym(pl,"IndigoHIDMessageForPalomaSelection"); Ray ray={{F(1),F(2),F(3)},{F(4),F(5),F(6)}}; m=f(I(0),&ray); }
    else if(!strcmp(verb,"coll")){ CollF f=dlsym(pl,"IndigoHIDMessageForPalomaCollection"); Ray ray={{F(1),F(2),F(3)},{F(4),F(5),F(6)}};
      m=f(I(0),&ray,I(7),I(8),I(9),I(10),I(11),I(12),(uint64_t)strtoull(getenv("ARG9")?getenv("ARG9"):"0",NULL,0),(simd_float3){F(13),F(14),F(15)},simd_quaternion(F(16),F(17),F(18),F(19)),(simd_float3){F(20),F(21),F(22)},simd_quaternion(F(23),F(24),F(25),F(26))); }
    else if(!strcmp(verb,"button")){ ButtonF f=dlsym(sk,"IndigoHIDMessageForButton"); send1(f(I(0),1,0x33)); usleep(100000); m=f(I(0),2,0x33); }
    else if(!strcmp(verb,"bdown")){ ButtonF f=dlsym(sk,"IndigoHIDMessageForButton"); m=f(I(0),1,0x33); }
    else if(!strcmp(verb,"bup")){ ButtonF f=dlsym(sk,"IndigoHIDMessageForButton"); m=f(I(0),2,0x33); }
    else if(!strcmp(verb,"dial")){ DialF f=dlsym(sk,"IndigoHIDMessageForDigitalDialEvent"); m=f(atof(argv[a])); }
    else if(!strcmp(verb,"dialv")){ DialVF f=dlsym(sk,"IndigoHIDMessageForDigitalDialEvent"); m=f((simd_float2){F(0),F(1)}); }
    else if(!strcmp(verb,"key")){ KeyF f=dlsym(sk,"IndigoHIDMessageForKeyboardArbitrary"); send1(f(I(0),1)); usleep(50000); m=f(I(0),2); }
    else return NULL;
  return m; }
