//
//  TPAdConfig.h
//  Billiard — TradPlus + Meta Audience Network
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// TradPlus 后台应用 ID
static NSString * const kTPAppId = @"499DD5D958A8D67A8A95C09A78B42221";

/// 激励视频广告位 ID
static NSString * const kTPRewardedAdUnitId = @"724D5CADFB36627D490CD9456775C122";

/// 插屏广告位 ID
static NSString * const kTPInterstitialAdUnitId = @"EF04302A40ED6C26E45A0776B2F12F22";

/// 横幅广告位 ID
static NSString * const kTPBannerAdUnitId = @"7BB8DF15AE5872F56E06D29EBD99C722";

/// YES：把当前设备加入 Meta 测试设备（仅调试用，正式包保持 NO）
static const BOOL kTPEnableMetaTestDevice = NO;

/// YES：打印 TradPlus / Meta 详细日志（仅调试用，正式包保持 NO）
static const BOOL kTPEnableVerboseLog = NO;

NS_ASSUME_NONNULL_END
