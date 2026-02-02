#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(ConversionService, NSObject)

RCT_EXTERN_METHOD(healthCheck:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(convertFile:(NSString *)inputPath
                  targetExt:(NSString *)targetExt
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

@end
