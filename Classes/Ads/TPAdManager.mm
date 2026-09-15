//
//  TPAdManager.mm
//  Billiard — TradPlus 中介（Meta / Vungle / InMobi / Chartboost / Fyber·DT / Bigo）
//
//  参考：
//  - https://docs.tradplusad.com/docs/integration_ios/download/
//  - https://docs.tradplusad.com/docs/integration_ios/ios_sdk/ios_sdk_start/
//  - https://docs.tradplusad.com/docs/integration_ios/ios14
//  - https://docs.tradplusad.com/docs/integration_ios/fast_integration_ios/fast_rewarded/
//  - https://github.com/tradplus/tradplus-ios-demo
//

#import "TPAdManager.h"
#import "TPAdConfig.h"
#import "TPAdSessionLog.h"

#import <AppTrackingTransparency/AppTrackingTransparency.h>
#import <AdSupport/AdSupport.h>

#import <TradPlusAds/TradPlus.h>
#import <TradPlusAds/TradPlusAdRewarded.h>
#import <TradPlusAds/TradPlusAdInterstitial.h>
#import <TradPlusAds/TradPlusAdBanner.h>
#import <TradPlusAds/MSLogging.h>

#import <FBAudienceNetwork/FBAudienceNetwork.h>

#import "UnityAppController.h"

static NSString * const kTPAdLogTag = @"[广告]";

static void TPAds_Log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void TPAds_Log(NSString *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    [[TPAdSessionLog shared] append:[NSString stringWithFormat:@"%@ %@", kTPAdLogTag, body]];
}

@interface TPAdManager () <
    TradPlusADRewardedDelegate,
    TradPlusADInterstitialDelegate,
    TradPlusADBannerDelegate
>

@property (nonatomic, strong) TradPlusAdRewarded *rewardedAd;
@property (nonatomic, strong) TradPlusAdInterstitial *interstitialAd;
@property (nonatomic, strong) TradPlusAdBanner *bannerAd;

@property (nonatomic, assign) BOOL sdkInitialized;
@property (nonatomic, assign) BOOL startCalled;
@property (nonatomic, assign) BOOL attRequested;
@property (nonatomic, assign) BOOL adsPrepared;
@property (nonatomic, assign) BOOL bannerShowing;
@property (nonatomic, assign) TPBannerPosition bannerPosition;
@property (nonatomic, assign) BOOL rewardedGrantedThisPlay;
@property (nonatomic, copy, nullable) void (^rewardedFinished)(BOOL didEarnReward, BOOL didShowAd);

/// 加载中标记：避免并发 / 回调连环 loadAd
@property (nonatomic, assign) BOOL rewardedLoading;
@property (nonatomic, assign) BOOL interstitialLoading;
@property (nonatomic, assign) BOOL bannerLoading;
/// 最近一次加载失败时间：展示未就绪触发时遵守冷却，避免 TradPlus 600015
@property (nonatomic, assign) CFAbsoluteTime rewardedLastFailAt;
@property (nonatomic, assign) CFAbsoluteTime interstitialLastFailAt;
@property (nonatomic, assign) CFAbsoluteTime bannerLastFailAt;

@end

/// 展示未就绪触发重载时的最小间隔（秒）；关闭后重载不受此限制
static const CFAbsoluteTime kTPShowNotReadyReloadCooldown = 12.0;

typedef NS_ENUM(NSInteger, TPAdReloadReason) {
    TPAdReloadReasonStartup = 0,       // 首次启动
    TPAdReloadReasonClosed = 1,        // 广告关闭（兜底）
    TPAdReloadReasonShowNotReady = 2,  // 展示时未就绪
    TPAdReloadReasonShowFailed = 3,    // 展示失败（等同需要补货）
    TPAdReloadReasonOnShow = 4,        // show 成功立即预载下一条（播放期间跑瀑布流）
};

@implementation TPAdManager

+ (instancetype)shared
{
    static TPAdManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TPAdManager alloc] init];
    });
    return instance;
}

+ (void)load
{
    // 在 didBecomeActive 时启动：iOS15+ 在 didFinishLaunching 里弹 ATT 可能不出现
    [[NSNotificationCenter defaultCenter] addObserver:[TPAdManager shared]
                                             selector:@selector(onDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _bannerPosition = TPBannerPositionBottomCenter;
    }
    return self;
}

#pragma mark - Lifecycle

- (void)onDidBecomeActive:(NSNotification *)notification
{
    [self start];
}

- (void)start
{
    if (self.startCalled)
    {
        return;
    }
    self.startCalled = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self requestATTThenInit];
    });
}

- (void)requestATTThenInit
{
    if (@available(iOS 14.5, *))
    {
        ATTrackingManagerAuthorizationStatus status = [ATTrackingManager trackingAuthorizationStatus];
        if (status == ATTrackingManagerAuthorizationStatusNotDetermined)
        {
            if (self.attRequested)
            {
                return;
            }
            self.attRequested = YES;
            [ATTrackingManager requestTrackingAuthorizationWithCompletionHandler:^(ATTrackingManagerAuthorizationStatus newStatus) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self applyMetaAdvertiserTracking:newStatus];
                    [self initTradPlusSDK];
                });
            }];
            return;
        }

        [self applyMetaAdvertiserTracking:status];
        [self initTradPlusSDK];
        return;
    }

    [FBAdSettings setAdvertiserTrackingEnabled:YES];
    [self initTradPlusSDK];
}

- (void)applyMetaAdvertiserTracking:(ATTrackingManagerAuthorizationStatus)status API_AVAILABLE(ios(14.0))
{
    BOOL enabled = (status == ATTrackingManagerAuthorizationStatusAuthorized);
    [FBAdSettings setAdvertiserTrackingEnabled:enabled];
    if (kTPEnableVerboseLog)
    {
        TPAds_Log(@"ATT 状态=%ld Meta广告追踪ATE=%d", (long)status, enabled);
    }
}

#pragma mark - SDK Init

- (void)initTradPlusSDK
{
    if (self.sdkInitialized)
    {
        [self prepareAdUnitsIfNeeded];
        return;
    }

    if (kTPEnableVerboseLog)
    {
        [TradPlus setLogLevel:MSLogLevelAll];
        [FBAdSettings setLogLevel:FBAdLogLevelLog];
    }

    if (kTPEnableMetaTestDevice)
    {
        NSString *hash = [FBAdSettings testDeviceHash];
        TPAds_Log(@"Meta 测试设备 hash=%@（上架前请将 kTPEnableMetaTestDevice 改为 NO）", hash);
        if (hash.length > 0)
        {
            [FBAdSettings addTestDevice:hash];
        }
    }

    TPAds_Log(@"TradPlus 初始化 appId=%@", kTPAppId);
    __weak TPAdManager *weakSelf = self;
    [TradPlus initSDK:kTPAppId completionBlock:^(NSError *tpError) {
        TPAdManager *manager = weakSelf;
        if (!manager)
        {
            return;
        }
        if (tpError)
        {
            TPAds_Log(@"TradPlus 初始化失败: %@", tpError);
            manager.startCalled = NO; // 允许下次重试
            return;
        }

        TPAds_Log(@"TradPlus 初始化成功");
        manager.sdkInitialized = YES;
        [manager prepareAdUnitsIfNeeded];
    }];
}

- (void)prepareAdUnitsIfNeeded
{
    if (self.adsPrepared)
    {
        return;
    }
    self.adsPrepared = YES;

    [self setupRewarded];
    [self setupInterstitial];
    // 横幅按需展示，不在启动时自动加载
    // 重载策略：① 启动预载 ② show 成功立即预载下一条 ③ 关闭后兜底 ④ 展示未就绪（有冷却）
    [self loadRewardedForReason:TPAdReloadReasonStartup];
    [self loadInterstitialForReason:TPAdReloadReasonStartup];
}

#pragma mark - Load guards

- (NSString *)descriptionForReloadReason:(TPAdReloadReason)reason
{
    switch (reason)
    {
        case TPAdReloadReasonStartup: return @"启动";
        case TPAdReloadReasonClosed: return @"关闭后兜底";
        case TPAdReloadReasonShowNotReady: return @"展示未就绪";
        case TPAdReloadReasonShowFailed: return @"展示失败";
        case TPAdReloadReasonOnShow: return @"show后预载下一条";
    }
    return @"未知";
}

- (BOOL)shouldSkipShowNotReadyReloadAfterFailAt:(CFAbsoluteTime)lastFailAt
                                         reason:(TPAdReloadReason)reason
                                           kind:(NSString *)kind
{
    if (reason != TPAdReloadReasonShowNotReady || lastFailAt <= 0)
    {
        return NO;
    }
    CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - lastFailAt;
    if (elapsed < kTPShowNotReadyReloadCooldown)
    {
        TPAds_Log(@"%@跳过加载：展示未就绪但距上次失败仅 %.1fs（冷却 %.0fs，防连环重载）",
                  kind, elapsed, kTPShowNotReadyReloadCooldown);
        return YES;
    }
    return NO;
}

#pragma mark - Rewarded

- (void)setupRewarded
{
    if (self.rewardedAd)
    {
        return;
    }
    self.rewardedAd = [[TradPlusAdRewarded alloc] init];
    self.rewardedAd.delegate = self;
    [self.rewardedAd setAdUnitID:kTPRewardedAdUnitId];
}

- (void)loadRewarded
{
    [self loadRewardedForReason:TPAdReloadReasonShowNotReady];
}

- (void)loadRewardedForReason:(TPAdReloadReason)reason
{
    if (!self.sdkInitialized)
    {
        TPAds_Log(@"加载激励视频跳过：SDK 未就绪");
        return;
    }
    // OnShow：正在展示当前条，仍要强制预载下一条；不能因 isAdReady 短暂仍为 YES 而跳过
    if (reason != TPAdReloadReasonOnShow && [self isRewardedReady])
    {
        TPAds_Log(@"加载激励视频跳过：已就绪");
        return;
    }
    if (self.rewardedLoading)
    {
        TPAds_Log(@"加载激励视频跳过：加载中（reason=%@）", [self descriptionForReloadReason:reason]);
        return;
    }
    if ([self shouldSkipShowNotReadyReloadAfterFailAt:self.rewardedLastFailAt
                                               reason:reason
                                                 kind:@"激励视频"])
    {
        return;
    }

    [self setupRewarded];
    self.rewardedLoading = YES;
    TPAds_Log(@"加载激励视频 %@（%@）", kTPRewardedAdUnitId, [self descriptionForReloadReason:reason]);
    [self.rewardedAd loadAd];
}

- (BOOL)isRewardedReady
{
    return self.rewardedAd != nil && self.rewardedAd.isAdReady;
}

- (void)finishRewardedWithEarned:(BOOL)earned shown:(BOOL)shown
{
    void (^callback)(BOOL, BOOL) = self.rewardedFinished;
    self.rewardedFinished = nil;
    self.rewardedGrantedThisPlay = NO;
    if (callback)
    {
        callback(earned, shown);
    }
}

- (BOOL)showRewardedWithSceneId:(NSString *)sceneId
{
    return [self showRewardedWithSceneId:sceneId finished:nil];
}

- (BOOL)showRewardedWithSceneId:(NSString *)sceneId
                       finished:(void (^)(BOOL didEarnReward, BOOL didShowAd))finished
{
    self.rewardedFinished = finished;
    self.rewardedGrantedThisPlay = NO;

    if (![self isRewardedReady])
    {
        TPAds_Log(@"展示激励视频：未就绪，触发加载");
        [self loadRewardedForReason:TPAdReloadReasonShowNotReady];
        [self finishRewardedWithEarned:NO shown:NO];
        return NO;
    }
    if (sceneId.length > 0)
    {
        [self.rewardedAd entryAdScenario:sceneId];
    }
    TPAds_Log(@"展示激励视频 sceneId=%@", sceneId ?: @"(nil)");
    [self.rewardedAd showAdWithSceneId:sceneId];
    // show 成功立刻预载下一条：播放那几十秒里瀑布流可跑完，关完再点更容易直接出片
    [self loadRewardedForReason:TPAdReloadReasonOnShow];
    return YES;
}

#pragma mark - Interstitial

- (void)setupInterstitial
{
    if (self.interstitialAd)
    {
        return;
    }
    self.interstitialAd = [[TradPlusAdInterstitial alloc] init];
    self.interstitialAd.delegate = self;
    [self.interstitialAd setAdUnitID:kTPInterstitialAdUnitId];
}

- (void)loadInterstitial
{
    [self loadInterstitialForReason:TPAdReloadReasonShowNotReady];
}

- (void)loadInterstitialForReason:(TPAdReloadReason)reason
{
    if (!self.sdkInitialized)
    {
        TPAds_Log(@"加载插屏跳过：SDK 未就绪");
        return;
    }
    // OnShow：正在展示当前条，仍要强制预载下一条
    if (reason != TPAdReloadReasonOnShow && [self isInterstitialReady])
    {
        TPAds_Log(@"加载插屏跳过：已就绪");
        return;
    }
    if (self.interstitialLoading)
    {
        TPAds_Log(@"加载插屏跳过：加载中（reason=%@）", [self descriptionForReloadReason:reason]);
        return;
    }
    if ([self shouldSkipShowNotReadyReloadAfterFailAt:self.interstitialLastFailAt
                                               reason:reason
                                                 kind:@"插屏"])
    {
        return;
    }

    [self setupInterstitial];
    self.interstitialLoading = YES;
    TPAds_Log(@"加载插屏 %@（%@）", kTPInterstitialAdUnitId, [self descriptionForReloadReason:reason]);
    [self.interstitialAd loadAd];
}

- (BOOL)isInterstitialReady
{
    return self.interstitialAd != nil && self.interstitialAd.isAdReady;
}

- (BOOL)showInterstitialWithSceneId:(NSString *)sceneId
{
    if (![self isInterstitialReady])
    {
        TPAds_Log(@"展示插屏：未就绪，触发加载");
        [self loadInterstitialForReason:TPAdReloadReasonShowNotReady];
        return NO;
    }
    if (sceneId.length > 0)
    {
        [self.interstitialAd entryAdScenario:sceneId];
    }
    TPAds_Log(@"展示插屏 sceneId=%@", sceneId ?: @"(nil)");
    [self.interstitialAd showAdWithSceneId:sceneId];
    // show 成功立刻预载下一条：播放/展示期间瀑布流可跑完
    [self loadInterstitialForReason:TPAdReloadReasonOnShow];
    return YES;
}

#pragma mark - Banner

- (UIViewController *)hostViewController
{
    UnityAppController *ctrl = GetAppController();
    if (ctrl.rootViewController)
    {
        return ctrl.rootViewController;
    }
    return UIApplication.sharedApplication.keyWindow.rootViewController;
}

- (UIView *)hostView
{
    UnityAppController *ctrl = GetAppController();
    if (ctrl.rootView)
    {
        return ctrl.rootView;
    }
    return UIApplication.sharedApplication.keyWindow;
}

- (void)layoutBanner
{
    if (!self.bannerAd || !self.bannerAd.superview)
    {
        return;
    }

    UIView *host = self.bannerAd.superview;
    CGFloat bannerW = 320.0;
    CGFloat bannerH = 50.0;
    CGFloat safeBottom = 0;
    CGFloat safeTop = 0;
    if (@available(iOS 11.0, *))
    {
        safeBottom = host.safeAreaInsets.bottom;
        safeTop = host.safeAreaInsets.top;
    }

    CGFloat x = (CGRectGetWidth(host.bounds) - bannerW) * 0.5;
    CGFloat y = 0;
    if (self.bannerPosition == TPBannerPositionTopCenter)
    {
        y = safeTop;
    }
    else
    {
        y = CGRectGetHeight(host.bounds) - bannerH - safeBottom;
    }
    self.bannerAd.frame = CGRectMake(x, y, bannerW, bannerH);
}

- (void)showBannerAtPosition:(TPBannerPosition)position sceneId:(NSString *)sceneId
{
    [self showBannerAtPosition:position sceneId:sceneId hostView:nil];
}

- (void)showBannerAtPosition:(TPBannerPosition)position
                     sceneId:(NSString *)sceneId
                    hostView:(UIView *)hostView
{
    if (!self.sdkInitialized)
    {
        TPAds_Log(@"展示横幅跳过：SDK 未就绪");
        return;
    }

    self.bannerPosition = position;
    UIView *host = hostView ?: [self hostView];
    if (!host)
    {
        TPAds_Log(@"展示横幅失败：无宿主视图");
        return;
    }

    if (!self.bannerAd)
    {
        self.bannerAd = [[TradPlusAdBanner alloc] init];
        self.bannerAd.delegate = self;
        [self.bannerAd setAdUnitID:kTPBannerAdUnitId];
    }

    if (self.bannerAd.superview != host)
    {
        [self.bannerAd removeFromSuperview];
        [host addSubview:self.bannerAd];
    }

    self.bannerAd.hidden = NO;
    [self layoutBanner];
    self.bannerShowing = YES;

    if (self.bannerLoading)
    {
        TPAds_Log(@"横幅跳过重复加载：加载中");
        return;
    }
    if ([self shouldSkipShowNotReadyReloadAfterFailAt:self.bannerLastFailAt
                                               reason:TPAdReloadReasonShowNotReady
                                                 kind:@"横幅"])
    {
        return;
    }

    self.bannerLoading = YES;
    TPAds_Log(@"加载横幅 %@ sceneId=%@（展示未就绪/按需）", kTPBannerAdUnitId, sceneId ?: @"(nil)");
    [self.bannerAd loadAdWithSceneId:sceneId];
}

- (void)hideBanner
{
    self.bannerShowing = NO;
    if (self.bannerAd)
    {
        self.bannerAd.hidden = YES;
        [self.bannerAd removeFromSuperview];
    }
}

#pragma mark - TradPlusADRewardedDelegate

- (void)tpRewardedAdLoaded:(NSDictionary *)adInfo
{
    self.rewardedLoading = NO;
    self.rewardedLastFailAt = 0;
    [[TPAdSessionLog shared] appendEvent:@"激励视频·加载成功" adInfo:adInfo];
}

- (void)tpRewardedAdLoadFailWithError:(NSError *)error
{
    self.rewardedLoading = NO;
    self.rewardedLastFailAt = CFAbsoluteTimeGetCurrent();
    [[TPAdSessionLog shared] appendEvent:@"激励视频·加载失败" error:error];
    // 失败不自动重试，避免循环重载；等关闭或下次展示未就绪时再载
}

- (void)tpRewardedAdLoadFailWithError:(NSError *)error adInfo:(NSDictionary *)adInfo
{
    self.rewardedLoading = NO;
    self.rewardedLastFailAt = CFAbsoluteTimeGetCurrent();
    [[TPAdSessionLog shared] appendEvent:@"激励视频·加载失败(含adInfo)" adInfo:adInfo error:error];
}

- (void)tpRewardedAdImpression:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"激励视频·曝光" adInfo:adInfo];
}

- (void)tpRewardedAdShow:(NSDictionary *)adInfo didFailWithError:(NSError *)error
{
    [[TPAdSessionLog shared] appendEvent:@"激励视频·展示失败" adInfo:adInfo error:error];
    [self loadRewardedForReason:TPAdReloadReasonShowFailed];
    [self finishRewardedWithEarned:NO shown:NO];
}

- (void)tpRewardedAdClicked:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"激励视频·点击" adInfo:adInfo];
}

- (void)tpRewardedAdDismissed:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:[NSString stringWithFormat:@"激励视频·关闭 granted=%d", self.rewardedGrantedThisPlay]
                                  adInfo:adInfo];
    BOOL earned = self.rewardedGrantedThisPlay;
    [self loadRewardedForReason:TPAdReloadReasonClosed];
    [self finishRewardedWithEarned:earned shown:YES];
}

- (void)tpRewardedAdReward:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"激励视频·发放奖励" adInfo:adInfo];
    self.rewardedGrantedThisPlay = YES;
}

- (void)tpRewardedAdNoReward:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"激励视频·未获得奖励回调" adInfo:adInfo];
}

- (void)tpRewardedAdStartLoad:(NSDictionary *)adInfo
{
    self.rewardedLoading = YES;
    [[TPAdSessionLog shared] appendEvent:@"激励视频·开始加载" adInfo:adInfo];
}

- (void)tpRewardedAdOneLayerStartLoad:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"激励视频·广告源开始加载" adInfo:adInfo];
}

- (void)tpRewardedAdIsLoading:(NSDictionary *)adInfo
{
    self.rewardedLoading = YES;
    [[TPAdSessionLog shared] appendEvent:@"激励视频·加载中" adInfo:adInfo];
}

- (void)tpRewardedAdBidStart:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"激励视频·竞价开始" adInfo:adInfo];
}

- (void)tpRewardedAdBidEnd:(NSDictionary *)adInfo error:(NSError *)error
{
    [[TPAdSessionLog shared] appendEvent:@"激励视频·竞价结束" adInfo:adInfo error:error];
}

- (void)tpRewardedAdOneLayerLoaded:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"激励视频·广告源加载成功" adInfo:adInfo];
}

- (void)tpRewardedAdOneLayerLoad:(NSDictionary *)adInfo didFailWithError:(NSError *)error
{
    [[TPAdSessionLog shared] appendEvent:@"激励视频·广告源加载失败" adInfo:adInfo error:error];
}

- (void)tpRewardedAdAllLoaded:(BOOL)success adInfo:(NSDictionary *)adInfo
{
    self.rewardedLoading = NO;
    if (!success)
    {
        self.rewardedLastFailAt = CFAbsoluteTimeGetCurrent();
    }
    else
    {
        self.rewardedLastFailAt = 0;
    }
    [[TPAdSessionLog shared] appendEvent:[NSString stringWithFormat:@"激励视频·全部加载完成 success=%d", success]
                                  adInfo:adInfo];
}

- (void)tpRewardedAdAllLoaded:(BOOL)success
{
    self.rewardedLoading = NO;
    TPAds_Log(@"激励视频·全部加载完成 success=%d", success);
}

- (void)tpRewardedAdPlayStart:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"激励视频·播放开始" adInfo:adInfo];
}

- (void)tpRewardedAdPlayEnd:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"激励视频·播放结束" adInfo:adInfo];
}

#pragma mark - TradPlusADInterstitialDelegate

- (void)tpInterstitialAdLoaded:(NSDictionary *)adInfo
{
    self.interstitialLoading = NO;
    self.interstitialLastFailAt = 0;
    [[TPAdSessionLog shared] appendEvent:@"插屏·加载成功" adInfo:adInfo];
}

- (void)tpInterstitialAdLoadFailWithError:(NSError *)error
{
    self.interstitialLoading = NO;
    self.interstitialLastFailAt = CFAbsoluteTimeGetCurrent();
    [[TPAdSessionLog shared] appendEvent:@"插屏·加载失败" error:error];
    // 失败不自动重试，避免循环重载
}

- (void)tpInterstitialAdLoadFailWithError:(NSError *)error adInfo:(NSDictionary *)adInfo
{
    self.interstitialLoading = NO;
    self.interstitialLastFailAt = CFAbsoluteTimeGetCurrent();
    [[TPAdSessionLog shared] appendEvent:@"插屏·加载失败(含adInfo)" adInfo:adInfo error:error];
}

- (void)tpInterstitialAdImpression:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"插屏·曝光" adInfo:adInfo];
}

- (void)tpInterstitialAdShow:(NSDictionary *)adInfo didFailWithError:(NSError *)error
{
    [[TPAdSessionLog shared] appendEvent:@"插屏·展示失败" adInfo:adInfo error:error];
    [self loadInterstitialForReason:TPAdReloadReasonShowFailed];
}

- (void)tpInterstitialAdClicked:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"插屏·点击" adInfo:adInfo];
}

- (void)tpInterstitialAdDismissed:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"插屏·关闭" adInfo:adInfo];
    [self loadInterstitialForReason:TPAdReloadReasonClosed];
}

- (void)tpInterstitialAdStartLoad:(NSDictionary *)adInfo
{
    self.interstitialLoading = YES;
    [[TPAdSessionLog shared] appendEvent:@"插屏·开始加载" adInfo:adInfo];
}

- (void)tpInterstitialAdOneLayerStartLoad:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"插屏·广告源开始加载" adInfo:adInfo];
}

- (void)tpInterstitialAdIsLoading:(NSDictionary *)adInfo
{
    self.interstitialLoading = YES;
    [[TPAdSessionLog shared] appendEvent:@"插屏·加载中" adInfo:adInfo];
}

- (void)tpInterstitialAdBidStart:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"插屏·竞价开始" adInfo:adInfo];
}

- (void)tpInterstitialAdBidEnd:(NSDictionary *)adInfo error:(NSError *)error
{
    [[TPAdSessionLog shared] appendEvent:@"插屏·竞价结束" adInfo:adInfo error:error];
}

- (void)tpInterstitialAdOneLayerLoaded:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"插屏·广告源加载成功" adInfo:adInfo];
}

- (void)tpInterstitialAdOneLayerLoad:(NSDictionary *)adInfo didFailWithError:(NSError *)error
{
    [[TPAdSessionLog shared] appendEvent:@"插屏·广告源加载失败" adInfo:adInfo error:error];
}

- (void)tpInterstitialAdAllLoaded:(BOOL)success adInfo:(NSDictionary *)adInfo
{
    self.interstitialLoading = NO;
    if (!success)
    {
        self.interstitialLastFailAt = CFAbsoluteTimeGetCurrent();
    }
    else
    {
        self.interstitialLastFailAt = 0;
    }
    [[TPAdSessionLog shared] appendEvent:[NSString stringWithFormat:@"插屏·全部加载完成 success=%d", success]
                                  adInfo:adInfo];
}

- (void)tpInterstitialAdAllLoaded:(BOOL)success
{
    self.interstitialLoading = NO;
    TPAds_Log(@"插屏·全部加载完成 success=%d", success);
}

- (void)tpInterstitialAdPlayStart:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"插屏·播放开始" adInfo:adInfo];
}

- (void)tpInterstitialAdPlayEnd:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"插屏·播放结束" adInfo:adInfo];
}

#pragma mark - TradPlusADBannerDelegate

- (UIViewController *)viewControllerForPresentingModalView
{
    return [self hostViewController];
}

- (void)tpBannerAdLoaded:(NSDictionary *)adInfo
{
    self.bannerLoading = NO;
    self.bannerLastFailAt = 0;
    [[TPAdSessionLog shared] appendEvent:@"横幅·加载成功" adInfo:adInfo];
    [self layoutBanner];
}

- (void)tpBannerAdLoadFailWithError:(NSError *)error
{
    self.bannerLoading = NO;
    self.bannerLastFailAt = CFAbsoluteTimeGetCurrent();
    [[TPAdSessionLog shared] appendEvent:@"横幅·加载失败" error:error];
}

- (void)tpBannerAdLoadFailWithError:(NSError *)error adInfo:(NSDictionary *)adInfo
{
    self.bannerLoading = NO;
    self.bannerLastFailAt = CFAbsoluteTimeGetCurrent();
    [[TPAdSessionLog shared] appendEvent:@"横幅·加载失败(含adInfo)" adInfo:adInfo error:error];
}

- (void)tpBannerAdImpression:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"横幅·曝光" adInfo:adInfo];
}

- (void)tpBannerAdShow:(NSDictionary *)adInfo didFailWithError:(NSError *)error
{
    [[TPAdSessionLog shared] appendEvent:@"横幅·展示失败" adInfo:adInfo error:error];
}

- (void)tpBannerAdClicked:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"横幅·点击" adInfo:adInfo];
}

- (void)tpBannerAdClose:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"横幅·关闭" adInfo:adInfo];
    [self hideBanner];
}

- (void)tpBannerAdStartLoad:(NSDictionary *)adInfo
{
    self.bannerLoading = YES;
    [[TPAdSessionLog shared] appendEvent:@"横幅·开始加载" adInfo:adInfo];
}

- (void)tpBannerAdOneLayerStartLoad:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"横幅·广告源开始加载" adInfo:adInfo];
}

- (void)tpBannerAdIsLoading:(NSDictionary *)adInfo
{
    self.bannerLoading = YES;
    [[TPAdSessionLog shared] appendEvent:@"横幅·加载中" adInfo:adInfo];
}

- (void)tpBannerAdBidStart:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"横幅·竞价开始" adInfo:adInfo];
}

- (void)tpBannerAdBidEnd:(NSDictionary *)adInfo error:(NSError *)error
{
    [[TPAdSessionLog shared] appendEvent:@"横幅·竞价结束" adInfo:adInfo error:error];
}

- (void)tpBannerAdOneLayerLoaded:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:@"横幅·广告源加载成功" adInfo:adInfo];
}

- (void)tpBannerAdOneLayerLoad:(NSDictionary *)adInfo didFailWithError:(NSError *)error
{
    [[TPAdSessionLog shared] appendEvent:@"横幅·广告源加载失败" adInfo:adInfo error:error];
}

- (void)tpBannerAdAllLoaded:(BOOL)success adInfo:(NSDictionary *)adInfo
{
    self.bannerLoading = NO;
    if (!success)
    {
        self.bannerLastFailAt = CFAbsoluteTimeGetCurrent();
    }
    else
    {
        self.bannerLastFailAt = 0;
    }
    [[TPAdSessionLog shared] appendEvent:[NSString stringWithFormat:@"横幅·全部加载完成 success=%d", success]
                                  adInfo:adInfo];
}

- (void)tpBannerAdAllLoaded:(BOOL)success
{
    self.bannerLoading = NO;
    TPAds_Log(@"横幅·全部加载完成 success=%d", success);
}

- (void)tpBannerAdSizeDidChange:(CGSize)size adInfo:(NSDictionary *)adInfo
{
    [[TPAdSessionLog shared] appendEvent:[NSString stringWithFormat:@"横幅·尺寸变化 w=%.0f h=%.0f", size.width, size.height]
                                  adInfo:adInfo];
    if (!self.bannerAd || !self.bannerAd.superview)
    {
        return;
    }
    UIView *host = self.bannerAd.superview;
    CGFloat x = (CGRectGetWidth(host.bounds) - size.width) * 0.5;
    CGFloat y = self.bannerAd.frame.origin.y;
    if (self.bannerPosition == TPBannerPositionBottomCenter)
    {
        CGFloat safeBottom = 0;
        if (@available(iOS 11.0, *))
        {
            safeBottom = host.safeAreaInsets.bottom;
        }
        y = CGRectGetHeight(host.bounds) - size.height - safeBottom;
    }
    self.bannerAd.frame = CGRectMake(x, y, size.width, size.height);
}

@end

#pragma mark - C API

static NSString *TPAds_NSStringFromC(const char *cStr)
{
    if (cStr == NULL || cStr[0] == '\0')
    {
        return nil;
    }
    return [NSString stringWithUTF8String:cStr];
}

void TPAds_Start(void)
{
    [[TPAdManager shared] start];
}

int TPAds_IsRewardedReady(void)
{
    return [TPAdManager shared].isRewardedReady ? 1 : 0;
}

int TPAds_ShowRewarded(const char *sceneId)
{
    return [[TPAdManager shared] showRewardedWithSceneId:TPAds_NSStringFromC(sceneId)] ? 1 : 0;
}

int TPAds_IsInterstitialReady(void)
{
    return [TPAdManager shared].isInterstitialReady ? 1 : 0;
}

int TPAds_ShowInterstitial(const char *sceneId)
{
    return [[TPAdManager shared] showInterstitialWithSceneId:TPAds_NSStringFromC(sceneId)] ? 1 : 0;
}

void TPAds_ShowBanner(int position, const char *sceneId)
{
    TPBannerPosition pos = (position == 1) ? TPBannerPositionTopCenter : TPBannerPositionBottomCenter;
    [[TPAdManager shared] showBannerAtPosition:pos sceneId:TPAds_NSStringFromC(sceneId)];
}

void TPAds_HideBanner(void)
{
    [[TPAdManager shared] hideBanner];
}

void TPAds_LoadRewarded(void)
{
    [[TPAdManager shared] loadRewarded];
}

void TPAds_LoadInterstitial(void)
{
    [[TPAdManager shared] loadInterstitial];
}
