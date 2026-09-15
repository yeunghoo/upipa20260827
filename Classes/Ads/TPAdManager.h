//
//  TPAdManager.h
//  Billiard — TradPlus 中介（Meta / Vungle / InMobi / Chartboost / Fyber·DT / Bigo）
//
//  封装初始化 / 激励 / 插屏 / 横幅。广告源参数在 TradPlus 后台配置即可。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TPBannerPosition) {
    TPBannerPositionBottomCenter = 0,
    TPBannerPositionTopCenter = 1,
};

@interface TPAdManager : NSObject

+ (instancetype)shared;

/// 启动广告系统：ATT → TradPlus init → 预加载激励/插屏
/// 重载策略：① 启动预载 ② show 成功立即预载下一条（播放期间跑瀑布流）
/// ③ 关闭后兜底重载 ④ 展示未就绪时重载（带冷却，失败不自动连环）
- (void)start;

@property (nonatomic, readonly, getter=isSDKInitialized) BOOL sdkInitialized;
@property (nonatomic, readonly, getter=isRewardedReady) BOOL rewardedReady;
@property (nonatomic, readonly, getter=isInterstitialReady) BOOL interstitialReady;
@property (nonatomic, readonly, getter=isBannerShowing) BOOL bannerShowing;

- (void)loadRewarded;
- (BOOL)showRewardedWithSceneId:(nullable NSString *)sceneId;
/// shown=NO：未加载成功或展示失败；didEarnReward=YES：完整看完并发放奖励
- (BOOL)showRewardedWithSceneId:(nullable NSString *)sceneId
                       finished:(nullable void (^)(BOOL didEarnReward, BOOL didShowAd))finished;

- (void)loadInterstitial;
- (BOOL)showInterstitialWithSceneId:(nullable NSString *)sceneId;

- (void)showBannerAtPosition:(TPBannerPosition)position sceneId:(nullable NSString *)sceneId;
- (void)showBannerAtPosition:(TPBannerPosition)position
                     sceneId:(nullable NSString *)sceneId
                    hostView:(nullable UIView *)hostView;
- (void)hideBanner;

@end

#ifdef __cplusplus
extern "C" {
#endif

/// 供后续 Unity C# DllImport("__Internal") 调用
void TPAds_Start(void);
int TPAds_IsRewardedReady(void);
int TPAds_ShowRewarded(const char * _Nullable sceneId);
int TPAds_IsInterstitialReady(void);
int TPAds_ShowInterstitial(const char * _Nullable sceneId);
void TPAds_ShowBanner(int position, const char * _Nullable sceneId);
void TPAds_HideBanner(void);
void TPAds_LoadRewarded(void);
void TPAds_LoadInterstitial(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
