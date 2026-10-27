#import "TGCommon.h"
#import "TGPopupRequest.h"

//Non-blocking bar above Safari's toolbar, for pop-ups the user is asked about and (when enabled) ones
//blocked by the lists. Pop-ups from the same page are counted in one banner, "Allow Once" opens the
//most recent one. Stays up for bannerDuration, restarted by every new pop-up and paused while the menu is open.
@interface SBPopupBanner : UIView
+ (void)showForRequest:(SBPopupRequest*)request inViewController:(UIViewController*)rootVC browserController:(id)browserController;
@end
