#import "TGPopupBanner.h"
#import "TGPrefs.h"

@interface BrowserController : NSObject
- (id)loadURLInNewTab:(NSURL*)url inBackground:(BOOL)inBackground animated:(BOOL)animated;
@end

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

//UIButton is its own context menu delegate, overriding these is how to know when the menu is up
@interface SBMenuButton : UIButton
@property (nonatomic, copy) void (^menuVisibilityChanged)(BOOL visible);
@end

@implementation SBMenuButton

- (void)contextMenuInteraction:(UIContextMenuInteraction*)interaction willDisplayMenuForConfiguration:(UIContextMenuConfiguration*)configuration animator:(id<UIContextMenuInteractionAnimating>)animator
{
  if ([UIButton instancesRespondToSelector:_cmd])
    [super contextMenuInteraction:interaction willDisplayMenuForConfiguration:configuration animator:animator];
  if (self.menuVisibilityChanged)
    self.menuVisibilityChanged(YES);
}

- (void)contextMenuInteraction:(UIContextMenuInteraction*)interaction willEndForConfiguration:(UIContextMenuConfiguration*)configuration animator:(id<UIContextMenuInteractionAnimating>)animator
{
  if ([UIButton instancesRespondToSelector:_cmd])
    [super contextMenuInteraction:interaction willEndForConfiguration:configuration animator:animator];
  if (self.menuVisibilityChanged)
    self.menuVisibilityChanged(NO);
}

@end

@interface SBPopupBanner ()
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
  //Keep the order as written, otherwise iOS reverses it when the menu opens upwards (iOS 16+, iOS 15 reverses it)
  if (@available(iOS 16.0, *))
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
