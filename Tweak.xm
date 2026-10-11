#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <WebKit/WebKit.h>
#import <UIKit/UIKit.h>

@interface BrowserController : NSObject
- (void)loadURLInNewTab:(NSURL*)url inBackground:(BOOL)inBackground animated:(BOOL)animated;
@end

#define SBLog(fmt, ...) NSLog(@"[TabGuard] " fmt, ##__VA_ARGS__)

//Store the preferences in Safari Home Directory to avoid sandbox issues
#define prefFilePath [NSString stringWithFormat:@"%@/Library/Preferences/com.qn.tabguard.plist", NSHomeDirectory()]

static NSMutableArray * blockedURLs;
static NSMutableArray * blockedDomains;
static NSMutableArray * allowedDomains;
static bool tweakEnabled = YES;
static bool showBlockedBanner = YES;
static NSTimeInterval bannerDuration = 6;

//Strip the scheme (or the "//" left by resourceSpecifier) and a leading "www."
static NSString* removeJunk(NSString* url)
{
  for (NSString* prefix in @[@"https://", @"http://", @"//"])
  {
    if ([url hasPrefix:prefix])
    {
      url = [url substringFromIndex:prefix.length];
      break;
    }
  }

  if ([url hasPrefix:@"www."])
    url = [url substringFromIndex:4];

  return url;
}

static NSString* normalizedHost(NSString* host)
{
  if (host.length == 0)
    return nil;

  return removeJunk(host.lowercaseString);
}

//How specific a matching entry is, the more specific side wins when a pop-up matches both the whitelist and
//a blocked list: blocked URL > exact domain > wildcard, longer wildcards before shorter ones
static const NSInteger SBSpecificityWildcard = 1000;
static const NSInteger SBSpecificityDomain = 2000;
static const NSInteger SBSpecificityURL = 3000;

//"example.com" only matches itself, "*.example.com" also covers every subdomain like "ads.example.com".
//Returns the most specific entry matching host, and its specificity (0 when nothing matched).
static NSString* bestEntryMatchingHost(NSString* host, NSArray* domains, NSInteger* specificity)
{
  NSString* best = nil;
  NSInteger bestScore = 0;

  for (NSString* entry in host ? domains : @[])
  {
    NSString* trimmed = [entry stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    BOOL wildcard = [trimmed hasPrefix:@"*."];
    NSString* domain = normalizedHost(wildcard ? [trimmed substringFromIndex:2] : trimmed);
    if (!domain)
      continue;

    NSInteger score = 0;
    if ([host isEqualToString:domain])
      score = wildcard ? SBSpecificityWildcard + domain.length : SBSpecificityDomain;
    else if (wildcard && [host hasSuffix:[@"." stringByAppendingString:domain]])
      score = SBSpecificityWildcard + domain.length;

    if (score > bestScore)
    {
      best = entry;
      bestScore = score;
    }
  }

  if (specificity)
    *specificity = bestScore;
  return best;
}

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

@implementation SBPopupRequest
@end

//"example.com/path" without scheme, www., query or fragment, so a saved entry still matches when tracking
//parameters change. Saved entries are matched as a prefix of the full address.
static NSString* addressWithoutQuery(NSURL* url)
{
  NSString* host = normalizedHost(url.host);
  if (!host)
    return nil;

  NSString* path = url.path.length > 1 ? url.path : @"";
  return [host stringByAppendingString:path];
}

static SBPopupRequest* popupRequestFor(WKWebView* webView, WKNavigationAction* action)
{
  SBPopupRequest* request = [SBPopupRequest new];

  request.pageDomain = normalizedHost(webView.URL.host);
  request.pageURLWithoutJunk = removeJunk(webView.URL.resourceSpecifier);
  request.pageAddress = addressWithoutQuery(webView.URL);

  WKFrameInfo* sourceFrame = action.sourceFrame;
  NSString* openerHost = sourceFrame.securityOrigin.host;
  if (openerHost.length == 0)
    openerHost = sourceFrame.request.URL.host;
  request.openerDomain = normalizedHost(openerHost) ?: request.pageDomain;

  NSURL* target = action.request.URL;
  NSString* scheme = target.scheme.lowercaseString;
  if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])
  {
    request.targetURL = target;
    request.targetURLWithoutJunk = removeJunk(target.resourceSpecifier);
    request.targetAddress = addressWithoutQuery(target);
    request.targetDomain = normalizedHost(target.host);
  }

  return request;
}

typedef NS_ENUM(NSInteger, SBPopupDecision)
{
  SBPopupAsk,
  SBPopupAllow,
  SBPopupBlocked
};

static SBPopupDecision decisionForPopup(SBPopupRequest* request)
{
  //Whitelist: pop-ups on these pages, or going to these domains (sign-in, payment)
  NSInteger pageAllowScore, targetAllowScore;
  bestEntryMatchingHost(request.pageDomain, allowedDomains, &pageAllowScore);
  bestEntryMatchingHost(request.targetDomain, allowedDomains, &targetAllowScore);
  NSInteger allowScore = MAX(pageAllowScore, targetAllowScore);

  //Blocked lists: the page, the frame that opened the pop-up, or where it goes
  NSInteger blockScore = 0;
  NSString* blockEntry = nil;
  NSString* blockListKey = nil;

  NSInteger score;
  NSString* entry;
  for (NSString* host in @[request.pageDomain ?: @"", request.openerDomain ?: @"", request.targetDomain ?: @""])
  {
    entry = bestEntryMatchingHost(host.length ? host : nil, blockedDomains, &score);
    if (score > blockScore)
    {
      blockScore = score;
      blockEntry = entry;
      blockListKey = @"blockedDomains";
    }
  }


  for (NSString* tempURL in blockedURLs)
  {
    NSString* blockedURL = removeJunk(tempURL);
    if (blockedURL.length && ([request.pageURLWithoutJunk hasPrefix:blockedURL] || [request.targetURLWithoutJunk hasPrefix:blockedURL]))
    {
      score = SBSpecificityURL + blockedURL.length;
      if (score > blockScore)
      {
        blockScore = score;
        blockEntry = tempURL;
        blockListKey = @"blockedURLs";
      }
    }
  }

  //Equally specific: blocking wins, blocked entries are deliberate while the whitelist has defaults
  if (blockScore > 0 && blockScore >= allowScore)
  {
    request.blockingEntry = blockEntry;
    request.blockingListKey = blockListKey;
    return SBPopupBlocked;
  }

  if (allowScore > 0)
    return SBPopupAllow;

  return SBPopupAsk;
}

static NSMutableArray* listForKey(NSString* key)
{
  if ([key isEqualToString:@"allowedDomains"])
    return allowedDomains;
  if ([key isEqualToString:@"blockedDomains"])
    return blockedDomains;
  if ([key isEqualToString:@"blockedURLs"])
    return blockedURLs;
  return nil;
}

//key is one of allowedDomains, blockedDomains, blockedURLs. A domain lives in one list only, adding it to the
//whitelist takes it off the blocked domains and the other way around.
static void editTabGuardList(NSString* key, NSString* entry, BOOL add)
{
  NSMutableArray* list = listForKey(key);
  if (!list || !entry || add == [list containsObject:entry])
    return;

  if (add)
    [list addObject:entry];
  else
    [list removeObject:entry];

  NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
  [defaults addEntriesFromDictionary:[NSDictionary dictionaryWithContentsOfFile:prefFilePath]];
  [defaults setObject:[list componentsJoinedByString:@";"] forKey:key];

  NSString* otherKey = [key isEqualToString:@"allowedDomains"] ? @"blockedDomains" : ([key isEqualToString:@"blockedDomains"] ? @"allowedDomains" : nil);
  NSMutableArray* otherList = listForKey(otherKey);
  if (add && [otherList containsObject:entry])
  {
    [otherList removeObject:entry];
    [defaults setObject:[otherList componentsJoinedByString:@";"] forKey:otherKey];
  }

  [defaults writeToFile:prefFilePath atomically:YES];
}

//The pop-up was already refused, opening it again is a plain new tab without window.opener
static void reopenPopup(id browserController, NSURL* targetURL)
{
  if (!targetURL)
    return;

  if ([browserController respondsToSelector:@selector(loadURLInNewTab:inBackground:animated:)])
    [browserController loadURLInNewTab:targetURL inBackground:NO animated:YES];
  else
    [[UIApplication sharedApplication] openURL:targetURL options:@{} completionHandler:nil];
}

//Reads a private property only when it exists, nil instead of an exception if Apple renames it
static id valueForKeyIfResponds(id object, NSString* key)
{
  if (!object || ![object respondsToSelector:NSSelectorFromString(key)])
    return nil;

  @try
  {
    return [object valueForKey:key];
  }
  @catch(NSException* ex)
  {
    SBLog(@"valueForKey:%@ failed: %@", key, ex.reason);
    return nil;
  }
}

static UIViewController* rootViewControllerForWebView(WKWebView* webView)
{
  UIWindow* window = webView.window;
  if (!window)
  {
    for (UIScene* scene in [UIApplication sharedApplication].connectedScenes)
    {
      if (![scene isKindOfClass:[UIWindowScene class]])
        continue;

      for (UIWindow* sceneWindow in ((UIWindowScene*)scene).windows)
      {
        if (sceneWindow.isKeyWindow)
          window = sceneWindow;
      }
    }
  }
  return window.rootViewController;
}

//UIButton is its own context menu delegate, overriding these is how to know when the menu is up
@interface SBMenuButton : UIButton
@property (nonatomic, copy) void (^menuVisibilityChanged)(BOOL visible);
@end

@implementation SBMenuButton

- (void)contextMenuInteraction:(UIContextMenuInteraction*)interaction willDisplayMenuForConfiguration:(UIContextMenuConfiguration*)configuration animator:(id<UIContextMenuInteractionAnimating>)animator
{
  [super contextMenuInteraction:interaction willDisplayMenuForConfiguration:configuration animator:animator];
  if (self.menuVisibilityChanged)
    self.menuVisibilityChanged(YES);
}

- (void)contextMenuInteraction:(UIContextMenuInteraction*)interaction willEndForConfiguration:(UIContextMenuConfiguration*)configuration animator:(id<UIContextMenuInteractionAnimating>)animator
{
  [super contextMenuInteraction:interaction willEndForConfiguration:configuration animator:animator];
  if (self.menuVisibilityChanged)
    self.menuVisibilityChanged(NO);
}

@end

//Non-blocking bar above Safari's toolbar, for pop-ups the user is asked about and (when enabled) ones
//blocked by the lists. Pop-ups from the same page are counted in one banner, "Allow Once" opens the
//most recent one. Stays up for bannerDuration, restarted by every new pop-up and paused while the menu is open.
@interface SBPopupBanner : UIView
@property (nonatomic, assign) NSInteger count;
@property (nonatomic, strong) SBPopupRequest* latestRequest;
@property (nonatomic, weak) id browserController;
@property (nonatomic, strong) UILabel* titleLabel;
@property (nonatomic, strong) UILabel* subtitleLabel;
@property (nonatomic, strong) UIButton* allowButton;
@property (nonatomic, strong) SBMenuButton* moreButton;
@property (nonatomic, strong) UIVisualEffectView* background;
@property (nonatomic, strong) NSLayoutConstraint* bottomConstraint;
@property (nonatomic, strong) NSTimer* hideTimer;
@property (nonatomic, assign) BOOL menuVisible;
@end

static __weak SBPopupBanner* visibleBanner;

//Safari's bottom bars (toolbar, the iOS 15+ capsule address bar) have moved between classes and
//properties across versions, so look for them by class name instead of private keys
static BOOL isBottomBarCandidate(UIView* view)
{
  NSString* name = NSStringFromClass([view class]);
  return [name rangeOfString:@"Capsule"].location != NSNotFound
      || [name rangeOfString:@"Toolbar"].location != NSNotFound
      || [name rangeOfString:@"NavigationBar"].location != NSNotFound;
}

static void collectBottomBars(UIView* view, UIView* host, NSInteger depth, CGFloat* limit, NSMutableArray<NSString*>* found)
{
  if (depth > 15 || view.hidden || view.alpha < 0.01 || [view isKindOfClass:[WKWebView class]] || [view isKindOfClass:[SBPopupBanner class]])
    return;

  if (isBottomBarCandidate(view))
  {
    CGRect frame = [view convertRect:view.bounds toView:host];
    if (CGRectGetHeight(frame) > 0 && CGRectGetMinY(frame) > CGRectGetMidY(host.bounds) && CGRectGetMinY(frame) < *limit)
    {
      *limit = CGRectGetMinY(frame);
      [found addObject:[NSString stringWithFormat:@"%@ y=%.0f", NSStringFromClass([view class]), CGRectGetMinY(frame)]];
    }
  }

  for (UIView* subview in view.subviews)
    collectBottomBars(subview, host, depth + 1, limit, found);
}

//Top edge of Safari's bottom bars, so the banner never covers them
static CGFloat bottomBarsTop(UIView* host)
{
  CGFloat limit = CGRectGetMaxY(host.bounds) - host.safeAreaInsets.bottom;
  NSMutableArray<NSString*>* found = [NSMutableArray array];
  collectBottomBars(host, host, 0, &limit, found);
  SBLog(@"banner above y=%.0f, bottom bars: %@", limit, found.count ? [found componentsJoinedByString:@", "] : @"none");
  return limit;
}

@implementation SBPopupBanner

+ (void)showForRequest:(SBPopupRequest*)request inViewController:(UIViewController*)rootVC browserController:(id)browserController
{
  UIView* host = rootVC.view;
  SBPopupBanner* banner = visibleBanner;
  if (banner && banner.superview != host)
  {
    [banner removeFromSuperview];
    banner = nil;
  }

  NSString* bannerDomain = banner.latestRequest.pageDomain;
  BOOL samePage = banner && (bannerDomain == request.pageDomain || [bannerDomain isEqualToString:request.pageDomain]);
  BOOL isNew = !banner;
  if (isNew)
  {
    banner = [[SBPopupBanner alloc] initWithHost:host];
    visibleBanner = banner;
  }

  banner.count = samePage ? banner.count + 1 : 1;
  banner.latestRequest = request;
  banner.browserController = browserController;
  [banner refresh];

  [host bringSubviewToFront:banner];
  banner.bottomConstraint.constant = bottomBarsTop(host) - 10;
  [host layoutIfNeeded];

  if (isNew)
  {
    [[NSNotificationCenter defaultCenter] addObserver:banner selector:@selector(orientationDidChange) name:UIDeviceOrientationDidChangeNotification object:nil];

    banner.alpha = 0;
    banner.transform = CGAffineTransformMakeTranslation(0, 20);
    [UIView animateWithDuration:0.25 animations:^{
      banner.alpha = 1;
      banner.transform = CGAffineTransformIdentity;
    }];
  }

  [banner restartTimer];
}

- (instancetype)initWithHost:(UIView*)host
{
  self = [super initWithFrame:CGRectZero];
  if (!self)
    return nil;

  self.translatesAutoresizingMaskIntoConstraints = NO;
  //A blur alone takes its color from the page: near invisible on white pages, too see-through on dark ones.
  //A thick blur under a mostly opaque fill, a hairline border and a shadow keep it readable on any page.
  self.layer.shadowColor = [UIColor blackColor].CGColor;
  self.layer.shadowOpacity = 0.2;
  self.layer.shadowRadius = 12;
  self.layer.shadowOffset = CGSizeMake(0, 4);

  UIVisualEffectView* background = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterial]];
  background.translatesAutoresizingMaskIntoConstraints = NO;
  background.layer.cornerRadius = 16;
  background.layer.cornerCurve = kCACornerCurveContinuous;
  background.layer.borderWidth = 0.5;
  background.clipsToBounds = YES;
  background.contentView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor*(UITraitCollection* traits) {
    UIColor* fill = traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor tertiarySystemBackgroundColor] : [UIColor secondarySystemBackgroundColor];
    return [[fill resolvedColorWithTraitCollection:traits] colorWithAlphaComponent:0.85];
  }];
  self.background = background;
  [self addSubview:background];
  [self updateBorderColor];

  UIImageView* icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"hand.raised.fill"]];
  icon.tintColor = [UIColor systemRedColor];
  icon.contentMode = UIViewContentModeScaleAspectFit;
  [icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

  self.titleLabel = [UILabel new];
  self.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
  self.titleLabel.font = [UIFont systemFontOfSize:self.titleLabel.font.pointSize weight:UIFontWeightSemibold];
  self.subtitleLabel = [UILabel new];
  self.subtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
  self.subtitleLabel.textColor = [UIColor secondaryLabelColor];
  self.subtitleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

  UIStackView* labels = [[UIStackView alloc] initWithArrangedSubviews:@[self.titleLabel, self.subtitleLabel]];
  labels.axis = UILayoutConstraintAxisVertical;
  labels.spacing = 1;
  //The labels take the spare width and truncate first, the buttons stay at their natural size
  [labels setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
  [labels setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

  __weak SBPopupBanner* weakSelf = self;

  UIButtonConfiguration* allowConfig = [UIButtonConfiguration tintedButtonConfiguration];
  allowConfig.title = @"Allow Once";
  allowConfig.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
  allowConfig.buttonSize = UIButtonConfigurationSizeSmall;
  self.allowButton = [UIButton buttonWithConfiguration:allowConfig primaryAction:[UIAction actionWithHandler:^(UIAction* action) {
    [weakSelf allowOnce];
  }]];
  [self.allowButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  [self.allowButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

  self.moreButton = [SBMenuButton buttonWithType:UIButtonTypeSystem];
  [self.moreButton setImage:[UIImage systemImageNamed:@"ellipsis.circle"] forState:UIControlStateNormal];
  self.moreButton.showsMenuAsPrimaryAction = YES;
  //Keep the order as written, otherwise iOS reverses it when the menu opens upwards
  self.moreButton.preferredMenuElementOrder = UIContextMenuConfigurationElementOrderFixed;
  [self.moreButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  [self.moreButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  self.moreButton.menuVisibilityChanged = ^(BOOL visible) {
    weakSelf.menuVisible = visible;
    [weakSelf restartTimer];
  };

  UIStackView* row = [[UIStackView alloc] initWithArrangedSubviews:@[icon, labels, self.allowButton, self.moreButton]];
  row.alignment = UIStackViewAlignmentCenter;
  row.spacing = 10;
  row.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:row];

  UISwipeGestureRecognizer* swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(dismiss)];
  swipe.direction = UISwipeGestureRecognizerDirectionDown;
  [self addGestureRecognizer:swipe];

  [host addSubview:self];

  NSLayoutConstraint* fullWidth = [self.widthAnchor constraintEqualToAnchor:host.widthAnchor constant:-20];
  fullWidth.priority = UILayoutPriorityDefaultHigh;
  self.bottomConstraint = [self.bottomAnchor constraintEqualToAnchor:host.topAnchor];

  [NSLayoutConstraint activateConstraints:@[
    [background.topAnchor constraintEqualToAnchor:self.topAnchor],
    [background.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    [background.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [background.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [row.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
    [row.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-10],
    [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
    [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
    [icon.widthAnchor constraintEqualToConstant:22],
    [self.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
    [self.widthAnchor constraintLessThanOrEqualToConstant:500],
    fullWidth,
    self.bottomConstraint,
  ]];

  return self;
}

//CGColor borders don't follow light/dark mode by themselves
- (void)updateBorderColor
{
  self.background.layer.borderColor = [[UIColor separatorColor] resolvedColorWithTraitCollection:self.traitCollection].CGColor;
}

- (void)traitCollectionDidChange:(UITraitCollection*)previousTraitCollection
{
  [super traitCollectionDidChange:previousTraitCollection];
  [self updateBorderColor];
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:16].CGPath;
}

- (void)refresh
{
  NSString* domain = self.latestRequest.pageDomain;
  self.titleLabel.text = self.count > 1 ? [NSString stringWithFormat:@"%ld pop-ups blocked", (long)self.count] : @"Pop-up blocked";
  self.subtitleLabel.text = domain ? [@"on " stringByAppendingString:domain] : nil;
  self.subtitleLabel.hidden = !domain;

  //A blank pop-up only has content because the opener writes into it, there is nothing to open again
  self.allowButton.hidden = !self.latestRequest.targetURL;

  __weak SBPopupBanner* weakSelf = self;

  //Blocked by a list: offer to take that entry off the list, later pop-ups are asked about again
  NSString* entry = self.latestRequest.blockingEntry;
  if (entry)
  {
    NSString* key = self.latestRequest.blockingListKey;
    UIAction* unblock = [UIAction actionWithTitle:@"Remove from Blocked List" image:[UIImage systemImageNamed:@"minus.circle"] identifier:nil handler:^(UIAction* action) {
      editTabGuardList(key, entry, NO);
      [weakSelf dismiss];
    }];

    self.moreButton.hidden = NO;
    self.moreButton.menu = [UIMenu menuWithTitle:entry children:@[unblock]];
    return;
  }

  self.moreButton.hidden = !domain;
  if (!domain)
    return;

  UIAction* whitelist = [UIAction actionWithTitle:@"Always Allow Pop-ups on This Site" image:[UIImage systemImageNamed:@"checkmark.shield"] identifier:nil handler:^(UIAction* action) {
    editTabGuardList(@"allowedDomains", domain, YES);
    [weakSelf allowOnce];
  }];

  NSMutableArray<UIMenuElement*>* blockChoices = [NSMutableArray array];
  UIAction* blockSite = [UIAction actionWithTitle:@"Whole Site" image:nil identifier:nil handler:^(UIAction* action) {
    editTabGuardList(@"blockedDomains", domain, YES);
    [weakSelf dismiss];
  }];
  [blockChoices addObject:blockSite];

  NSString* pageAddress = self.latestRequest.pageAddress;
  if (pageAddress && ![pageAddress isEqualToString:domain])
  {
    UIAction* blockPage = [UIAction actionWithTitle:@"This Page Only" image:nil identifier:nil handler:^(UIAction* action) {
      editTabGuardList(@"blockedURLs", pageAddress, YES);
      [weakSelf dismiss];
    }];
    [blockChoices addObject:blockPage];
  }

  NSString* targetAddress = self.latestRequest.targetAddress;
  if (targetAddress)
  {
    UIAction* blockLink = [UIAction actionWithTitle:@"This Pop-up Link" image:nil identifier:nil handler:^(UIAction* action) {
      editTabGuardList(@"blockedURLs", targetAddress, YES);
      [weakSelf dismiss];
    }];
    [blockChoices addObject:blockLink];
  }

  for (UIAction* choice in blockChoices)
    choice.attributes = UIMenuElementAttributesDestructive;

  UIMenu* block = [UIMenu menuWithTitle:@"Block Pop-ups Silently" image:[UIImage systemImageNamed:@"nosign"] identifier:nil options:0 children:blockChoices];

  self.moreButton.menu = [UIMenu menuWithTitle:domain children:@[whitelist, block]];
}

//Safari moves its bars when the device rotates (bottom bars on iPhone portrait, top bar in landscape)
- (void)orientationDidChange
{
  __weak SBPopupBanner* weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    SBPopupBanner* banner = weakSelf;
    UIView* host = banner.superview;
    if (!host)
      return;

    banner.bottomConstraint.constant = bottomBarsTop(host) - 10;
    [UIView animateWithDuration:0.2 animations:^{
      [host layoutIfNeeded];
    }];
  });
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)allowOnce
{
  reopenPopup(self.browserController, self.latestRequest.targetURL);
  [self dismiss];
}

- (void)restartTimer
{
  [self.hideTimer invalidate];
  self.hideTimer = nil;
  if (self.menuVisible)
    return;

  __weak SBPopupBanner* weakSelf = self;
  self.hideTimer = [NSTimer scheduledTimerWithTimeInterval:bannerDuration repeats:NO block:^(NSTimer* timer) {
    [weakSelf dismiss];
  }];
}

- (void)dismiss
{
  [self.hideTimer invalidate];
  self.hideTimer = nil;
  if (visibleBanner == self)
    visibleBanner = nil;

  [UIView animateWithDuration:0.2 animations:^{
    self.alpha = 0;
    self.transform = CGAffineTransformMakeTranslation(0, 20);
  } completion:^(BOOL finished) {
    [self removeFromSuperview];
  }];
}

@end

//Returns YES when the pop-up may be created. Otherwise it was refused and the banner is already shown if needed.
static BOOL shouldCreatePopup(id uiDelegate, WKWebView* webView, WKNavigationAction* navigationAction)
{
  if (!tweakEnabled)
    return YES;

  SBPopupRequest* request = popupRequestFor(webView, navigationAction);
  SBPopupDecision decision = decisionForPopup(request);

  SBLog(@"pop-up page=%@ opener=%@ target=%@ decision=%ld", request.pageDomain, request.openerDomain, request.targetURL, (long)decision);

  if (decision == SBPopupAllow)
    return YES;

  UIViewController* rootVC = rootViewControllerForWebView(webView);
  id browserController = valueForKeyIfResponds(uiDelegate, @"browserController") ?: valueForKeyIfResponds(rootVC, @"browserController");

  BOOL ask = decision == SBPopupAsk;
  if (!rootVC.view)
  {
    SBLog(@"no view to show the banner in");
    return ask;
  }

  if (ask || showBlockedBanner)
    [SBPopupBanner showForRequest:request inViewController:rootVC browserController:browserController];
  return NO;
}

//Every pop-up from web content (window.open, target="_blank", form targets) asks the web view's UI delegate
//for a new web view, before anything is created or loaded. Refusing it there means no tab, no request,
//no History entry, and window.open() returns null to the page. Tabs the user opens from Safari's own UI
//(long press, "Open in New Tab", other tweaks calling loadURLInNewTab) never come through here.
//
//Which class is the UI delegate differs between Safari versions, and WebKit prefers the private async
//variant when the delegate has it, so both are hooked on whatever class Safari actually sets.
typedef WKWebView* (*SBCreateWebViewIMP)(id, SEL, WKWebView*, WKWebViewConfiguration*, WKNavigationAction*, WKWindowFeatures*);
typedef void (*SBCreateWebViewAsyncIMP)(id, SEL, WKWebView*, WKWebViewConfiguration*, WKNavigationAction*, WKWindowFeatures*, void (^)(WKWebView*));

static NSMutableSet<NSString*>* hookedMethods;

//The class that actually implements sel, hooking a subclass that only inherits it would hook it twice
static Class definingClassForSelector(Class cls, SEL sel)
{
  Method method = class_getInstanceMethod(cls, sel);
  if (!method)
    return nil;

  Class owner = cls;
  while (class_getSuperclass(owner) && class_getInstanceMethod(class_getSuperclass(owner), sel) == method)
    owner = class_getSuperclass(owner);
  return owner;
}

static Method methodToHook(Class cls, SEL sel)
{
  Class owner = definingClassForSelector(cls, sel);
  if (!owner)
    return NULL;

  NSString* key = [NSString stringWithFormat:@"%s %@", class_getName(owner), NSStringFromSelector(sel)];
  if ([hookedMethods containsObject:key])
    return NULL;

  [hookedMethods addObject:key];
  SBLog(@"hooking -[%s %@]", class_getName(owner), NSStringFromSelector(sel));
  return class_getInstanceMethod(owner, sel);
}

static void hookUIDelegateClass(Class cls)
{
  SEL syncSel = @selector(webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:);
  Method syncMethod = methodToHook(cls, syncSel);
  if (syncMethod)
  {
    SBCreateWebViewIMP orig = (SBCreateWebViewIMP)method_getImplementation(syncMethod);
    method_setImplementation(syncMethod, imp_implementationWithBlock(^WKWebView*(id delegate, WKWebView* webView, WKWebViewConfiguration* configuration, WKNavigationAction* navigationAction, WKWindowFeatures* windowFeatures) {
      if (!shouldCreatePopup(delegate, webView, navigationAction))
        return nil;

      return orig(delegate, syncSel, webView, configuration, navigationAction, windowFeatures);
    }));
  }

  SEL asyncSel = NSSelectorFromString(@"_webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:completionHandler:");
  Method asyncMethod = methodToHook(cls, asyncSel);
  if (asyncMethod)
  {
    SBCreateWebViewAsyncIMP orig = (SBCreateWebViewAsyncIMP)method_getImplementation(asyncMethod);
    method_setImplementation(asyncMethod, imp_implementationWithBlock(^(id delegate, WKWebView* webView, WKWebViewConfiguration* configuration, WKNavigationAction* navigationAction, WKWindowFeatures* windowFeatures, void (^completionHandler)(WKWebView*)) {
      if (!shouldCreatePopup(delegate, webView, navigationAction))
      {
        completionHandler(nil);
        return;
      }

      orig(delegate, asyncSel, webView, configuration, navigationAction, windowFeatures, completionHandler);
    }));
  }
}

%hook WKWebView

- (void)setUIDelegate:(id<WKUIDelegate>)UIDelegate
{
  if (UIDelegate)
    hookUIDelegateClass(object_getClass(UIDelegate));

  %orig;
}

%end

//Pref lists are stored as ";" separated strings, ignore anything that isn't a string
static NSMutableArray* listPref(NSDictionary* prefs, NSString* key)
{
  id value = prefs[key];
  NSMutableArray* list = [([value isKindOfClass:[NSString class]] ? [value componentsSeparatedByString:@";"] : @[]) mutableCopy];
  [list removeObject:@""];
  return list;
}

//Sites with legitimate pop-ups (sign-in, payment, docs). Added to the user's whitelist once, so they
//show up in settings and stay deleted if the user removes them.
static NSArray* defaultAllowedDomains()
{
  return @[
    @"*.google.com",
    @"*.youtube.com",
    @"*.apple.com",
    @"*.icloud.com",
    @"*.microsoft.com",
    @"*.microsoftonline.com",
    @"*.live.com",
    @"*.office.com",
    @"*.github.com",
    @"*.wikipedia.org",
    @"*.facebook.com",
    @"*.paypal.com",
    @"*.stripe.com",
  ];
}

static void addDefaultAllowedDomainsOnce(NSMutableDictionary* prefs)
{
  if ([[prefs objectForKey:@"addedDefaultAllowedDomains"] boolValue])
    return;

  NSMutableArray* domains = listPref(prefs, @"allowedDomains");
  for (NSString* domain in defaultAllowedDomains())
  {
    if (![domains containsObject:domain])
      [domains addObject:domain];
  }

  [prefs setObject:[domains componentsJoinedByString:@";"] forKey:@"allowedDomains"];
  [prefs setObject:@YES forKey:@"addedDefaultAllowedDomains"];
  [prefs writeToFile:prefFilePath atomically:YES];
}

static void updatePrefs()
{
  NSMutableDictionary* prefs = [[NSMutableDictionary alloc] initWithContentsOfFile:prefFilePath] ?: [NSMutableDictionary dictionary];
  addDefaultAllowedDomainsOnce(prefs);

  allowedDomains = listPref(prefs, @"allowedDomains");
  blockedDomains = listPref(prefs, @"blockedDomains");
  blockedURLs = listPref(prefs, @"blockedURLs");

  tweakEnabled = prefs[@"enabled"] ? [prefs[@"enabled"] boolValue] : YES;
  showBlockedBanner = prefs[@"showBlockedBanner"] ? [prefs[@"showBlockedBanner"] boolValue] : YES;
  id duration = prefs[@"bannerDuration"];
  bannerDuration = [duration respondsToSelector:@selector(doubleValue)] && [duration doubleValue] > 0 ? MIN(MAX([duration doubleValue], 1), 60) : 6;
}

//TabGuard was SafariBlocker (com.p2kdev.safariblocker), keep the user's lists and settings
static void migrateSafariBlockerPrefs()
{
  NSString* oldPath = [NSString stringWithFormat:@"%@/Library/Preferences/com.p2kdev.safariblocker.plist", NSHomeDirectory()];
  NSFileManager* fileManager = [NSFileManager defaultManager];
  if (![fileManager fileExistsAtPath:prefFilePath] && [fileManager fileExistsAtPath:oldPath])
    [fileManager copyItemAtPath:oldPath toPath:prefFilePath error:nil];
}

%ctor
{
  SBLog(@"loaded");
  hookedMethods = [NSMutableSet new];

  migrateSafariBlockerPrefs();
  CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)updatePrefs, CFSTR("com.qn.tabguard.settingschanged"), NULL, CFNotificationSuspensionBehaviorCoalesce);
  updatePrefs();

  %init;
}
