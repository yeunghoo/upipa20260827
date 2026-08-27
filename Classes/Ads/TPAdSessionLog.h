//
//  TPAdSessionLog.h
//  仅保留本次 App 启动后的广告相关日志（内存，不落盘）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TPAdSessionLog : NSObject

+ (instancetype)shared;

/// 写入一行纯文本（同时 NSLog）
- (void)append:(NSString *)message;

/// 带 adInfo 的详细事件
- (void)appendEvent:(NSString *)event adInfo:(nullable NSDictionary *)adInfo;

/// 带 NSError 的详细事件（含 code / domain / userInfo）
- (void)appendEvent:(NSString *)event error:(nullable NSError *)error;

/// adInfo + error
- (void)appendEvent:(NSString *)event
             adInfo:(nullable NSDictionary *)adInfo
              error:(nullable NSError *)error;

/// 复制给用户的完整报告（英文抬头 + 本次会话明细）
- (NSString *)exportReport;

- (void)clear;

@end

NS_ASSUME_NONNULL_END
