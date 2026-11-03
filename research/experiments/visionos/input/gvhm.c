// gvhm: guest-side client for vhmdd (our code), run with simctl spawn.
//  gvhm <service> key=s:str key=i:n key=d:x key=b:0/1 key=m:16 floats ... [WAIT=s] [NOREPLY=1]
#include <xpc/xpc.h>
extern xpc_connection_t ycode_mach_service(const char *, dispatch_queue_t, uint64_t) __asm__("_xpc_connection_create_mach_service");
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc,char**argv){ setvbuf(stdout,NULL,_IOLBF,0);
  xpc_connection_t c=ycode_mach_service(argv[1],NULL,0);
  xpc_connection_set_event_handler(c,^(xpc_object_t o){ char*d=xpc_copy_description(o); printf("EVENT %s\n",d); free(d);
     if(xpc_get_type(o)==XPC_TYPE_DICTIONARY){ size_t n=0; const float*f=xpc_dictionary_get_data(o,"pose",&n); if(f&&n==64){ printf("  pose:"); for(int i=0;i<16;i++) printf("%s%.4f",i%4?",":" | ",f[i]); printf("\n");} } });
  xpc_connection_resume(c);
  double wait=0.5; int noreply=0;
  xpc_object_t m=xpc_dictionary_create(NULL,NULL,0);
  for(int i=2;i<argc;i++){ char*eq=strchr(argv[i],'='); if(!eq) continue; *eq=0; const char*k=argv[i]; char*v=eq+1;
    if(!strcmp(k,"WAIT")){wait=atof(v);continue;} if(!strcmp(k,"NOREPLY")){noreply=1;continue;}
    char t=v[0]; v+=2;
    if(t=='s') xpc_dictionary_set_string(m,k,v); else if(t=='i') xpc_dictionary_set_int64(m,k,atoll(v));
    else if(t=='d') xpc_dictionary_set_double(m,k,atof(v)); else if(t=='b') xpc_dictionary_set_bool(m,k,atoi(v));
    else if(t=='m'){ float f[16]={0}; int n=0; char*p=v,*tk; while((tk=strsep(&p,","))&&n<16) f[n++]=atof(tk); xpc_dictionary_set_data(m,k,f,sizeof f);} }
  char*d=xpc_copy_description(m); printf("SEND %s\n",d); free(d);
  if(noreply) xpc_connection_send_message(c,m);
  else { xpc_object_t r=xpc_connection_send_message_with_reply_sync(c,m); d=xpc_copy_description(r); printf("REPLY %s\n",d); free(d);
    if(xpc_get_type(r)==XPC_TYPE_DICTIONARY){ size_t n=0; const float*f=xpc_dictionary_get_data(r,"pose",&n); if(f&&n==64){ printf("  pose:"); for(int i=0;i<16;i++) printf("%s%.4f",i%4?",":" | ",f[i]); printf("\n");} } }
  usleep((useconds_t)(wait*1e6)); return 0; }
