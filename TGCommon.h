#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <WebKit/WebKit.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
#define TG_EXTERN extern "C"
#else
#define TG_EXTERN extern
#endif

#define SBLog(fmt, ...) NSLog(@"[TabGuard] " fmt, ##__VA_ARGS__)
