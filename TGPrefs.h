#import "TGCommon.h"

TG_EXTERN NSMutableArray* blockedURLs;
TG_EXTERN NSMutableArray* blockedDomains;
TG_EXTERN NSMutableArray* allowedDomains;
TG_EXTERN bool tweakEnabled;
TG_EXTERN bool showBlockedBanner;
TG_EXTERN NSTimeInterval bannerDuration;

TG_EXTERN void editTabGuardList(NSString* key, NSString* entry, BOOL add);
TG_EXTERN void updatePrefs(void);
TG_EXTERN void migrateSafariBlockerPrefs(void);
