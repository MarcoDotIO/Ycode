// mkdev: create a simulator device on a runtime chosen by build version (our code). simctl picks
// one runtime per identifier; when two builds share an identifier this selects the one wanted.
//  mkdev <name> <device type identifier> <runtime build, e.g. 24M362>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <dlfcn.h>
int main(int argc,char**argv){ @autoreleasepool{
  if(argc<4){ fprintf(stderr,"usage: mkdev name devtype build\n"); return 2; }
  dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",RTLD_NOW);
  NSError*e=nil;
  id ctx=((id(*)(id,SEL,NSString*,NSError**))objc_msgSend)(NSClassFromString(@"SimServiceContext"),NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:"),@"/Applications/Xcode.app/Contents/Developer",&e);
  id set=((id(*)(id,SEL,NSError**))objc_msgSend)(ctx,NSSelectorFromString(@"defaultDeviceSetWithError:"),&e);
  id rt=nil, dt=nil;
  for(id r in ((id(*)(id,SEL))objc_msgSend)(ctx,NSSelectorFromString(@"supportedRuntimes"))){
    NSString*b=((id(*)(id,SEL))objc_msgSend)(r,NSSelectorFromString(@"buildVersionString"));
    if([b isEqualToString:@(argv[3])]) rt=r; }
  for(id t in ((id(*)(id,SEL))objc_msgSend)(ctx,NSSelectorFromString(@"supportedDeviceTypes"))){
    NSString*i=((id(*)(id,SEL))objc_msgSend)(t,NSSelectorFromString(@"identifier"));
    if([i isEqualToString:@(argv[2])]) dt=t; }
  if(!rt||!dt){ fprintf(stderr,"runtime %s or type %s not found\n",argv[3],argv[2]); return 1; }
  id d=((id(*)(id,SEL,id,id,NSString*,NSError**))objc_msgSend)(set,NSSelectorFromString(@"createDeviceWithType:runtime:name:error:"),dt,rt,@(argv[1]),&e);
  if(!d){ fprintf(stderr,"create failed: %s\n",e.description.UTF8String); return 1; }
  printf("%s\n",[((id(*)(id,SEL))objc_msgSend)(d,NSSelectorFromString(@"UDID")) UUIDString].UTF8String); return 0; } }
