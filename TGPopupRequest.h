#import "TGCommon.h"

//Everything known about a pop-up at the moment WebKit asks Safari for a new window
@interface SBPopupRequest : NSObject
//The page in the tab that opens the pop-up
@property (nonatomic, copy) NSString* pageDomain;
@property (nonatomic, copy) NSString* pageURLWithoutJunk;
//Host and path only, what the "block this page" menu item saves
@property (nonatomic, copy) NSString* pageAddress;
//The frame that actually called window.open / owns the link, often an ad iframe
@property (nonatomic, copy) NSString* openerDomain;
//Where the pop-up wants to go, nil for about:blank pop-ups that get written by script
@property (nonatomic, strong) NSURL* targetURL;
@property (nonatomic, copy) NSString* targetURLWithoutJunk;
@property (nonatomic, copy) NSString* targetAddress;
@property (nonatomic, copy) NSString* targetDomain;
//The blocked list entry that refused this pop-up, nil when it wasn't blocked by a list
@property (nonatomic, copy) NSString* blockingEntry;
@property (nonatomic, copy) NSString* blockingListKey;
@end

typedef NS_ENUM(NSInteger, SBPopupDecision)
{
  SBPopupAsk,
  SBPopupAllow,
  SBPopupBlocked
};

TG_EXTERN SBPopupRequest* popupRequestFor(WKWebView* webView, WKNavigationAction* action);
TG_EXTERN SBPopupDecision decisionForPopup(SBPopupRequest* request);
