// hidrec: our recorder, inserted into the guest's backboardd. Logs every event the HID bundle
// dispatches (_IOHIDServiceDispatchEvent: sender ID and the event's own description) and the
// arguments of vendor-defined event creation, to $HIDREC_FILE.
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <pthread.h>
typedef void *IOHIDServiceRef; typedef void *IOHIDEventRef;
extern void _IOHIDServiceDispatchEvent(IOHIDServiceRef, IOHIDEventRef);
extern uint64_t _IOHIDServiceGetSenderID(IOHIDServiceRef);
extern IOHIDEventRef IOHIDEventCreateVendorDefinedEvent(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, const uint8_t *, CFIndex, uint32_t);
static FILE *f; static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static FILE *out(void){ if(!f){ const char *p=getenv("HIDREC_FILE"); if(p) f=fopen(p,"a"); if(f) setvbuf(f,NULL,_IOLBF,0);} return f; }
static void my_dispatch(IOHIDServiceRef s, IOHIDEventRef e){
  pthread_mutex_lock(&mu);
  if(out()){ CFStringRef d=CFCopyDescription(e); char buf[16384]; buf[0]=0; if(d){ CFStringGetCString(d,buf,sizeof buf,kCFStringEncodingUTF8); CFRelease(d);} 
    fprintf(f,"DISPATCH sender=0x%llx\n%s\n----\n",(unsigned long long)_IOHIDServiceGetSenderID(s),buf); }
  pthread_mutex_unlock(&mu);
  _IOHIDServiceDispatchEvent(s,e);
}
static IOHIDEventRef my_vendor(CFAllocatorRef a, uint64_t ts, uint32_t page, uint32_t usage, uint32_t ver, const uint8_t *data, CFIndex len, uint32_t opt){
  pthread_mutex_lock(&mu);
  if(out()){ fprintf(f,"VENDOR page=0x%x usage=0x%x version=%u len=%ld opt=0x%x data=",page,usage,ver,(long)len,opt); for(CFIndex i=0;i<len;i++) fprintf(f,"%02x",data[i]); fprintf(f,"\n"); }
  pthread_mutex_unlock(&mu);
  return IOHIDEventCreateVendorDefinedEvent(a,ts,page,usage,ver,data,len,opt);
}
__attribute__((used, section("__DATA,__interpose"))) static struct { const void *r, *o; } interp[] = {
  { (const void *)my_dispatch, (const void *)_IOHIDServiceDispatchEvent },
  { (const void *)my_vendor, (const void *)IOHIDEventCreateVendorDefinedEvent },
};
