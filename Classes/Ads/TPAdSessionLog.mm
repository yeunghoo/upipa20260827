//
//  TPAdSessionLog.mm
//

#import "TPAdSessionLog.h"
#import <UIKit/UIKit.h>

@interface TPAdSessionLog ()
@property (nonatomic, strong) NSMutableArray<NSString *> *lines;
@property (nonatomic, strong) NSDate *sessionStart;
@property (nonatomic, strong) NSDateFormatter *formatter;
@end

@implementation TPAdSessionLog

+ (instancetype)shared
{
    static TPAdSessionLog *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TPAdSessionLog alloc] init];
    });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _lines = [NSMutableArray array];
        _sessionStart = [NSDate date];
        _formatter = [[NSDateFormatter alloc] init];
        _formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        _formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        [self append:@"===== session begin ====="];
        NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
        NSString *build = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";
        UIDevice *device = [UIDevice currentDevice];
        [self append:[NSString stringWithFormat:@"app=%@(%@) ios=%@ model=%@ name=%@",
                      ver, build, device.systemVersion, device.model, device.name]];
    }
    return self;
}

- (void)clear
{
    @synchronized (self)
    {
        [self.lines removeAllObjects];
        self.sessionStart = [NSDate date];
    }
}

- (NSString *)timestamp
{
    return [self.formatter stringFromDate:[NSDate date]];
}

- (id)jsonSafeObject:(id)obj depth:(NSInteger)depth
{
    if (obj == nil || obj == [NSNull null])
    {
        return [NSNull null];
    }
    if (depth > 6)
    {
        NSString *desc = [obj description] ?: @"";
        if (desc.length > 200)
        {
            return [desc substringToIndex:200];
        }
        return desc;
    }
    if ([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]])
    {
        return obj;
    }
    if ([obj isKindOfClass:[NSDate class]])
    {
        return [self.formatter stringFromDate:(NSDate *)obj];
    }
    if ([obj isKindOfClass:[NSError class]])
    {
        NSError *err = (NSError *)obj;
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"domain"] = err.domain ?: @"";
        d[@"code"] = @(err.code);
        d[@"localizedDescription"] = err.localizedDescription ?: @"";
        if (err.localizedFailureReason.length > 0)
        {
            d[@"localizedFailureReason"] = err.localizedFailureReason;
        }
        if (err.userInfo.count > 0)
        {
            d[@"userInfo"] = [self jsonSafeObject:err.userInfo depth:depth + 1];
        }
        NSError *underlying = err.userInfo[NSUnderlyingErrorKey];
        if ([underlying isKindOfClass:[NSError class]])
        {
            d[@"underlyingError"] = [self jsonSafeObject:underlying depth:depth + 1];
        }
        return d;
    }
    if ([obj isKindOfClass:[NSDictionary class]])
    {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        [(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            out[[key description]] = [self jsonSafeObject:value depth:depth + 1];
        }];
        return out;
    }
    if ([obj isKindOfClass:[NSArray class]])
    {
        NSMutableArray *out = [NSMutableArray array];
        for (id item in (NSArray *)obj)
        {
            [out addObject:[self jsonSafeObject:item depth:depth + 1]];
        }
        return out;
    }
    return [obj description];
}

- (NSString *)prettyJSON:(id)obj
{
    id safe = [self jsonSafeObject:obj depth:0];
    if (![NSJSONSerialization isValidJSONObject:safe])
    {
        return [safe description];
    }
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:safe
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&err];
    if (!data)
    {
        return [safe description];
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: [safe description];
}

- (NSString *)stringifyObject:(id)obj depth:(NSInteger)depth
{
    if (obj == nil || obj == [NSNull null])
    {
        return @"(null)";
    }
    if (depth > 5)
    {
        return @"…";
    }
    if ([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]])
    {
        return [obj description];
    }
    if ([obj isKindOfClass:[NSError class]])
    {
        return [self formatError:(NSError *)obj];
    }
    if ([obj isKindOfClass:[NSDictionary class]])
    {
        NSDictionary *dict = (NSDictionary *)obj;
        NSMutableArray *parts = [NSMutableArray array];
        NSArray *keys = [[dict allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            return [[a description] compare:[b description]];
        }];
        for (id key in keys)
        {
            NSString *val = [self stringifyObject:dict[key] depth:depth + 1];
            [parts addObject:[NSString stringWithFormat:@"%@=%@", key, val]];
        }
        return [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@", "]];
    }
    if ([obj isKindOfClass:[NSArray class]])
    {
        NSMutableArray *parts = [NSMutableArray array];
        for (id item in (NSArray *)obj)
        {
            [parts addObject:[self stringifyObject:item depth:depth + 1]];
        }
        return [NSString stringWithFormat:@"[%@]", [parts componentsJoinedByString:@"; "]];
    }
    return [obj description];
}

- (NSString *)formatError:(NSError *)error
{
    if (!error)
    {
        return @"(no error)";
    }
    NSMutableString *s = [NSMutableString stringWithFormat:@"NSError{domain=%@ code=%ld desc=%@",
                          error.domain ?: @"?", (long)error.code, error.localizedDescription ?: @""];
    if (error.localizedFailureReason.length > 0)
    {
        [s appendFormat:@" reason=%@", error.localizedFailureReason];
    }
    if (error.userInfo.count > 0)
    {
        [s appendFormat:@" userInfo=%@", [self stringifyObject:error.userInfo depth:0]];
    }
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if ([underlying isKindOfClass:[NSError class]])
    {
        [s appendFormat:@" underlying=%@", [self formatError:underlying]];
    }
    [s appendString:@"}"];
    return s;
}

- (NSString *)formatAdInfo:(NSDictionary *)adInfo
{
    if (adInfo.count == 0)
    {
        return @"(empty adInfo)";
    }
    // 优先展开常见 TradPlus / 广告源字段，再附完整字典
    static NSArray<NSString *> *priorityKeys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        priorityKeys = @[
            @"adunit_id", @"adUnitId", @"adunitid", @"placement_id", @"placementId",
            @"network_name", @"networkName", @"adnetwork", @"ad_network", @"channel_name",
            @"adsource_id", @"adsourceId", @"adSourceId", @"adsource_name", @"adSourceName",
            @"ecpm", @"ECPM", @"ecpm_precision", @"precision",
            @"bid_price", @"bidPrice", @"bid_type", @"bidType", @"is_bid", @"isBid",
            @"layer_id", @"layerId", @"waterfall_index", @"waterfallIndex",
            @"iso_code", @"country_code", @"scene_id", @"sceneId",
            @"request_id", @"requestId", @"impression_id", @"impressionId",
            @"load_time", @"loadTime", @"is_success", @"code", @"error_code", @"errorCode",
            @"error_msg", @"errorMsg", @"msg", @"message"
        ];
    });

    NSMutableArray *highlight = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *key in priorityKeys)
    {
        id val = adInfo[key];
        if (val != nil)
        {
            [highlight addObject:[NSString stringWithFormat:@"%@=%@", key, [self stringifyObject:val depth:0]]];
            [seen addObject:key];
        }
    }
    NSString *full = [self stringifyObject:adInfo depth:0];
    if (highlight.count > 0)
    {
        return [NSString stringWithFormat:@"highlight{%@} full%@", [highlight componentsJoinedByString:@", "], full];
    }
    return [NSString stringWithFormat:@"full%@", full];
}

- (void)append:(NSString *)message
{
    if (message.length == 0)
    {
        return;
    }
    NSString *line = [NSString stringWithFormat:@"[%@] %@", [self timestamp], message];
    @synchronized (self)
    {
        [self.lines addObject:line];
        // 防止极端情况下内存过大
        if (self.lines.count > 4000)
        {
            [self.lines removeObjectsInRange:NSMakeRange(0, 500)];
        }
    }
    NSLog(@"%@", line);
}

- (void)appendEvent:(NSString *)event adInfo:(NSDictionary *)adInfo
{
    [self appendEvent:event adInfo:adInfo error:nil];
}

- (void)appendEvent:(NSString *)event error:(NSError *)error
{
    [self appendEvent:event adInfo:nil error:error];
}

- (void)appendEvent:(NSString *)event adInfo:(NSDictionary *)adInfo error:(NSError *)error
{
    NSMutableString *msg = [NSMutableString stringWithString:event ?: @"event"];
    if (adInfo)
    {
        [msg appendFormat:@"\n  adInfo.highlight=%@", [self formatAdInfo:adInfo]];
        [msg appendFormat:@"\n  adInfo.json=\n%@", [self prettyJSON:adInfo]];
    }
    if (error)
    {
        [msg appendFormat:@"\n  error=%@", [self formatError:error]];
        [msg appendFormat:@"\n  error.json=\n%@", [self prettyJSON:error]];
    }
    [self append:msg];
}

- (NSString *)exportReport
{
    NSMutableString *report = [NSMutableString string];
    [report appendString:@"Pool Game-Shooting Billiards — Support Details\n"];
    [report appendFormat:@"Exported: %@\n", [self timestamp]];
    [report appendFormat:@"Session started: %@\n", [self.formatter stringFromDate:self.sessionStart]];
    [report appendFormat:@"Email: Ljy18011962920@163.com\n"];
    UIDevice *device = [UIDevice currentDevice];
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";
    [report appendFormat:@"App: %@ (%@)\n", ver, build];
    [report appendFormat:@"Device: %@ / iOS %@\n", device.model, device.systemVersion];
    [report appendString:@"----------------------------------------\n"];
    @synchronized (self)
    {
        if (self.lines.count == 0)
        {
            [report appendString:@"(No details captured yet.)\n"];
        }
        else
        {
            for (NSString *line in self.lines)
            {
                [report appendString:line];
                [report appendString:@"\n"];
            }
        }
    }
    [report appendString:@"----------------------------------------\n"];
    return report;
}

@end
