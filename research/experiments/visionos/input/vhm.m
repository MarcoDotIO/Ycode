// vhm: Mac-side client for the guest daemon vhmdd (our code). Looks the service up in the
// device's bootstrap via CoreSimulator, wraps the send right in an XPC endpoint and sends
// one dictionary built from key=value arguments; prints the reply and any events for a while.
//  vhm <udid> <service> key=s:string key=i:int key=u:uint key=d:double key=b:1 key=m:16floats(comma) ... [WAIT=s]
//  vhm <udid> <service> - [WAIT=s]   one message per stdin line on one connection; "sleep <ms>" lines
#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <xpc/xpc.h>
#include <dlfcn.h>
extern xpc_endpoint_t xpc_endpoint_create_mach_port_4sim(mach_port_t);
extern void xpc_connection_enable_sim2host_4sim(xpc_connection_t);
static void send1(xpc_connection_t c, char **argv, int argc){
  xpc_object_t m=xpc_dictionary_create_empty();
  for(int i=0;i<argc;i++){ char *eq=strchr(argv[i],'='); if(!eq) continue; *eq=0; const char*k=argv[i]; char*v=eq+1;
    if(!strcmp(k,"WAIT")) continue;
    if(v[0]&&v[1]==':'){ char t=v[0]; v+=2;
      if(t=='s') xpc_dictionary_set_string(m,k,v); else if(t=='i') xpc_dictionary_set_int64(m,k,atoll(v));
      else if(t=='u') xpc_dictionary_set_uint64(m,k,strtoull(v,NULL,0));
      else if(t=='d') xpc_dictionary_set_double(m,k,atof(v)); else if(t=='b') xpc_dictionary_set_bool(m,k,atoi(v));
      else if(t=='m'){ float f[16]={0}; int n=0; char*p=v,*tk; while((tk=strsep(&p,","))&&n<16) f[n++]=atof(tk); xpc_dictionary_set_data(m,k,f,sizeof f); } } }
  char*d=xpc_copy_description(m); printf("SEND %s\n",d); free(d);
  xpc_object_t r=xpc_connection_send_message_with_reply_sync(c,m);
  d=xpc_copy_description(r); printf("REPLY %s\n",d); free(d);
  if(xpc_get_type(r)==XPC_TYPE_DICTIONARY){ size_t n=0; const void*p=xpc_dictionary_get_data(r,"pose",&n); if(p&&n==64){ const float*f=p; printf("pose matrix cols:"); for(int i=0;i<16;i++) printf("%s%.4f",i%4?",":" | ",f[i]); printf("\n"); } } }
int main(int argc,char**argv){ @autoreleasepool{ setvbuf(stdout,NULL,_IOLBF,0);
  dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",RTLD_NOW);
  NSError*e=nil;
  id ctx=((id(*)(id,SEL,NSString*,NSError**))objc_msgSend)(NSClassFromString(@"SimServiceContext"),NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:"),@"/Applications/Xcode.app/Contents/Developer",&e);
  id set=((id(*)(id,SEL,NSError**))objc_msgSend)(ctx,NSSelectorFromString(@"defaultDeviceSetWithError:"),&e);
  NSDictionary*by=((id(*)(id,SEL))objc_msgSend)(set,NSSelectorFromString(@"devicesByUDID"));
  id dev=by[[[NSUUID alloc]initWithUUIDString:@(argv[1])]];
  mach_port_t port=((mach_port_t(*)(id,SEL,NSString*,NSError**))objc_msgSend)(dev,NSSelectorFromString(@"lookup:error:"),@(argv[2]),&e);
  printf("lookup %s -> 0x%x %s\n",argv[2],port,e?e.description.UTF8String:"");
  if(!port) return 1;
  xpc_endpoint_t ep=xpc_endpoint_create_mach_port_4sim(port);
  xpc_connection_t c=xpc_connection_create_from_endpoint(ep);
  xpc_connection_enable_sim2host_4sim(c);
  xpc_connection_set_event_handler(c,^(xpc_object_t o){ char *d=xpc_copy_description(o); printf("EVENT %.3f %s\n",[NSDate date].timeIntervalSince1970,d); free(d); });
  xpc_connection_resume(c);
  double wait=1;
  // One message from the arguments, or (argument "-") one message per stdin line on this one
  // connection ("sleep <ms>" lines pause while events keep printing).
  if(argc>3&&!strcmp(argv[3],"-")){ char line[4096];
    for(int i=4;i<argc;i++) if(!strncmp(argv[i],"WAIT=",5)) wait=atof(argv[i]+5);
    while(fgets(line,sizeof line,stdin)){ char *args[64]; int n=0; char *t,*p=line; while((t=strsep(&p," \t\n"))) if(*t&&n<64) args[n++]=t; if(!n) continue;
      if(!strcmp(args[0],"sleep")){ [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:atof(args[1])/1000.0]]; continue; }
      printf("T %.3f\n",[NSDate date].timeIntervalSince1970); send1(c,args,n); }
  } else { char **args=argv+3; int n=argc-3; for(int i=0;i<n;i++) if(!strncmp(args[i],"WAIT=",5)) wait=atof(args[i]+5); send1(c,args,n); }
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:wait]];
  return 0; } }
