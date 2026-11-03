// hidrec2: our recorder for pose events (OBS-VISION-POSE, 2026-11-01), inserted into the guest's
// backboardd like hidrec. For every dispatched event it logs the sender ID, the event's own
// description, and for the event and each child: type, event flags, and the float and integer
// value of field (type << 16) | i for i = 0..15 (IOHIDFamily's field numbering, IOHIDEventFieldDefs.h).
// HIDREC_REWRITE=1 replaces a pose event (vendor 0xFF00 / 0x72) before dispatch with one built the
// way Ycode's HID bundle builds it (generic Orientation event, integer field 3 = 3, floats in
// fields 8..11 = w, x, y, z), keeping the received translation and quaternion; HIDREC_REWRITE=2 the
// same with fields 4..7; HIDREC_REWRITE=3 drops the Orientation child. HIDREC_QBASE (default 4) is the
// first field the received quaternion is read from: set 8. A "LOADED" line is written per process.
// HIDREC_FILE must be writable from the guest: a folder in the device's data directory other than
// tmp (cleared at boot) worked; a path on the USB volume gave no log.
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <pthread.h>
typedef void *IOHIDServiceRef; typedef void *IOHIDEventRef;
extern void _IOHIDServiceDispatchEvent(IOHIDServiceRef, IOHIDEventRef);
extern uint64_t _IOHIDServiceGetSenderID(IOHIDServiceRef);
extern uint32_t IOHIDEventGetType(IOHIDEventRef);
extern CFArrayRef IOHIDEventGetChildren(IOHIDEventRef);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, uint32_t);
extern CFIndex IOHIDEventGetIntegerValue(IOHIDEventRef, uint32_t);
extern void IOHIDEventSetFloatValue(IOHIDEventRef, uint32_t, double);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef, uint32_t, CFIndex);
extern uint32_t IOHIDEventGetEventFlags(IOHIDEventRef);
extern void IOHIDEventSetEventFlags(IOHIDEventRef, uint32_t);
extern uint64_t IOHIDEventGetTimeStamp(IOHIDEventRef);
extern IOHIDEventRef IOHIDEventCreate(CFAllocatorRef, uint32_t, uint64_t, uint32_t);
extern void IOHIDEventAppendEvent(IOHIDEventRef, IOHIDEventRef, uint32_t);
extern IOHIDEventRef IOHIDEventCreateVendorDefinedEvent(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, const uint8_t *, CFIndex, uint32_t);
extern IOHIDEventRef IOHIDEventCreateTranslationEvent(CFAllocatorRef, uint64_t, double, double, double, uint32_t);
static FILE *f; static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static FILE *out(void){ if(!f){ const char *p=getenv("HIDREC_FILE"); if(p) f=fopen(p,"a"); if(f) setvbuf(f,NULL,_IOLBF,0);} return f; }
static void fields(IOHIDEventRef e, int depth){
  uint32_t t=IOHIDEventGetType(e);
  fprintf(f,"%*sTYPE %u flags=0x%x\n",depth*2,"",t,IOHIDEventGetEventFlags(e));
  if(t!=1) for(uint32_t i=0;i<16;i++){ uint32_t fid=(t<<16)|i; double d=IOHIDEventGetFloatValue(e,fid); CFIndex n=IOHIDEventGetIntegerValue(e,fid);
    if(d!=0||n!=0) fprintf(f,"%*s  field 0x%x (%u<<16|%u): float %.6f int %ld\n",depth*2,"",fid,t,i,d,(long)n); }
  CFArrayRef c=IOHIDEventGetChildren(e); if(c) for(CFIndex k=0;k<CFArrayGetCount(c);k++) fields((IOHIDEventRef)CFArrayGetValueAtIndex(c,k),depth+1);
}
static int is_pose(IOHIDEventRef e){ return IOHIDEventGetType(e)==1 && IOHIDEventGetIntegerValue(e,(1<<16)|0)==0xFF00 && IOHIDEventGetIntegerValue(e,(1<<16)|1)==0x72; }
static IOHIDEventRef rewrite(IOHIDEventRef e, int mode){
  CFArrayRef c=IOHIDEventGetChildren(e); if(!c) return NULL;
  double t[3]={0}, q[4]={1,0,0,0}; int have=0;
  for(CFIndex k=0;k<CFArrayGetCount(c);k++){ IOHIDEventRef ch=(IOHIDEventRef)CFArrayGetValueAtIndex(c,k); uint32_t ty=IOHIDEventGetType(ch);
    if(ty==4) for(int i=0;i<3;i++) t[i]=IOHIDEventGetFloatValue(ch,(4<<16)|i);
    if(ty==10){ have=1; for(int i=0;i<4;i++) q[i]=IOHIDEventGetFloatValue(ch,(10<<16)|(uint32_t)(getenv("HIDREC_QBASE")?atoi(getenv("HIDREC_QBASE")):4)+i); } }
  uint64_t ts=IOHIDEventGetTimeStamp(e); static const uint8_t none[1]={0};
  IOHIDEventRef p=IOHIDEventCreateVendorDefinedEvent(NULL,ts,0xFF00,0x72,13,none,0,1); IOHIDEventSetEventFlags(p,1);
  IOHIDEventRef tr=IOHIDEventCreateTranslationEvent(NULL,ts,t[0],t[1],t[2],0); IOHIDEventSetEventFlags(tr,0); IOHIDEventAppendEvent(p,tr,0); CFRelease(tr);
  if(mode!=3){ IOHIDEventRef o=IOHIDEventCreate(NULL,10,ts,0); IOHIDEventSetIntegerValue(o,(10<<16)|3,3);
    uint32_t base = mode==2 ? 4 : 8; for(uint32_t i=0;i<4;i++) IOHIDEventSetFloatValue(o,(10<<16)|(base+i),q[i]);
    IOHIDEventSetEventFlags(o,0); IOHIDEventAppendEvent(p,o,0); CFRelease(o); }
  fprintf(f,"REWRITE mode %d (orientation seen %d) t %.3f %.3f %.3f q %.4f %.4f %.4f %.4f\n",mode,have,t[0],t[1],t[2],q[0],q[1],q[2],q[3]);
  return p;
}
static void my_dispatch(IOHIDServiceRef s, IOHIDEventRef e){
  IOHIDEventRef r=NULL;
  pthread_mutex_lock(&mu);
  if(out()){ CFStringRef d=CFCopyDescription(e); char buf[16384]; buf[0]=0; if(d){ CFStringGetCString(d,buf,sizeof buf,kCFStringEncodingUTF8); CFRelease(d);}
    fprintf(f,"DISPATCH sender=0x%llx\n%s\n",(unsigned long long)_IOHIDServiceGetSenderID(s),buf); fields(e,0);
    const char *m=getenv("HIDREC_REWRITE"); if(m && is_pose(e)){ r=rewrite(e,atoi(m)); if(r){ fprintf(f,"AFTER REWRITE\n"); fields(r,0);} }
    fprintf(f,"----\n"); }
  pthread_mutex_unlock(&mu);
  _IOHIDServiceDispatchEvent(s,r?r:e);
  if(r) CFRelease(r);
}
__attribute__((constructor)) static void hello(void){ pthread_mutex_lock(&mu); if(out()) fprintf(f,"LOADED\n"); pthread_mutex_unlock(&mu); }
__attribute__((used, section("__DATA,__interpose"))) static struct { const void *r, *o; } interp[] = {
  { (const void *)my_dispatch, (const void *)_IOHIDServiceDispatchEvent },
};
