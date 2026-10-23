#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <unistd.h>
#include <fcntl.h>
#ifndef HELPER
#define HELPER 0
#endif
#ifndef BOOTSTRAP_AUTH
#define BOOTSTRAP_AUTH 0
#endif
#ifndef PARENT_VERSION
#define PARENT_VERSION 0
#endif
#ifndef PARENT_REQ
#define PARENT_REQ @""
#endif
#ifndef EVENT_PATH
#define EVENT_PATH @"/tmp/unused"
#endif
@protocol ProofMutation
- (void)ping:(NSData *)nonce version:(NSInteger)version reply:(void (^)(NSData *nonce, NSInteger version))reply;
- (void)mutate:(NSData *)payload reply:(void (^)(NSInteger count, NSData *echo))reply;
@end
@protocol ProofBroker
- (void)connectWithReply:(void (^)(NSXPCListenerEndpoint *endpoint))reply;
@end
static void event(NSString *kind, pid_t peer, NSInteger count) {
    NSDictionary *entry = @{ @"event":kind, @"peer":@(peer), @"helper":@(getpid()), @"count":@(count) };
    NSData *data = [NSJSONSerialization dataWithJSONObject:entry options:0 error:NULL];
    NSMutableData *line = [data mutableCopy]; [line appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    int fd = open([EVENT_PATH fileSystemRepresentation], O_WRONLY|O_CREAT|O_APPEND|O_CLOEXEC, 0600);
    if(fd >= 0) { write(fd, line.bytes, line.length); close(fd); }
}
@interface Mutation : NSObject <ProofMutation>
@property NSInteger count;
@property BOOL authenticated;
@end
@implementation Mutation
- (void)ping:(NSData *)nonce version:(NSInteger)version reply:(void (^)(NSData *,NSInteger))reply {
    NSXPCConnection *c=NSXPCConnection.currentConnection;
    event(@"authenticated_handshake",c.processIdentifier,0);
    if (c.effectiveUserIdentifier!=getuid() || nonce.length!=32 || version!=1) { [c invalidate]; return; }
    self.authenticated=YES;
    NSString *mode=[NSBundle.mainBundle objectForInfoDictionaryKey:@"XPCProofReplyMode"];
    NSData *response=[mode isEqualToString:@"bad_nonce"] ? [NSMutableData dataWithLength:32] : nonce;
    reply(response,[mode isEqualToString:@"bad_version"] ? 2 : 1);
}
- (void)mutate:(NSData *)payload reply:(void (^)(NSInteger,NSData *))reply {
    NSXPCConnection *c = NSXPCConnection.currentConnection;
    if (!self.authenticated || c.effectiveUserIdentifier != getuid() || payload.length > 1024) { [c invalidate]; return; }
    self.count += 1; event(@"mutation",c.processIdentifier,self.count); event(@"synthetic_vault",c.processIdentifier,self.count); reply(self.count,payload);
}
@end
@interface AnonymousDelegate : NSObject <NSXPCListenerDelegate>
@property Mutation *mutation;
@end
@implementation AnonymousDelegate
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)c {
    event(@"anonymous_delegate", c.processIdentifier, 0);
    if (c.effectiveUserIdentifier != getuid()) return NO;
    [c setCodeSigningRequirement:PARENT_REQ];
    c.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(ProofMutation)];
    c.exportedObject = [Mutation new];
    [c resume]; return YES;
}
@end
@interface Broker : NSObject <ProofBroker>
@property NSXPCListener *anonymous;
@end
@implementation Broker
- (void)connectWithReply:(void (^)(NSXPCListenerEndpoint *))reply {
    event(@"broker",NSXPCConnection.currentConnection.processIdentifier,0);
    reply(self.anonymous.endpoint);
    // Only this disposable synthetic service; ensure no launchd fixture survives.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6*NSEC_PER_SEC)),dispatch_get_global_queue(QOS_CLASS_DEFAULT,0), ^{ exit(0); });
}
@end
@interface BootstrapDelegate : NSObject <NSXPCListenerDelegate>
@property Broker *broker;
@end
@implementation BootstrapDelegate
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)c {
    if(c.effectiveUserIdentifier != getuid()) return NO;
    // Read-only bootstrap distributes an endpoint only. Every mutation is on
    // the anonymous listener, authenticated before its delegate is consulted.
    if (BOOTSTRAP_AUTH) [c setCodeSigningRequirement:PARENT_REQ];
    c.exportedInterface=[NSXPCInterface interfaceWithProtocol:BOOTSTRAP_AUTH ? @protocol(ProofMutation) : @protocol(ProofBroker)];
    c.exportedObject=BOOTSTRAP_AUTH ? [Mutation new] : self.broker; [c resume]; return YES;
}
@end
int main(int argc, const char *argv[]) { @autoreleasepool {
    SecKeychainSetUserInteractionAllowed(false);
    if(HELPER) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6*NSEC_PER_SEC)),dispatch_get_global_queue(QOS_CLASS_DEFAULT,0), ^{ exit(0); });
        AnonymousDelegate *d=[AnonymousDelegate new]; d.mutation=[Mutation new];
        NSXPCListener *a=[NSXPCListener anonymousListener]; a.delegate=d;
        [a setConnectionCodeSigningRequirement:PARENT_REQ]; // macOS 13 public API.
        [a resume];
        Broker *b=[Broker new]; b.anonymous=a;
        BootstrapDelegate *bd=[BootstrapDelegate new]; bd.broker=b;
        NSXPCListener *service=[NSXPCListener serviceListener]; service.delegate=bd;
        [service resume];
        dispatch_main();
    } else {
        if(argc != 3) return 10;
        NSString *requirement=[NSString stringWithUTF8String:argv[1]];
        NSString *label=[NSString stringWithUTF8String:argv[2]];
        __block NSString *failure=nil; __block BOOL authenticated=NO; __block BOOL sameUID=NO; __block BOOL echoOK=NO; __block NSInteger counter=0;
        NSXPCConnection *bootstrap=[[NSXPCConnection alloc] initWithServiceName:@"net.mercen.agentswap.xpcproof.helper"];
        [bootstrap setCodeSigningRequirement:requirement];
        BOOL direct=[label hasPrefix:@"service_auth_"] || [label hasPrefix:@"bad_server_"] || [label hasPrefix:@"bad_reply_"];
        bootstrap.remoteObjectInterface=[NSXPCInterface interfaceWithProtocol:direct ? @protocol(ProofMutation) : @protocol(ProofBroker)];
        [bootstrap resume];
        NSXPCConnection *c=direct ? bootstrap : nil;
        NSXPCConnection *replacementProbe=nil;
        if(!direct) {
            __block NSXPCListenerEndpoint *endpoint=nil;
            dispatch_semaphore_t brokerDone=dispatch_semaphore_create(0);
            id<ProofBroker> broker=[bootstrap remoteObjectProxyWithErrorHandler:^(NSError *e){ failure=@"bootstrap_rejected"; dispatch_semaphore_signal(brokerDone); }];
            [broker connectWithReply:^(NSXPCListenerEndpoint *e){endpoint=e; dispatch_semaphore_signal(brokerDone);}];
            if(dispatch_semaphore_wait(brokerDone,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))) { failure=@"bootstrap_timeout"; [bootstrap invalidate]; }
            if(endpoint) {
                c=[[NSXPCConnection alloc] initWithListenerEndpoint:endpoint];
                [c setCodeSigningRequirement:requirement];
                c.remoteObjectInterface=[NSXPCInterface interfaceWithProtocol:@protocol(ProofMutation)];
                c.interruptionHandler=^{event(@"private_interrupted",getpid(),0);};
                c.invalidationHandler=^{event(@"private_invalidated",getpid(),0);};
                [c resume];
            }
        }
        if(c) {
            uint8_t random[32]; if(SecRandomCopyBytes(kSecRandomDefault,sizeof(random),random)) return 11;
            NSData *nonce=[NSData dataWithBytes:random length:sizeof(random)];
            dispatch_semaphore_t pingDone=dispatch_semaphore_create(0);
            id<ProofMutation> mutation=[c remoteObjectProxyWithErrorHandler:^(NSError *e){failure=direct ? @"service_rejected" : @"anonymous_rejected"; dispatch_semaphore_signal(pingDone);}];
            [mutation ping:nonce version:1 reply:^(NSData *response,NSInteger version){
                sameUID=(c.effectiveUserIdentifier==getuid()); authenticated=sameUID && version==1 && response.length==32 && [response isEqualToData:nonce];
                if(!authenticated) failure=@"handshake_rejected";
                dispatch_semaphore_signal(pingDone);
            }];
            if(dispatch_semaphore_wait(pingDone,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))) { failure=@"ping_timeout"; [c invalidate]; }
            BOOL swapped=[label hasPrefix:@"endpoint_swap_"];
            if(swapped && authenticated) {
                event(@"parent_ready_for_swap",getpid(),0);
                NSString *gate=[EVENT_PATH stringByAppendingFormat:@".gate-%@",label];
                NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:10];
                while(![NSFileManager.defaultManager fileExistsAtPath:gate] && deadline.timeIntervalSinceNow>0) usleep(10000);
                if(![NSFileManager.defaultManager fileExistsAtPath:gate]) return 12;
                // Force a fresh harmless service lookup while retaining the
                // original broker and original anonymous credential channel.
                replacementProbe=[[NSXPCConnection alloc] initWithServiceName:@"net.mercen.agentswap.xpcproof.helper"];
                [replacementProbe setCodeSigningRequirement:requirement];
                replacementProbe.remoteObjectInterface=[NSXPCInterface interfaceWithProtocol:@protocol(ProofBroker)]; [replacementProbe resume];
                dispatch_semaphore_t probeDone=dispatch_semaphore_create(0);
                id<ProofBroker> probe=[replacementProbe remoteObjectProxyWithErrorHandler:^(NSError *e){event(@"broker_reconnect_rejected",getpid(),0); dispatch_semaphore_signal(probeDone);}];
                [probe connectWithReply:^(NSXPCListenerEndpoint *unused){event(@"unexpected_new_endpoint",getpid(),0); dispatch_semaphore_signal(probeDone);}];
                if(dispatch_semaphore_wait(probeDone,dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC))) event(@"broker_reconnect_timeout",getpid(),0);
                event(@"private_execute_attempt",getpid(),0);
            }
            // No credential-like payload is constructed or sent before this gate.
            if(authenticated && sameUID) {
                NSData *payload=[@"synthetic-echo" dataUsingEncoding:NSUTF8StringEncoding];
                dispatch_semaphore_t executeDone=dispatch_semaphore_create(0);
                id<ProofMutation> executor=[c remoteObjectProxyWithErrorHandler:^(NSError *e){failure=direct ? @"service_rejected" : @"anonymous_rejected"; dispatch_semaphore_signal(executeDone);}];
                [executor mutate:payload reply:^(NSInteger count,NSData *echo){echoOK=[echo isEqualToData:payload]; counter=count; dispatch_semaphore_signal(executeDone);}];
                if(dispatch_semaphore_wait(executeDone,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))) { failure=@"private_execute_timeout"; [c invalidate]; }
            }
        }
        NSDictionary *result=@{@"label":label,@"parent_version":@(PARENT_VERSION),@"pid":@(getpid()),@"echo":@(echoOK),@"authenticated_handshake":@(authenticated),@"helper_same_uid":@(sameUID),@"counter":@(counter),@"outcome":failure?:@"accepted"};
        NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
        fwrite(data.bytes,1,data.length,stdout); puts(""); fflush(stdout);
        [c invalidate]; [bootstrap invalidate]; [replacementProbe invalidate];
        return 0;
    }
} }
