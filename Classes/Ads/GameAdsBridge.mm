//
//  GameAdsBridge.mm
//  激励（+1 击球次数）/ 横幅 / 设置页 / 中文日志
//

#import "GameAdsBridge.h"
#import "TPAdManager.h"
#import "TPAdSessionLog.h"
#import "UnityAppController.h"
#import "Unity/UnityInterface.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

static NSString * const kGameAdsLog = @"[广告]";
static NSString * const kSoundPrefKey = @"pool_sfx_enabled";
static NSString * const kGameDisplayName = @"Pool Game-Shooting Billiards";
static NSString * const kSupportEmail = @"Ljy18011962920@163.com";

#pragma mark - Helpers

/// 主游戏 UIWindow（设置页等仍挂这里；关卡内热区/弹窗改用独立高层级窗口）。
static UIWindow *GameAds_KeyWindow(void)
{
    UnityAppController *ctrl = GetAppController();
    if (ctrl.window)
    {
        return ctrl.window;
    }
    UIWindow *key = UIApplication.sharedApplication.keyWindow;
    if (key)
    {
        return key;
    }
    for (UIWindow *w in UIApplication.sharedApplication.windows)
    {
        if (w.isKeyWindow)
        {
            return w;
        }
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

static UIView *GameAds_HostView(void)
{
    return GameAds_KeyWindow();
}

/// 独立 overlay 窗口：不 makeKey，避免抢走 Unity；层级高于游戏窗以接收点击。
static UIWindow *GameAds_MakeOverlayWindow(CGRect screenFrame)
{
    UIWindow *key = GameAds_KeyWindow();
    UIWindow *win = nil;
    if (@available(iOS 13.0, *))
    {
        UIWindowScene *scene = key.windowScene;
        if (scene)
        {
            win = [[UIWindow alloc] initWithWindowScene:scene];
        }
    }
    if (!win)
    {
        win = [[UIWindow alloc] initWithFrame:screenFrame];
    }
    win.frame = screenFrame;
    win.windowLevel = UIWindowLevelAlert - 1.0;
    win.backgroundColor = [UIColor clearColor];
    win.opaque = NO;
    win.userInteractionEnabled = YES;
    win.hidden = NO;
    return win;
}

static UIEdgeInsets GameAds_SafeInsets(UIView *view)
{
    if (!view)
    {
        return UIEdgeInsetsZero;
    }
    if (@available(iOS 11.0, *))
    {
        UIEdgeInsets insets = view.safeAreaInsets;
        if (UIEdgeInsetsEqualToEdgeInsets(insets, UIEdgeInsetsZero))
        {
            UIWindow *win = view.window ?: (UIWindow *)([view isKindOfClass:[UIWindow class]] ? view : nil);
            if (win)
            {
                insets = win.safeAreaInsets;
            }
        }
        return insets;
    }
    return UIEdgeInsetsZero;
}

/// 弹层内容约束在安全区内，避免刘海 / 圆角 / Home Indicator 遮挡
static void GameAds_PinPanelInSafeArea(UIView *panel, UIView *overlay, CGFloat margin, CGFloat maxWidth)
{
    UILayoutGuide *guide = overlay.layoutMarginsGuide;
    if (@available(iOS 11.0, *))
    {
        guide = overlay.safeAreaLayoutGuide;
    }
    NSLayoutConstraint *widthCap = [panel.widthAnchor constraintLessThanOrEqualToConstant:maxWidth];
    NSLayoutConstraint *fillW = [panel.widthAnchor constraintEqualToAnchor:guide.widthAnchor constant:-(margin * 2.0)];
    fillW.priority = UILayoutPriorityDefaultHigh;
    // 固定占安全区高度的大部分，内部用 ScrollView 滚动，避免横屏裁切 / 高度塌陷
    NSLayoutConstraint *prefH = [panel.heightAnchor constraintEqualToAnchor:guide.heightAnchor multiplier:0.88];
    prefH.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *maxH = [panel.heightAnchor constraintLessThanOrEqualToConstant:480.0];
    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:guide.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:guide.centerYAnchor],
        [panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:guide.leadingAnchor constant:margin],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:guide.trailingAnchor constant:-margin],
        [panel.topAnchor constraintGreaterThanOrEqualToAnchor:guide.topAnchor constant:8.0],
        [panel.bottomAnchor constraintLessThanOrEqualToAnchor:guide.bottomAnchor constant:-8.0],
        widthCap,
        fillW,
        prefH,
        maxH,
    ]];
}

static BOOL GameAds_IsSoundEnabled(void)
{
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    if (![defs objectForKey:kSoundPrefKey])
    {
        return YES;
    }
    return [defs boolForKey:kSoundPrefKey];
}

static void GameAds_SessionLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void GameAds_SessionLog(NSString *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    [[TPAdSessionLog shared] append:[NSString stringWithFormat:@"%@ %@", kGameAdsLog, body]];
}

/// 仅子控件可点，空白处穿透给 Unity（全屏容器用）
@interface GameAdsPassThroughView : UIView
@end
@implementation GameAdsPassThroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

@interface GameAdsHotspotButton : UIButton
@end
@implementation GameAdsHotspotButton
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    GameAds_SessionLog(@"热区 touchesBegan point=%@",
                       NSStringFromCGPoint([[touches anyObject] locationInView:self]));
    [super touchesBegan:touches withEvent:event];
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event
{
    return CGRectContainsPoint(CGRectInset(self.bounds, -12.0, -12.0), point);
}
@end

static void GameAds_SetSoundEnabled(BOOL enabled)
{
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kSoundPrefKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    GameAds_SessionLog(@"音效开关=%@", enabled ? @"开" : @"关");
    // 尽量静音/恢复系统音频会话（配合 GameMgr 里禁用 AudioSource）
    UnitySetAudioSessionActive(enabled ? 1 : 0);
}

static void GameAds_ShowTopToast(NSString *text)
{
    UIView *host = GameAds_HostView();
    if (!host || text.length == 0)
    {
        return;
    }

    UIView *wrap = [[UIView alloc] init];
    wrap.translatesAutoresizingMaskIntoConstraints = NO;
    wrap.backgroundColor = [[UIColor colorWithRed:0.07 green:0.16 blue:0.12 alpha:1.0] colorWithAlphaComponent:0.90];
    wrap.layer.cornerRadius = 3.0;
    wrap.userInteractionEnabled = NO;

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 2;
    label.textColor = [UIColor colorWithRed:0.96 green:0.91 blue:0.78 alpha:1.0];
    label.font = [UIFont fontWithName:@"Georgia" size:12.0] ?: [UIFont systemFontOfSize:12.0];
    [wrap addSubview:label];
    [host addSubview:wrap];

    [NSLayoutConstraint activateConstraints:@[
        [wrap.topAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.topAnchor constant:10.0],
        [wrap.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
        [wrap.leadingAnchor constraintGreaterThanOrEqualToAnchor:host.safeAreaLayoutGuide.leadingAnchor constant:18.0],
        [wrap.trailingAnchor constraintLessThanOrEqualToAnchor:host.safeAreaLayoutGuide.trailingAnchor constant:-18.0],
        [wrap.widthAnchor constraintLessThanOrEqualToConstant:320.0],
        [label.topAnchor constraintEqualToAnchor:wrap.topAnchor constant:6.0],
        [label.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor constant:-6.0],
        [label.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:10.0],
        [label.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor constant:-10.0],
    ]];

    wrap.alpha = 0;
    [UIView animateWithDuration:0.18 animations:^{
        wrap.alpha = 1;
    } completion:^(BOOL finished) {
        (void)finished;
        [UIView animateWithDuration:0.25 delay:2.0 options:0 animations:^{
            wrap.alpha = 0;
        } completion:^(BOOL done) {
            (void)done;
            [wrap removeFromSuperview];
        }];
    }];
}

#pragma mark - Extra shot dialog + banner

@interface GameAdsExtraShotUI : NSObject
+ (instancetype)shared;
- (void)showWithStrengthControl:(void *)strengthControl;
- (void)dismiss;
@end

@interface GameAdsExtraShotUI ()
@property (nonatomic, strong) UIWindow *dialogWindow;
@property (nonatomic, strong) UIView *overlay;
@property (nonatomic, assign) void *pendingStrength;
@end

@implementation GameAdsExtraShotUI

+ (instancetype)shared
{
    static GameAdsExtraShotUI *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GameAdsExtraShotUI alloc] init];
    });
    return instance;
}

- (void)dismiss
{
    GameAds_SessionLog(@"关闭次数激励弹窗与横幅");
    [[TPAdManager shared] hideBanner];
    [self.overlay removeFromSuperview];
    self.overlay = nil;
    self.dialogWindow.hidden = YES;
    self.dialogWindow.rootViewController = nil;
    self.dialogWindow = nil;
}

- (void)showWithStrengthControl:(void *)strengthControl
{
    if (self.dialogWindow || self.overlay.superview)
    {
        return;
    }
    UIWindow *key = GameAds_KeyWindow();
    if (!key)
    {
        GameAds_SessionLog(@"次数弹窗失败：无宿主窗口");
        return;
    }

    self.pendingStrength = strengthControl;
    GameAds_SessionLog(@"弹出次数激励弹窗（+横幅）");

    // 全屏高层级窗口，避免关卡内 UnityView 挡住 Watch / Not Now
    UIWindow *win = GameAds_MakeOverlayWindow(key.bounds);
    win.windowLevel = UIWindowLevelAlert; // 高于热区窗口，避免右上角热区挡按钮
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    win.rootViewController = vc;
    self.dialogWindow = win;

    UIView *host = vc.view;
    UIView *overlay = [[UIView alloc] initWithFrame:host.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.52];
    self.overlay = overlay;

    UIView *panel = [[UIView alloc] init];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.backgroundColor = [UIColor colorWithRed:0.09 green:0.22 blue:0.17 alpha:1.0];
    panel.layer.cornerRadius = 6.0;
    panel.layer.borderWidth = 1.0;
    panel.layer.borderColor = [UIColor colorWithRed:0.82 green:0.66 blue:0.22 alpha:0.85].CGColor;
    [overlay addSubview:panel];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Need an Extra Shot?";
    title.textColor = [UIColor colorWithRed:0.96 green:0.91 blue:0.78 alpha:1.0];
    title.font = [UIFont fontWithName:@"Georgia-Bold" size:22.0] ?: [UIFont boldSystemFontOfSize:22.0];
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;
    [panel addSubview:title];

    UILabel *body = [[UILabel alloc] init];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    body.text = @"Watch a short video to earn +1 shot for this level.";
    body.textColor = [UIColor colorWithRed:0.84 green:0.79 blue:0.64 alpha:1.0];
    body.font = [UIFont fontWithName:@"Georgia" size:15.0] ?: [UIFont systemFontOfSize:15.0];
    body.textAlignment = NSTextAlignmentCenter;
    body.numberOfLines = 0;
    [panel addSubview:body];

    UIButton *watch = [UIButton buttonWithType:UIButtonTypeCustom];
    watch.translatesAutoresizingMaskIntoConstraints = NO;
    watch.backgroundColor = [UIColor colorWithRed:0.79 green:0.64 blue:0.16 alpha:1.0];
    watch.layer.cornerRadius = 4.0;
    [watch setTitle:@"Watch Video" forState:UIControlStateNormal];
    [watch setTitleColor:[UIColor colorWithRed:0.12 green:0.09 blue:0.04 alpha:1.0] forState:UIControlStateNormal];
    watch.titleLabel.font = [UIFont fontWithName:@"Georgia-Bold" size:16.0] ?: [UIFont boldSystemFontOfSize:16.0];
    [watch addTarget:self action:@selector(onWatch) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:watch];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeCustom];
    cancel.translatesAutoresizingMaskIntoConstraints = NO;
    cancel.layer.cornerRadius = 4.0;
    cancel.layer.borderWidth = 1.0;
    cancel.layer.borderColor = [UIColor colorWithRed:0.84 green:0.79 blue:0.64 alpha:0.7].CGColor;
    [cancel setTitle:@"Not Now" forState:UIControlStateNormal];
    [cancel setTitleColor:[UIColor colorWithRed:0.90 green:0.86 blue:0.74 alpha:1.0] forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont fontWithName:@"Georgia" size:15.0] ?: [UIFont systemFontOfSize:15.0];
    [cancel addTarget:self action:@selector(onCancel) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:cancel];

    CGFloat bannerReserve = 56.0;
    UIEdgeInsets safe = GameAds_SafeInsets(host);
    bannerReserve += safe.bottom;

    UILayoutGuide *guide = overlay.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:guide.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:guide.centerYAnchor constant:-12.0],
        [panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:guide.leadingAnchor constant:20.0],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:guide.trailingAnchor constant:-20.0],
        [panel.widthAnchor constraintLessThanOrEqualToConstant:360.0],
        [panel.topAnchor constraintGreaterThanOrEqualToAnchor:guide.topAnchor constant:8.0],
        [panel.bottomAnchor constraintLessThanOrEqualToAnchor:guide.bottomAnchor constant:-(bannerReserve + 8.0)],

        [title.topAnchor constraintEqualToAnchor:panel.topAnchor constant:22.0],
        [title.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:20.0],
        [title.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-20.0],

        [body.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12.0],
        [body.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:20.0],
        [body.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-20.0],

        [watch.topAnchor constraintEqualToAnchor:body.bottomAnchor constant:22.0],
        [watch.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:20.0],
        [watch.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-20.0],
        [watch.heightAnchor constraintEqualToConstant:44.0],

        [cancel.topAnchor constraintEqualToAnchor:watch.bottomAnchor constant:10.0],
        [cancel.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:20.0],
        [cancel.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-20.0],
        [cancel.heightAnchor constraintEqualToConstant:40.0],
        [cancel.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-18.0],
    ]];

    [host addSubview:overlay];
    [host bringSubviewToFront:overlay];
    [[TPAdManager shared] showBannerAtPosition:TPBannerPositionBottomCenter
                                       sceneId:@"extra_shot"
                                      hostView:overlay];
}

- (void)onCancel
{
    GameAds_SessionLog(@"用户取消次数激励弹窗");
    [self dismiss];
    self.pendingStrength = NULL;
}

- (void)onWatch
{
    void *sc = self.pendingStrength;
    GameAds_SessionLog(@"用户点击观看激励视频（次数+1）");
    [self dismiss];
    self.pendingStrength = NULL;

    __weak GameAdsExtraShotUI *weakSelf = self;
    [[TPAdManager shared] showRewardedWithSceneId:@"extra_shot"
                                        finished:^(BOOL didEarnReward, BOOL didShowAd) {
        dispatch_async(dispatch_get_main_queue(), ^{
            (void)weakSelf;
            if (!didShowAd)
            {
                GameAds_SessionLog(@"激励视频未展示/未加载成功 → 不加次数");
                GameAds_ShowTopToast(@"Ad is not available. Please try again.");
                return;
            }
            if (didEarnReward)
            {
                GameAds_SessionLog(@"激励视频看完 → 发放 +1 次数");
                GameAds_AddExtraShot(sc);
                GameAds_ShowTopToast(@"Reward earned! +1 shot added.");
            }
            else
            {
                GameAds_SessionLog(@"激励视频未看完 → 不发放次数");
                GameAds_ShowTopToast(@"No reward. Finish the video to earn a shot.");
            }
        });
    }];
}

@end

#pragma mark - Extra shot hotspot (top-right)

@interface GameAdsHotspotUI : NSObject
+ (instancetype)shared;
- (void)showForStrength:(void *)strengthControl;
- (void)hide;
- (void)refresh;
@end

@interface GameAdsHotspotUI ()
@property (nonatomic, strong) UIWindow *hotspotWindow;
@property (nonatomic, strong) UIButton *hotspot;
@property (nonatomic, assign) void *strengthControl;
@property (nonatomic, strong) id orientationObserver;
@property (nonatomic, assign) BOOL hasUnityFrame;
@property (nonatomic, assign) CGRect unityFrame;   // Unity 屏幕：左上原点
@property (nonatomic, assign) CGSize unityScreen;
@end

@implementation GameAdsHotspotUI

+ (instancetype)shared
{
    static GameAdsHotspotUI *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GameAdsHotspotUI alloc] init];
    });
    return instance;
}

- (void)dealloc
{
    if (self.orientationObserver)
    {
        [[NSNotificationCenter defaultCenter] removeObserver:self.orientationObserver];
    }
}

- (void)hide
{
    [self.hotspot removeFromSuperview];
    self.hotspot = nil;
    self.hotspotWindow.hidden = YES;
    self.hotspotWindow.rootViewController = nil;
    self.hotspotWindow = nil;
    self.strengthControl = NULL;
    self.hasUnityFrame = NO;
}

- (void)setUnityFrame:(CGRect)frame screen:(CGSize)screen
{
    // Overlay Canvas 的 WorldToScreen 在本工程里经常算出左下角小矩形，
    // 导致热区离开❤️。暂时一律忽略，只用右上角估算。
    (void)frame;
    (void)screen;
}

- (CGRect)hotspotScreenFrame
{
    UIWindow *key = GameAds_KeyWindow();
    if (!key)
    {
        return CGRectZero;
    }
    CGFloat keyW = CGRectGetWidth(key.bounds);
    CGFloat keyH = CGRectGetHeight(key.bounds);
    CGRect inKey = CGRectZero;

    if (self.hasUnityFrame && self.unityScreen.width > 1.0 && self.unityScreen.height > 1.0)
    {
        CGFloat sx = keyW / self.unityScreen.width;
        CGFloat sy = keyH / self.unityScreen.height;
        inKey = CGRectMake(self.unityFrame.origin.x * sx,
                           self.unityFrame.origin.y * sy,
                           self.unityFrame.size.width * sx,
                           self.unityFrame.size.height * sy);
    }
    else
    {
        // 与 Unity GameAds_PinBloodBadgeToTopRight 同一套右上角布局（edge=10pt）
        UIEdgeInsets safe = GameAds_SafeInsets(key);
        CGFloat edge = 10.0;
        CGFloat w = MAX(168.0, keyW * 0.125);
        CGFloat h = MAX(58.0, keyH * 0.058);
        CGFloat top = MAX(safe.top, 0.0) + edge;
        CGFloat right = MAX(safe.right, 0.0) + edge;
        inKey = CGRectMake(keyW - w - right, top, w, h);
    }
    return [key convertRect:inKey toWindow:nil];
}

- (void)layoutHotspot
{
    if (!self.hotspotWindow)
    {
        return;
    }
    CGRect frame = [self hotspotScreenFrame];
    if (CGRectIsEmpty(frame))
    {
        return;
    }
    self.hotspotWindow.frame = frame;
    self.hotspot.frame = self.hotspotWindow.rootViewController.view.bounds;
}

- (void)refresh
{
    if (self.hotspotWindow)
    {
        [self layoutHotspot];
    }
}

- (void)showForStrength:(void *)strengthControl
{
    UIWindow *key = GameAds_KeyWindow();
    if (!key || !strengthControl)
    {
        GameAds_SessionLog(@"次数热区失败：key=%@ sc=%p", key, strengthControl);
        return;
    }
    self.strengthControl = strengthControl;
    self.hasUnityFrame = NO; // 强制右上角估算，避免错误 UnityFrame

    CGRect frame = [self hotspotScreenFrame];
    if (CGRectIsEmpty(frame))
    {
        GameAds_SessionLog(@"次数热区失败：frame 为空");
        return;
    }

    if (!self.hotspotWindow)
    {
        UIWindow *win = GameAds_MakeOverlayWindow(frame);
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor clearColor];
        vc.view.userInteractionEnabled = YES;

        GameAdsHotspotButton *btn = [GameAdsHotspotButton buttonWithType:UIButtonTypeCustom];
        btn.backgroundColor = [UIColor clearColor];
        btn.accessibilityLabel = @"Extra shot";
        btn.userInteractionEnabled = YES;
        btn.exclusiveTouch = YES;
        [btn addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];
        [btn addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchDown];
        btn.frame = vc.view.bounds;
        btn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [vc.view addSubview:btn];

        // 手势兜底：个别平台按钮事件丢失时仍能弹出
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap)];
        [vc.view addGestureRecognizer:tap];

        win.rootViewController = vc;
        self.hotspotWindow = win;
        self.hotspot = btn;

        if (!self.orientationObserver)
        {
            __weak GameAdsHotspotUI *weakSelf = self;
            self.orientationObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:UIDeviceOrientationDidChangeNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *note) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [weakSelf layoutHotspot];
                });
            }];
        }
    }

    [self layoutHotspot];
    self.hotspotWindow.hidden = NO;
    GameAds_SessionLog(@"显示关卡右上角次数点击热区 overlayWindow frame=%@",
                       NSStringFromCGRect(self.hotspotWindow.frame));

    __weak GameAdsHotspotUI *weakSelf = self;
    for (NSNumber *delay in @[ @0.2, @0.6, @1.2 ])
    {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf layoutHotspot];
        });
    }
}

- (void)onTap
{
    static CFAbsoluteTime sLastTap = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - sLastTap < 0.45)
    {
        return;
    }
    sLastTap = now;

    GameAds_SessionLog(@"点击次数热区 → 弹出激励询问");
    if (!self.strengthControl)
    {
        GameAds_SessionLog(@"次数热区无 StrengthControl，忽略");
        return;
    }
    [[GameAdsExtraShotUI shared] showWithStrengthControl:self.strengthControl];
}

@end

#pragma mark - Settings UI

@interface GameSettingsUI : NSObject
+ (instancetype)shared;
- (void)showEntryButton;
- (void)hideEntryButton;
- (void)openRoot;
- (void)closeAll;
@end

@interface GameSettingsUI ()
@property (nonatomic, strong) UIButton *entryButton;
@property (nonatomic, strong) UIView *rootOverlay;
@property (nonatomic, strong) UIView *pageContainer;
@property (nonatomic, strong) UISwitch *soundSwitch;
@end

@implementation GameSettingsUI

+ (instancetype)shared
{
    static GameSettingsUI *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[GameSettingsUI alloc] init];
    });
    return instance;
}

- (UIColor *)feltColor { return [UIColor colorWithRed:0.09 green:0.22 blue:0.17 alpha:1.0]; }
- (UIColor *)ivoryColor { return [UIColor colorWithRed:0.96 green:0.91 blue:0.78 alpha:1.0]; }
- (UIColor *)mutedIvory { return [UIColor colorWithRed:0.84 green:0.79 blue:0.64 alpha:1.0]; }
- (UIColor *)goldColor { return [UIColor colorWithRed:0.79 green:0.64 blue:0.16 alpha:1.0]; }

- (void)hideEntryButton
{
    [self.entryButton removeFromSuperview];
    self.entryButton = nil;
}

- (void)showEntryButton
{
    UIView *host = GameAds_HostView();
    if (!host)
    {
        return;
    }
    if (self.entryButton.superview)
    {
        return;
    }

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 13.0, *))
    {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
        UIImage *img = [UIImage systemImageNamed:@"gearshape" withConfiguration:cfg];
        [btn setImage:img forState:UIControlStateNormal];
        btn.tintColor = [self ivoryColor];
    }
    else
    {
        [btn setTitle:@"⚙︎" forState:UIControlStateNormal];
        [btn setTitleColor:[self ivoryColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:22.0];
    }
    btn.backgroundColor = [[self feltColor] colorWithAlphaComponent:0.85];
    btn.layer.cornerRadius = 18.0;
    btn.layer.borderWidth = 1.0;
    btn.layer.borderColor = [[self goldColor] colorWithAlphaComponent:0.7].CGColor;
    [btn addTarget:self action:@selector(openRoot) forControlEvents:UIControlEventTouchUpInside];

    // 选关页设置按钮：贴右上，但避开安全区，避免被刘海裁切
    CGFloat size = 40.0;
    UIEdgeInsets safe = GameAds_SafeInsets(host);
    CGFloat top = MAX(10.0, safe.top + 6.0);
    CGFloat right = MAX(10.0, safe.right + 8.0);
    btn.frame = CGRectMake(CGRectGetWidth(host.bounds) - size - right, top, size, size);
    btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    [host addSubview:btn];
    [host bringSubviewToFront:btn];
    self.entryButton = btn;
    GameAds_SessionLog(@"关卡选择界面显示设置按钮");
}

- (UIButton *)makeRowButton:(NSString *)title action:(SEL)action
{
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
    btn.layer.cornerRadius = 4.0;
    btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    btn.titleEdgeInsets = UIEdgeInsetsMake(0, 16, 0, 16);
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[self ivoryColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont fontWithName:@"Georgia" size:16.0] ?: [UIFont systemFontOfSize:16.0];
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [btn.heightAnchor constraintEqualToConstant:48.0].active = YES;
    return btn;
}

- (void)closeAll
{
    [self.rootOverlay removeFromSuperview];
    self.rootOverlay = nil;
    self.pageContainer = nil;
    self.soundSwitch = nil;
}

- (void)openRoot
{
    UIView *host = GameAds_HostView();
    if (!host)
    {
        return;
    }
    [self closeAll];
    GameAds_SessionLog(@"打开设置界面");

    UIView *overlay = [[UIView alloc] initWithFrame:host.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    self.rootOverlay = overlay;

    UIView *panel = [[UIView alloc] init];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.backgroundColor = [self feltColor];
    panel.layer.cornerRadius = 8.0;
    panel.layer.borderWidth = 1.0;
    panel.layer.borderColor = [[self goldColor] colorWithAlphaComponent:0.8].CGColor;
    [overlay addSubview:panel];
    self.pageContainer = panel;

    [self buildSettingsRootIn:panel];
    [host addSubview:overlay];
    [host bringSubviewToFront:overlay];

    GameAds_PinPanelInSafeArea(panel, overlay, 16.0, 420.0);
}

- (void)clearPanel:(UIView *)panel
{
    for (UIView *v in panel.subviews)
    {
        [v removeFromSuperview];
    }
}

- (UILabel *)headerLabel:(NSString *)text
{
    UILabel *l = [[UILabel alloc] init];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.text = text;
    l.textColor = [self ivoryColor];
    l.font = [UIFont fontWithName:@"Georgia-Bold" size:22.0] ?: [UIFont boldSystemFontOfSize:22.0];
    l.textAlignment = NSTextAlignmentCenter;
    return l;
}

- (void)buildSettingsRootIn:(UIView *)panel
{
    [self clearPanel:panel];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [panel addSubview:scroll];

    UIView *content = [[UIView alloc] init];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:content];

    UILabel *title = [self headerLabel:@"Settings"];
    [content addSubview:title];

    UIView *soundRow = [[UIView alloc] init];
    soundRow.translatesAutoresizingMaskIntoConstraints = NO;
    soundRow.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
    soundRow.layer.cornerRadius = 4.0;
    [content addSubview:soundRow];

    UILabel *soundLabel = [[UILabel alloc] init];
    soundLabel.translatesAutoresizingMaskIntoConstraints = NO;
    soundLabel.text = @"Sound Effects";
    soundLabel.textColor = [self ivoryColor];
    soundLabel.font = [UIFont fontWithName:@"Georgia" size:16.0] ?: [UIFont systemFontOfSize:16.0];
    [soundRow addSubview:soundLabel];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    sw.on = GameAds_IsSoundEnabled();
    sw.onTintColor = [self goldColor];
    [sw addTarget:self action:@selector(onSoundToggle:) forControlEvents:UIControlEventValueChanged];
    [soundRow addSubview:sw];
    self.soundSwitch = sw;

    UIButton *about = [self makeRowButton:@"About Us" action:@selector(openAbout)];
    UIButton *legal = [self makeRowButton:@"Legal Terms" action:@selector(openLegal)];
    UIButton *feedback = [self makeRowButton:@"Feedback" action:@selector(openFeedback)];
    [content addSubview:about];
    [content addSubview:legal];
    [content addSubview:feedback];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"Close" forState:UIControlStateNormal];
    [close setTitleColor:[self mutedIvory] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont fontWithName:@"Georgia" size:15.0] ?: [UIFont systemFontOfSize:15.0];
    [close addTarget:self action:@selector(closeAll) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:close];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:panel.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor],

        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],

        [title.topAnchor constraintEqualToAnchor:content.topAnchor constant:18.0],
        [title.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16.0],
        [title.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16.0],

        [soundRow.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:16.0],
        [soundRow.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16.0],
        [soundRow.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16.0],
        [soundRow.heightAnchor constraintEqualToConstant:44.0],
        [soundLabel.leadingAnchor constraintEqualToAnchor:soundRow.leadingAnchor constant:16.0],
        [soundLabel.centerYAnchor constraintEqualToAnchor:soundRow.centerYAnchor],
        [sw.trailingAnchor constraintEqualToAnchor:soundRow.trailingAnchor constant:-14.0],
        [sw.centerYAnchor constraintEqualToAnchor:soundRow.centerYAnchor],

        [about.topAnchor constraintEqualToAnchor:soundRow.bottomAnchor constant:10.0],
        [about.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16.0],
        [about.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16.0],

        [legal.topAnchor constraintEqualToAnchor:about.bottomAnchor constant:8.0],
        [legal.leadingAnchor constraintEqualToAnchor:about.leadingAnchor],
        [legal.trailingAnchor constraintEqualToAnchor:about.trailingAnchor],

        [feedback.topAnchor constraintEqualToAnchor:legal.bottomAnchor constant:8.0],
        [feedback.leadingAnchor constraintEqualToAnchor:about.leadingAnchor],
        [feedback.trailingAnchor constraintEqualToAnchor:about.trailingAnchor],

        [close.topAnchor constraintEqualToAnchor:feedback.bottomAnchor constant:12.0],
        [close.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [close.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14.0],
        [close.heightAnchor constraintEqualToConstant:36.0],
    ]];
}

- (void)onSoundToggle:(UISwitch *)sw
{
    GameAds_SetSoundEnabled(sw.isOn);
    GameAds_ApplySoundPreference(NULL);
}

- (void)openSubpageWithTitle:(NSString *)title body:(NSString *)body
{
    UIView *panel = self.pageContainer;
    if (!panel)
    {
        return;
    }
    [self clearPanel:panel];

    UILabel *h = [self headerLabel:title];
    [panel addSubview:h];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.showsVerticalScrollIndicator = YES;
    [panel addSubview:scroll];

    UILabel *bodyLabel = [[UILabel alloc] init];
    bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bodyLabel.text = body;
    bodyLabel.textColor = [self mutedIvory];
    bodyLabel.font = [UIFont fontWithName:@"Georgia" size:14.0] ?: [UIFont systemFontOfSize:14.0];
    bodyLabel.numberOfLines = 0;
    [scroll addSubview:bodyLabel];

    UIButton *back = [UIButton buttonWithType:UIButtonTypeCustom];
    back.translatesAutoresizingMaskIntoConstraints = NO;
    [back setTitle:@"Back" forState:UIControlStateNormal];
    [back setTitleColor:[self ivoryColor] forState:UIControlStateNormal];
    back.titleLabel.font = [UIFont fontWithName:@"Georgia" size:15.0] ?: [UIFont systemFontOfSize:15.0];
    [back addTarget:self action:@selector(backToRoot) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:back];

    [NSLayoutConstraint activateConstraints:@[
        [h.topAnchor constraintEqualToAnchor:panel.topAnchor constant:16.0],
        [h.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:16.0],
        [h.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-16.0],

        [scroll.topAnchor constraintEqualToAnchor:h.bottomAnchor constant:10.0],
        [scroll.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:12.0],
        [scroll.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-12.0],
        [scroll.bottomAnchor constraintEqualToAnchor:back.topAnchor constant:-8.0],

        [bodyLabel.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:4.0],
        [bodyLabel.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:4.0],
        [bodyLabel.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-4.0],
        [bodyLabel.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-8.0],
        [bodyLabel.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-8.0],

        [back.centerXAnchor constraintEqualToAnchor:panel.centerXAnchor],
        [back.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-12.0],
        [back.heightAnchor constraintEqualToConstant:36.0],
    ]];
}

- (void)backToRoot
{
    if (self.pageContainer)
    {
        [self buildSettingsRootIn:self.pageContainer];
    }
}

- (void)openAbout
{
    GameAds_SessionLog(@"打开关于我们");
    NSString *body = [NSString stringWithFormat:
                      @"%@\n\n"
                      @"A casual pool experience focused on precise aiming, clean shots, and satisfying table clearances.\n\n"
                      @"Sink every ball with the shots you have, climb through stages, and enjoy a relaxed billiards challenge built for quick sessions.\n\n"
                      @"Contact\n%@",
                      kGameDisplayName, kSupportEmail];
    [self openSubpageWithTitle:@"About Us" body:body];
}

- (void)openLegal
{
    GameAds_SessionLog(@"打开法律条款");
    NSString *body =
    @"Terms of Use\n"
    @"By playing this game, you agree to use it for personal entertainment only. Do not reverse engineer, redistribute, or misuse the app.\n\n"
    @"Privacy Policy\n"
    @"We may process limited device and advertising identifiers to show ads (including rewarded, interstitial, and banner ads) through our ad partners. We do not sell your personal information.\n\n"
    @"Ads & Tracking\n"
    @"On iOS, tracking is subject to your App Tracking Transparency choice. You can change related permissions in system Settings.\n\n"
    @"Contact\n"
    @"For privacy or legal questions, email:\n"
    @"Ljy18011962920@163.com\n\n"
    @"These terms are provided within the app for your review.";
    [self openSubpageWithTitle:@"Legal Terms" body:body];
}

- (void)openFeedback
{
    GameAds_SessionLog(@"打开反馈意见");
    UIView *panel = self.pageContainer;
    if (!panel)
    {
        return;
    }
    [self clearPanel:panel];

    UILabel *h = [self headerLabel:@"Feedback"];
    [panel addSubview:h];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [panel addSubview:scroll];

    UIView *content = [[UIView alloc] init];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:content];

    UILabel *intro = [[UILabel alloc] init];
    intro.translatesAutoresizingMaskIntoConstraints = NO;
    intro.text = [NSString stringWithFormat:
                  @"We'd love to hear from you.\n\n"
                  @"Tell us about bugs, level difficulty, or ideas that would make %@ better.\n\n"
                  @"Please email:\n%@\n\n"
                  @"(Copy the address above — feedback stays in your email app of choice; this screen does not open external links.)",
                  kGameDisplayName, kSupportEmail];
    intro.textColor = [self mutedIvory];
    intro.font = [UIFont fontWithName:@"Georgia" size:14.0] ?: [UIFont systemFontOfSize:14.0];
    intro.numberOfLines = 0;
    [content addSubview:intro];

    UILabel *troubleTitle = [[UILabel alloc] init];
    troubleTitle.translatesAutoresizingMaskIntoConstraints = NO;
    troubleTitle.text = @"Having trouble?";
    troubleTitle.textColor = [self ivoryColor];
    troubleTitle.font = [UIFont fontWithName:@"Georgia-Bold" size:15.0] ?: [UIFont boldSystemFontOfSize:15.0];
    [content addSubview:troubleTitle];

    UILabel *helper = [[UILabel alloc] init];
    helper.translatesAutoresizingMaskIntoConstraints = NO;
    helper.text = @"If something isn't working right, please copy the details and email them to us. A little extra context helps us help you much faster.";
    helper.textColor = [self mutedIvory];
    helper.font = [UIFont fontWithName:@"Georgia" size:11.0] ?: [UIFont systemFontOfSize:11.0];
    helper.numberOfLines = 0;
    [content addSubview:helper];

    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    copyBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [copyBtn setTitle:@"Copy Details" forState:UIControlStateNormal];
    [copyBtn setTitleColor:[UIColor colorWithRed:0.12 green:0.18 blue:0.14 alpha:1.0] forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont fontWithName:@"Georgia-Bold" size:14.0] ?: [UIFont boldSystemFontOfSize:14.0];
    copyBtn.backgroundColor = [self goldColor];
    copyBtn.layer.cornerRadius = 4.0;
    [copyBtn addTarget:self action:@selector(copySupportDetails) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:copyBtn];

    UIButton *back = [UIButton buttonWithType:UIButtonTypeCustom];
    back.translatesAutoresizingMaskIntoConstraints = NO;
    [back setTitle:@"Back" forState:UIControlStateNormal];
    [back setTitleColor:[self ivoryColor] forState:UIControlStateNormal];
    back.titleLabel.font = [UIFont fontWithName:@"Georgia" size:15.0] ?: [UIFont systemFontOfSize:15.0];
    [back addTarget:self action:@selector(backToRoot) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:back];

    [NSLayoutConstraint activateConstraints:@[
        [h.topAnchor constraintEqualToAnchor:panel.topAnchor constant:14.0],
        [h.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:16.0],
        [h.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-16.0],

        [scroll.topAnchor constraintEqualToAnchor:h.bottomAnchor constant:8.0],
        [scroll.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:back.topAnchor constant:-6.0],

        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],

        [intro.topAnchor constraintEqualToAnchor:content.topAnchor constant:4.0],
        [intro.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16.0],
        [intro.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16.0],

        [troubleTitle.topAnchor constraintEqualToAnchor:intro.bottomAnchor constant:14.0],
        [troubleTitle.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16.0],
        [troubleTitle.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16.0],

        [helper.topAnchor constraintEqualToAnchor:troubleTitle.bottomAnchor constant:6.0],
        [helper.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16.0],
        [helper.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16.0],

        [copyBtn.topAnchor constraintEqualToAnchor:helper.bottomAnchor constant:12.0],
        [copyBtn.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16.0],
        [copyBtn.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16.0],
        [copyBtn.heightAnchor constraintEqualToConstant:40.0],
        [copyBtn.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-12.0],

        [back.centerXAnchor constraintEqualToAnchor:panel.centerXAnchor],
        [back.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-10.0],
        [back.heightAnchor constraintEqualToConstant:34.0],
    ]];
}

- (void)copySupportDetails
{
    NSString *report = [[TPAdSessionLog shared] exportReport];
    UIPasteboard.generalPasteboard.string = report ?: @"";
    GameAds_SessionLog(@"已复制支持详情 length=%lu", (unsigned long)report.length);
    GameAds_ShowTopToast(@"✓ Copied — paste into your email");
}

@end

#pragma mark - C API

int GameAds_TryShowInterstitial(const char *sceneId)
{
    NSString *sid = nil;
    if (sceneId != NULL && sceneId[0] != '\0')
    {
        sid = [NSString stringWithUTF8String:sceneId];
    }
    GameAds_SessionLog(@"尝试展示插屏 sceneId=%@", sid ?: @"(nil)");
    int ok = [[TPAdManager shared] showInterstitialWithSceneId:sid] ? 1 : 0;
    GameAds_SessionLog(@"插屏%@", ok ? @"已调用展示" : @"未就绪，已触发加载");
    return ok;
}

void GameAds_ShowExtraShotHotspot(void *strengthControl)
{
    void (^show)(void) = ^{
        [[GameAdsHotspotUI shared] showForStrength:strengthControl];
    };
    if ([NSThread isMainThread])
    {
        show();
    }
    else
    {
        dispatch_async(dispatch_get_main_queue(), show);
    }
}

void GameAds_HideExtraShotHotspot(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[GameAdsHotspotUI shared] hide];
        [[GameAdsExtraShotUI shared] dismiss];
    });
}

void GameAds_RefreshExtraShotHotspot(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[GameAdsHotspotUI shared] refresh];
    });
}

void GameAds_SetExtraShotHotspotUnityFrame(float x, float y, float w, float h, float screenW, float screenH)
{
    CGRect frame = CGRectMake((CGFloat)x, (CGFloat)y, (CGFloat)w, (CGFloat)h);
    CGSize screen = CGSizeMake((CGFloat)screenW, (CGFloat)screenH);
    void (^apply)(void) = ^{
        [[GameAdsHotspotUI shared] setUnityFrame:frame screen:screen];
        [[GameAdsHotspotUI shared] refresh];
    };
    if ([NSThread isMainThread])
    {
        apply();
    }
    else
    {
        dispatch_async(dispatch_get_main_queue(), apply);
    }
}

void GameAds_ShowSettingsButton(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[GameSettingsUI shared] showEntryButton];
    });
}

void GameAds_HideSettingsButton(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[GameSettingsUI shared] hideEntryButton];
        [[GameSettingsUI shared] closeAll];
    });
}

void GameAds_ApplySoundPreference(void *gameMgr)
{
    (void)gameMgr;
    BOOL enabled = GameAds_IsSoundEnabled();
    UnitySetAudioSessionActive(enabled ? 1 : 0);
    GameAds_SessionLog(@"应用音效偏好 enabled=%d", enabled);
}
