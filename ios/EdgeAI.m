#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>
#import <React/RCTViewManager.h>

@interface RCT_EXTERN_MODULE(EdgeAI, RCTEventEmitter)

RCT_EXTERN_METHOD(generate:(NSString *)prompt
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(resolveRequest:(NSString *)requestId
                  text:(NSString *)text)

RCT_EXTERN_METHOD(rejectRequest:(NSString *)requestId
                  code:(NSString *)code
                  message:(NSString *)message)

@end

@interface RCT_EXTERN_MODULE(NativeChatViewManager, RCTViewManager)

@end
