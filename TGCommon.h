#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <WebKit/WebKit.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
#define TG_EXTERN extern "C"
#else
#define TG_EXTERN extern
#endif

//Logging only exists in debug builds (make TABGUARD_DEBUG=1), release builds don't log pop-up URLs
#if TG_DEBUG
#define TGLog(fmt, ...) NSLog(@"[TabGuard] " fmt, ##__VA_ARGS__)
#else
#define TGLog(fmt, ...) ((void)0)
#endif
