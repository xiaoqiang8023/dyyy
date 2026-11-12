//
//  DYYY
//
//  Copyright (c) 2024 huami. All rights reserved.
//  Channel: @huamidev
//  Created on: 2024/10/04
//
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <float.h>
#import <math.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <syslog.h>

#import "AwemeHeaders.h"
#import "CityManager.h"
#import "DYYYBottomAlertView.h"
#import "DYYYManager.h"

#import "AWMSafeDispatchTimer.h"
#import "DYYYConstants.h"
#import "DYYYFloatClearButton.h"
#import "DYYYFloatSpeedButton.h"
#import "DYYYSettingViewController.h"
#import "DYYYToast.h"
#import "DYYYUtils.h"

static BOOL DYYYShouldDisableAllHDR(void);
static BOOL DYYYShouldFilterGlobalHDR(void);
static void DYYYMigrateCombinedHDRModeIfNeeded(void);

static CGFloat gStartY = 0.0;
static CGFloat gStartVal = 0.0;
static DYEdgeMode gMode = DYEdgeModeNone;
static __weak UICollectionView *gFeedCV = nil;

static const CGFloat kInvalidAlpha = -1.0;
static const CGFloat kInvalidHeight = -1.0;
static CGFloat gGlobalTransparency = kInvalidAlpha;
static CGFloat gCurrentTabBarHeight = kInvalidHeight;
static CGFloat originalTabBarHeight = kInvalidHeight;
static NSString *const kDYYYGlobalTransparencyKey = @"DYYYGlobalTransparency";
static NSString *const kDYYYGlobalTransparencyDidChangeNotification = @"DYYYGlobalTransparencyDidChangeNotification";
static char kDYYYGlobalTransparencyBaseAlphaKey;
static NSInteger dyyyGlobalTransparencyMutationDepth = 0;
// 2.2-9-23 前置声明：进度黑线通用藏线函数定义在文件后部（%ctor 前），AWEDProgressCoreContainer 的
// updateProgressSliderWithTime 在文件前部就要调用它，跑在每次进度更新后，压过状态机对黑线的重显示。
static void DYYYFullscreenProgressSyncBlackLines(UIView *slider);

static void updateGlobalTransparencyCache() {
    NSString *transparentValue = DYYYGetString(kDYYYGlobalTransparencyKey);
    if (transparentValue.length > 0) {
        float alphaValue;
        NSScanner *scanner = [NSScanner scannerWithString:transparentValue];
        if ([scanner scanFloat:&alphaValue] && scanner.isAtEnd) {
            gGlobalTransparency = MIN(MAX(alphaValue, 0.0), 1.0);
            return;
        }
    }
    gGlobalTransparency = kInvalidAlpha;
}

static NSDictionary<NSString *, NSString *> *DYYYTopTabTitleMapping(void) {
    static NSString *cachedRawValue = nil;
    static NSDictionary<NSString *, NSString *> *cachedMapping = nil;

    NSString *currentValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYModifyTopTabText"];
    BOOL rawValueChanged = (cachedRawValue != currentValue) && ![cachedRawValue isEqualToString:currentValue];

    if (!rawValueChanged) {
        return cachedMapping;
    }

    cachedRawValue = [currentValue copy];

    if (currentValue.length == 0) {
        cachedMapping = nil;
        return nil;
    }

    NSMutableDictionary<NSString *, NSString *> *mapping = [NSMutableDictionary dictionary];
    NSArray<NSString *> *titlePairs = [currentValue componentsSeparatedByString:@"#"];
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];

    for (NSString *pair in titlePairs) {
        NSArray<NSString *> *components = [pair componentsSeparatedByString:@"="];
        if (components.count != 2) {
            continue;
        }

        NSString *originalTitle = [components[0] stringByTrimmingCharactersInSet:whitespace];
        NSString *newTitle = [components[1] stringByTrimmingCharactersInSet:whitespace];

        if (originalTitle.length == 0 || newTitle.length == 0) {
            continue;
        }

        mapping[originalTitle] = newTitle;
    }

    cachedMapping = mapping.count > 0 ? [mapping copy] : nil;
    return cachedMapping;
}

static NSString *DYYYCustomAssetsDirectory(void) {
    static NSString *customDirectory = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
      NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
      customDirectory = [documentsPath stringByAppendingPathComponent:@"DYYY"];
      [[NSFileManager defaultManager] createDirectoryAtPath:customDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    });

    return customDirectory;
}

static NSString *DYYYCustomIconFileNameForButtonName(NSString *nameString) {
    if (nameString.length == 0) {
        return nil;
    }

    static NSDictionary<NSString *, NSString *> *prefixMapping = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      prefixMapping = @{
          @"icon_home_like_after" : @"like_after.png",
          @"icon_home_like_before" : @"like_before.png",
          @"icon_home_comment" : @"comment.png",
          @"icon_home_unfavorite" : @"unfavorite.png",
          @"icon_home_favorite" : @"favorite.png",
          @"iconHomeShareRight" : @"share.png"
      };
    });

    for (NSString *prefix in prefixMapping) {
        if ([nameString hasPrefix:prefix]) {
            return prefixMapping[prefix];
        }
    }

    if ([nameString containsString:@"_comment"]) {
        return @"comment.png";
    }
    if ([nameString containsString:@"_like"]) {
        BOOL isLikedState = [nameString containsString:@"_after"] || [nameString containsString:@"_liked"];
        return isLikedState ? @"like_after.png" : @"like_before.png";
    }
    if ([nameString containsString:@"_collect"]) {
        return @"unfavorite.png";
    }
    if ([nameString containsString:@"_share"]) {
        return @"share.png";
    }

    return nil;
}

static UIImage *DYYYLoadCustomImage(NSString *fileName, CGSize targetSize) {
    if (fileName.length == 0) {
        return nil;
    }

    static NSCache<NSString *, UIImage *> *imageCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      imageCache = [[NSCache alloc] init];
      imageCache.name = @"com.dyyy.customIcons.cache";
    });

    NSString *cacheKey = (targetSize.width > 0.0 && targetSize.height > 0.0) ? [NSString stringWithFormat:@"%@_%0.1f_%0.1f", fileName, targetSize.width, targetSize.height] : fileName;

    UIImage *cachedImage = [imageCache objectForKey:cacheKey];
    if (cachedImage) {
        return cachedImage;
    }

    NSString *fullPath = [DYYYCustomAssetsDirectory() stringByAppendingPathComponent:fileName];
    UIImage *sourceImage = [UIImage imageWithContentsOfFile:fullPath];
    if (!sourceImage) {
        return nil;
    }

    if (targetSize.width <= 0.0 || targetSize.height <= 0.0) {
        [imageCache setObject:sourceImage forKey:cacheKey];
        return sourceImage;
    }

    CGSize originalSize = sourceImage.size;
    if (originalSize.width <= 0.0 || originalSize.height <= 0.0) {
        return sourceImage;
    }

    CGFloat widthScale = targetSize.width / originalSize.width;
    CGFloat heightScale = targetSize.height / originalSize.height;
    CGFloat scale = fmin(widthScale, heightScale);

    if (fabs(1.0 - scale) <= FLT_EPSILON) {
        [imageCache setObject:sourceImage forKey:cacheKey];
        return sourceImage;
    }

    CGSize newSize = CGSizeMake(originalSize.width * scale, originalSize.height * scale);
    UIGraphicsBeginImageContextWithOptions(newSize, NO, 0.0);
    [sourceImage drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
    UIImage *resizedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    UIImage *resultImage = resizedImage ?: sourceImage;
    [imageCache setObject:resultImage forKey:cacheKey];
    return resultImage;
}

static BOOL DYYYShouldHandleSpeedFeatures(void) {
    if (isFloatSpeedButtonEnabled) {
        return YES;
    }

    float defaultSpeed = [[NSUserDefaults standardUserDefaults] floatForKey:@"DYYYDefaultSpeed"];
    if (defaultSpeed <= 0.0f) {
        return NO;
    }

    return fabsf(defaultSpeed - 1.0f) > FLT_EPSILON;
}

@interface AWEFeedProgressSlider (DYYYProgressLabel)
- (NSString *)dyyy_formatTimeFromSeconds:(CGFloat)seconds;
- (CGFloat)dyyy_modelDurationInSeconds;
- (CGFloat)dyyy_scheduleVerticalOffset;
- (void)dyyy_removeScheduleLabels;
- (void)dyyy_updateScheduleLabelsWithCurrentTime:(CGFloat)currentTime totalDuration:(CGFloat)totalDuration;
@end

@interface AWEPlayInteractionProgressController (DYYYProgressLabel)
- (void)dyyy_syncScheduleLabelsWithCurrentTime:(CGFloat)currentTime totalDuration:(CGFloat)totalDuration;
@end

@interface AWEDProgressCoreContainer (DYYYProgressLabel)
- (void)dyyy_syncScheduleLabelsWithCurrentTime:(CGFloat)currentTime totalDuration:(CGFloat)totalDuration;
@end

@interface UIView (DYYYProgressLabelLegacy)
- (void)dyyy_updateScheduleLabelsLegacyWithCurrentTime:(CGFloat)currentTime totalDuration:(CGFloat)totalDuration model:(id)model;
@end

@implementation UIView (DYYYProgressLabelLegacy)

- (NSString *)dyyy_legacyFormatTimeFromSeconds:(CGFloat)seconds {
    CGFloat safeSeconds = seconds;
    if (safeSeconds < 0) {
        safeSeconds = 0;
    }

    NSInteger total = (NSInteger)floor(safeSeconds);
    NSInteger hours = total / 3600;
    NSInteger minutes = (total % 3600) / 60;
    NSInteger secs = total % 60;

    if (hours > 0) {
        return [NSString stringWithFormat:@"%02ld:%02ld:%02ld", (long)hours, (long)minutes, (long)secs];
    }
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)minutes, (long)secs];
}

- (CGFloat)dyyy_legacyScheduleVerticalOffset {
    CGFloat verticalOffset = -12.5;
    NSString *offsetValueString = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYTimelineVerticalPosition"];
    if (offsetValueString.length > 0) {
        CGFloat configuredOffset = [offsetValueString floatValue];
        if (configuredOffset != 0) {
            verticalOffset = configuredOffset;
        }
    }
    return verticalOffset;
}

- (CGFloat)dyyy_legacyModelDurationInSeconds:(id)model {
    if (!model || ![model respondsToSelector:@selector(videoDuration)]) {
        return 0;
    }

    CGFloat videoDurationMs = [[model valueForKey:@"videoDuration"] doubleValue];
    if (videoDurationMs <= 0) {
        return 0;
    }
    return videoDurationMs / 1000.0;
}

- (void)dyyy_updateScheduleLabelsLegacyWithCurrentTime:(CGFloat)currentTime totalDuration:(CGFloat)totalDuration model:(id)model {
    if (!DYYYGetBool(@"DYYYShowScheduleDisplay")) {
        UIView *parentView = self.superview;
        if (parentView) {
            [[parentView viewWithTag:10001] removeFromSuperview];
            [[parentView viewWithTag:10002] removeFromSuperview];
        }
        return;
    }

    if (![NSThread isMainThread]) {
        __weak __typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
          [weakSelf dyyy_updateScheduleLabelsLegacyWithCurrentTime:currentTime totalDuration:totalDuration model:model];
        });
        return;
    }

    UIView *parentView = self.superview;
    if (!parentView) {
        return;
    }
    [parentView layoutIfNeeded];
    [self layoutIfNeeded];

    NSString *scheduleStyle = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYScheduleStyle"];
    BOOL showRightRemainingTime = [scheduleStyle isEqualToString:@"进度条右侧剩余"];
    BOOL showRightCompleteTime = [scheduleStyle isEqualToString:@"进度条右侧完整"];
    BOOL showLeftRemainingTime = [scheduleStyle isEqualToString:@"进度条左侧剩余"];
    BOOL showLeftCompleteTime = [scheduleStyle isEqualToString:@"进度条左侧完整"];

    BOOL shouldShowLeftLabel = !showRightRemainingTime && !showRightCompleteTime;
    BOOL shouldShowRightLabel = !showLeftRemainingTime && !showLeftCompleteTime;

    CGFloat modelDuration = [self dyyy_legacyModelDurationInSeconds:model];
    CGFloat effectiveTotalDuration = totalDuration > 0 ? totalDuration : modelDuration;
    if (effectiveTotalDuration < 0) {
        effectiveTotalDuration = 0;
    }

    CGFloat effectiveCurrentTime = currentTime;
    if (effectiveCurrentTime < 0) {
        effectiveCurrentTime = 0;
    }
    if (effectiveTotalDuration > 0 && effectiveCurrentTime > effectiveTotalDuration) {
        effectiveCurrentTime = effectiveTotalDuration;
    }

    CGRect sliderFrameInParent = [self convertRect:self.bounds toView:parentView];
    if (CGRectGetWidth(sliderFrameInParent) <= 1.0 || CGRectGetHeight(sliderFrameInParent) <= 1.0) {
        return;
    }
    CGFloat labelYPosition = CGRectGetMinY(sliderFrameInParent) + [self dyyy_legacyScheduleVerticalOffset];
    CGFloat labelHeight = 15.0;
    UIFont *labelFont = [UIFont systemFontOfSize:8];
    NSString *labelColorHex = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYProgressLabelColor"];

    UILabel *leftLabel = (UILabel *)[parentView viewWithTag:10001];
    if (leftLabel && ![leftLabel isKindOfClass:[UILabel class]]) {
        [leftLabel removeFromSuperview];
        leftLabel = nil;
    }

    if (shouldShowLeftLabel) {
        if (!leftLabel) {
            leftLabel = [[UILabel alloc] init];
            leftLabel.backgroundColor = [UIColor clearColor];
            leftLabel.tag = 10001;
            [parentView addSubview:leftLabel];
        }
        leftLabel.font = labelFont;

        NSString *newLeftText = nil;
        if (showLeftRemainingTime) {
            newLeftText = [self dyyy_legacyFormatTimeFromSeconds:MAX(effectiveTotalDuration - effectiveCurrentTime, 0)];
        } else if (showLeftCompleteTime) {
            newLeftText = [NSString stringWithFormat:@"%@/%@", [self dyyy_legacyFormatTimeFromSeconds:effectiveCurrentTime], [self dyyy_legacyFormatTimeFromSeconds:effectiveTotalDuration]];
        } else {
            newLeftText = [self dyyy_legacyFormatTimeFromSeconds:effectiveCurrentTime];
        }

        if (![leftLabel.text isEqualToString:newLeftText]) {
            leftLabel.text = newLeftText;
        }
        [leftLabel sizeToFit];
        leftLabel.frame = CGRectMake(CGRectGetMinX(sliderFrameInParent), labelYPosition, CGRectGetWidth(leftLabel.bounds), labelHeight);
        [DYYYUtils applyColorSettingsToLabel:leftLabel colorHexString:labelColorHex];
    } else {
        [leftLabel removeFromSuperview];
    }

    UILabel *rightLabel = (UILabel *)[parentView viewWithTag:10002];
    if (rightLabel && ![rightLabel isKindOfClass:[UILabel class]]) {
        [rightLabel removeFromSuperview];
        rightLabel = nil;
    }

    if (shouldShowRightLabel) {
        if (!rightLabel) {
            rightLabel = [[UILabel alloc] init];
            rightLabel.backgroundColor = [UIColor clearColor];
            rightLabel.tag = 10002;
            [parentView addSubview:rightLabel];
        }
        rightLabel.font = labelFont;

        NSString *newRightText = nil;
        if (showRightRemainingTime) {
            newRightText = [self dyyy_legacyFormatTimeFromSeconds:MAX(effectiveTotalDuration - effectiveCurrentTime, 0)];
        } else if (showRightCompleteTime) {
            newRightText = [NSString stringWithFormat:@"%@/%@", [self dyyy_legacyFormatTimeFromSeconds:effectiveCurrentTime], [self dyyy_legacyFormatTimeFromSeconds:effectiveTotalDuration]];
        } else {
            newRightText = [self dyyy_legacyFormatTimeFromSeconds:effectiveTotalDuration];
        }

        if (![rightLabel.text isEqualToString:newRightText]) {
            rightLabel.text = newRightText;
        }
        [rightLabel sizeToFit];
        CGFloat rightLabelX = MAX(CGRectGetMaxX(sliderFrameInParent) - CGRectGetWidth(rightLabel.bounds), CGRectGetMinX(sliderFrameInParent));
        rightLabel.frame = CGRectMake(rightLabelX, labelYPosition, CGRectGetWidth(rightLabel.bounds), labelHeight);
        [DYYYUtils applyColorSettingsToLabel:rightLabel colorHexString:labelColorHex];
    } else {
        [rightLabel removeFromSuperview];
    }
}

@end

// 关闭不可见水印
%hook AWEHPChannelInvisibleWaterMarkModel

- (BOOL)isEnter {
    return NO;
}

- (BOOL)isAppear {
    return NO;
}

%end

// 长按复制个人简介
%hook AWEProfileMentionLabel

- (void)layoutSubviews {
    %orig;

    if (!DYYYGetBool(@"DYYYBioCopyText")) {
        return;
    }

    BOOL hasLongPressGesture = NO;
    for (UIGestureRecognizer *gesture in self.gestureRecognizers) {
        if ([gesture isKindOfClass:[UILongPressGestureRecognizer class]]) {
            hasLongPressGesture = YES;
            break;
        }
    }

    if (!hasLongPressGesture) {
        UILongPressGestureRecognizer *longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        longPressGesture.minimumPressDuration = 0.5;
        [self addGestureRecognizer:longPressGesture];
        self.userInteractionEnabled = YES;
    }
}

%new
- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        NSString *bioText = self.text;
        if (bioText && bioText.length > 0) {
            [[UIPasteboard generalPasteboard] setString:bioText];
            [DYYYToast showSuccessToastWithMessage:@"个人简介已复制"];
        }
    }
}

%end

// 默认视频流最高画质
%hook AWEVideoModel

- (AWEURLModel *)playURL {
    if (!DYYYGetBool(@"DYYYEnableVideoHighestQuality")) {
        return %orig;
    }

    AWEURLModel *defaultPlayURL = %orig;

    // 获取比特率模型数组
    NSArray *bitrateModels = [self bitrateModels];
    if (!bitrateModels || bitrateModels.count == 0) {
        return defaultPlayURL;
    }

    // 查找比特率最高的模型
    id highestBitrateModel = nil;
    NSInteger highestBitrate = 0;

    for (id model in bitrateModels) {
        NSInteger bitrate = 0;
        BOOL validModel = NO;

        if ([model isKindOfClass:NSClassFromString(@"AWEVideoBSModel")]) {
            id bitrateValue = [model bitrate];
            if (bitrateValue) {
                bitrate = [bitrateValue integerValue];
                validModel = YES;
            }
        }

        if (validModel && bitrate > highestBitrate) {
            highestBitrate = bitrate;
            highestBitrateModel = model;
        }
    }

    // 如果找到了最高比特率模型，获取其播放地址
    if (highestBitrateModel) {
        id playAddr = [highestBitrateModel valueForKey:@"playAddr"];
        if (playAddr && [playAddr isKindOfClass:%c(AWEURLModel)]) {
            // 2.2-9-17 原画直连实验（用户 2026-11-02 批准试用）：
            // 原“提高画质”只挑转码版本里最高的一档，仍是 CDN 转码地址，不是原文件。
            // 现在优先用原文件地址：先看最高档 playAddr 自身的 originURLList，
            // 再看默认 playURL 的 originURLList，挑含 video_mp4 的那条，否则取首条。
            // 拿到后直接改写该 playAddr 模型的地址列表（保留宽高、URI 等其他属性，
            // 播放器无论从 originURLList 还是 urlList 取地址都能拿到原文件），
            // 拿不到原文件时回落到原来的最高转码档，绝不因原画失败而播不了。
            // 开关仍是“提高视频画质”，关掉开关即回到抖音默认，不用换包。
            NSString *originURLString = nil;
            NSArray *candidates = nil;
            @try {
                candidates = [(AWEURLModel *)playAddr originURLList];
            } @catch (__unused NSException *e) {
                candidates = nil;
            }
            if (!candidates || candidates.count == 0) {
                candidates = defaultPlayURL ? defaultPlayURL.originURLList : nil;
            }
            if (candidates && candidates.count > 0) {
                for (id urlObj in candidates) {
                    if ([urlObj isKindOfClass:[NSString class]] && [urlObj containsString:@"video_mp4"]) {
                        originURLString = urlObj;
                        break;
                    }
                }
                if (!originURLString) {
                    id firstObj = candidates.firstObject;
                    if ([firstObj isKindOfClass:[NSString class]]) {
                        originURLString = firstObj;
                    }
                }
            }
            if (originURLString.length > 0) {
                @try {
                    ((AWEURLModel *)playAddr).originURLList = @[ originURLString ];
                } @catch (__unused NSException *e) {
                }
                @try {
                    [playAddr setValue:@[ originURLString ] forKey:@"urlList"];
                } @catch (__unused NSException *e) {
                }
            }
            return playAddr;
        }
    }

    return defaultPlayURL;
}

- (NSArray *)bitrateModels {

    NSArray *originalModels = %orig;

    if (!DYYYGetBool(@"DYYYEnableVideoHighestQuality")) {
        return originalModels;
    }

    if (originalModels.count == 0) {
        return originalModels;
    }

    // 查找比特率最高的模型
    id highestBitrateModel = nil;
    NSInteger highestBitrate = 0;

    for (id model in originalModels) {

        NSInteger bitrate = 0;
        BOOL validModel = NO;

        if ([model isKindOfClass:NSClassFromString(@"AWEVideoBSModel")]) {
            id bitrateValue = [model bitrate];
            if (bitrateValue) {
                bitrate = [bitrateValue integerValue];
                validModel = YES;
            }
        }

        if (validModel) {
            if (bitrate > highestBitrate) {
                highestBitrate = bitrate;
                highestBitrateModel = model;
            }
        }
    }

    if (highestBitrateModel) {
        return @[ highestBitrateModel ];
    }

    return originalModels;
}

%end

// 直播间真实人数（万显示：沿用 2.3 二进制补丁已确认的规则）
// >=10000 显示万、四舍五入 2 位小数、末尾 0 去掉；<10000 原样。
// 例：484499 -> 48.45万，12500 -> 1.25万，10000 -> 1万，64337 -> 6.43万，9999 -> 9999
%hook IESLiveUserSeqlistFragment

- (void)refreshVerticalUserCount:(id)arg1 horizontalUserCount:(id)arg2 trueValue:(NSInteger)trueValue {
    if ( trueValue > 0 && DYYYGetBool(@"DYYYEnableLiveRealCount") ) {
        NSString *realStr;
        if (trueValue >= 10000) {
            NSString *wan = [NSString stringWithFormat:@"%.2f万", trueValue / 10000.0];
            // 去掉末尾 0 和多余的小数点：48.40万 -> 48.4万，1.00万 -> 1万
            while ([wan hasSuffix:@"0万"]) {
                wan = [wan substringToIndex:wan.length - 2];
                wan = [wan stringByAppendingString:@"万"];
            }
            if ([wan hasSuffix:@".万"]) {
                wan = [wan stringByReplacingOccurrencesOfString:@".万" withString:@"万"];
            }
            realStr = wan;
        } else {
            realStr = [NSString stringWithFormat:@"%ld", (long)trueValue];
        }
        %orig(realStr, realStr, trueValue);
    } else {
        %orig;
    }
}

%end

// 评论具体时间
%hook AWEDateTimeFormatter

+ (id)formattedDateForTimestamp:(double)timestamp {
    if (!DYYYGetBool(@"DYYYCommentExactTime")) return %orig(timestamp);
    return [NSString stringWithFormat:@"%.0f ", timestamp];
}

%end

%hook AWERLVirtualLabel

- (void)setText:(NSString *)text {
    if (!DYYYGetBool(@"DYYYCommentExactTime") || !text || text.length == 0) {
        %orig(text);
        return;
    }

    if ([text isEqualToString:@"回复"]) {
        %orig(@"");
        return;
    }

    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^(\\d{10,13})([\\s\\S]*)" options:0 error:&error];
    
    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];

    if (match) {
        NSString *rawTs = [text substringWithRange:[match rangeAtIndex:1]];
        NSString *suffix = [text substringWithRange:[match rangeAtIndex:2]];
        
        long long ts = [rawTs longLongValue];
        
        if (ts > 100000000000) {
            ts = ts / 1000;
        }
        
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:ts];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
        NSString *formattedDate = [formatter stringFromDate:date];
        
        NSString *newText = [NSString stringWithFormat:@"%@%@", formattedDate, suffix];
        %orig(newText);
    } else {
        %orig(text);
    }
}

%end

%group DYYYCommentExactTimeGroup
%hook AWECommentSwiftBizUI_CommentInteractionBaseLabel

- (void)setText:(NSString *)text {
    %orig(text); // 先让系统把文本赋上去
    
    if (!DYYYGetBool(@"DYYYCommentExactTime")) {
        return;
    }

    UILabel *label = (UILabel *)self;
    if (!text || text.length == 0) return;

    // --- 1. 拦截翻译文本，将其绝对定位在屏幕右侧 100 像素 ---
    if ([text isEqualToString:@"翻译"] || [text isEqualToString:@"隐藏翻译"]) {
        CGRect currentFrame = label.frame;
        CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
        // 重新计算 X 坐标：屏幕宽度 - 100 - 标签自身宽度
        currentFrame.origin.x = screenWidth - 100.0 - currentFrame.size.width;
        label.frame = currentFrame;
        return;
    }

    // --- 2. 拦截时间文本，如果不够宽则扩充宽度 ---
    UIFont *font = label.font;
    if (font) {
        CGFloat expectedWidth = ceilf([text sizeWithAttributes:@{NSFontAttributeName: font}].width);
        CGRect currentFrame = label.frame;
        
        // 如果当前宽度不够，并且不是尚未初始化的状态（>0），则强行修改并重新赋值
        if (currentFrame.size.width < expectedWidth && currentFrame.size.width > 0) {
            currentFrame.size.width = expectedWidth;
            label.frame = currentFrame; 
            label.clipsToBounds = NO;
        }
    }
}

- (void)setFrame:(CGRect)frame {
    if (!DYYYGetBool(@"DYYYCommentExactTime") || ![self respondsToSelector:@selector(text)]) {
        %orig(frame);
        return;
    }

    UILabel *label = (UILabel *)self;
    NSString *text = label.text;

    if (text && text.length > 0) {
        // --- 1. 拦截翻译文本，将其绝对定位在屏幕右侧 100 像素 ---
        if ([text isEqualToString:@"翻译"] || [text isEqualToString:@"隐藏翻译"]) {
            CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
            frame.origin.x = screenWidth - 100.0 - frame.size.width;
        } 
        // --- 2. 拦截时间文本，如果不够宽则扩充宽度 ---
        else if ([self respondsToSelector:@selector(font)]) {
            UIFont *font = label.font;
            if (font) {
                CGFloat expectedWidth = ceilf([text sizeWithAttributes:@{NSFontAttributeName: font}].width);
                if (frame.size.width < expectedWidth && frame.size.width > 0) {
                    frame.size.width = expectedWidth;
                    label.clipsToBounds = NO;
                }
            }
        }
    }

    %orig(frame);
}

%end
%end

// 前面的AWEDateTimeFormatter会导致图文视频展开时间文本变成时间戳，这里处理下
%hook YYLabel

// 1. Hook 富文本赋值方法 (核心)
- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (!DYYYGetBool(@"DYYYCommentExactTime") || !attributedText || attributedText.length == 0) {
        %orig(attributedText);
        return;
    }

    NSString *plainText = [attributedText string];

    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^(\\d{10,13})" options:0 error:&error];
    NSTextCheckingResult *match = [regex firstMatchInString:plainText options:0 range:NSMakeRange(0, plainText.length)];

    if (match) {
        NSString *rawTs = [plainText substringWithRange:[match rangeAtIndex:1]];
        long long ts = [rawTs longLongValue];
        
        if (ts > 100000000000) {
            ts = ts / 1000;
        }
        
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:ts];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
        NSString *formattedDate = [formatter stringFromDate:date];
        
        NSMutableAttributedString *newAttrStr = [attributedText mutableCopy];
        [newAttrStr replaceCharactersInRange:[match rangeAtIndex:1] withString:formattedDate];
        
        %orig(newAttrStr);
    } else {
        %orig(attributedText);
    }
}

%end

// 禁用自动进入直播间
%hook AWELiveGuideElement

- (BOOL)enableAutoEnterRoom {
    if (DYYYGetBool(@"DYYYDisableAutoEnterLive")) {
        return NO;
    }
    return %orig;
}

- (BOOL)enableNewAutoEnter {
    if (DYYYGetBool(@"DYYYDisableAutoEnterLive")) {
        return NO;
    }
    return %orig;
}

%end

%hook AWEFeedChannelManager

- (void)reloadChannelWithChannelModels:(id)arg1 currentChannelIDList:(id)arg2 reloadType:(id)arg3 selectedChannelID:(id)arg4 {
    NSArray *channelModels = arg1;
    NSMutableArray *newChannelModels = [NSMutableArray array];
    NSArray *currentChannelIDList = arg2;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray *newCurrentChannelIDList = [NSMutableArray arrayWithArray:currentChannelIDList];

    if (!arg1 || !arg2) {
        %orig(arg1, arg2, arg3, arg4);
        return;
    }

    if (![channelModels isKindOfClass:[NSArray class]] || ![currentChannelIDList isKindOfClass:[NSArray class]]) {
        %orig(arg1, arg2, arg3, arg4);
        return;
    }

    if (channelModels.count == 0) {
        %orig(arg1, arg2, arg3, arg4);
        return;
    }

    for (AWEHPTopTabItemModel *tabItemModel in channelModels) {
        NSString *channelID = tabItemModel.channelID;
        BOOL isHideChannel = NO;

        if ([channelID isEqualToString:@"homepage_hot_container"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideHotContainer"];
        } else if ([channelID isEqualToString:@"homepage_follow"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideFollow"];
        } else if ([channelID isEqualToString:@"homepage_mall"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideMall"];
        } else if ([channelID isEqualToString:@"homepage_nearby"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideNearby"];
        } else if ([channelID isEqualToString:@"homepage_groupon"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideGroupon"];
        } else if ([channelID isEqualToString:@"homepage_tablive"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideTabLive"];
        } else if ([channelID isEqualToString:@"homepage_pad_hot"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHidePadHot"];
        } else if ([channelID isEqualToString:@"homepage_hangout"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideHangout"];
        } else if ([channelID isEqualToString:@"homepage_familiar"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideFriend"];
        } else if ([channelID isEqualToString:@"homepage_playlet_stream"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHidePlaylet"];
        } else if ([channelID isEqualToString:@"homepage_pad_cinema"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideCinema"];
        } else if ([channelID isEqualToString:@"homepage_pad_kids_v2"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideKidsV2"];
        } else if ([channelID isEqualToString:@"homepage_pad_game"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideGame"];
        } else if ([channelID isEqualToString:@"homepage_mediumvideo"]) {
            isHideChannel = [defaults boolForKey:@"DYYYHideMediumVideo"];
        }

        if (!isHideChannel) {
            [newChannelModels addObject:tabItemModel];
        } else {
            [newCurrentChannelIDList removeObject:channelID];
        }
    }

    %orig(newChannelModels, newCurrentChannelIDList, arg3, arg4);
}

%end

%hook AWELandscapeFeedViewController
- (void)viewDidLoad {
    %orig;

    // 尝试优先走属性
    gFeedCV = self.collectionView;

    // 保险起见再fallback,遍历 subviews
    if (!gFeedCV) {
        gFeedCV = [DYYYUtils findSubviewOfClass:[UICollectionView class] inContainer:self.view];
    }
}
%end

%hook UICollectionView

// 拦截手指拖动
- (void)handlePan:(UIPanGestureRecognizer *)pan {

    /* 仅处理横屏Feed列表。其余collectionView直接走系统逻辑 */
    if (self != gFeedCV || !DYYYGetBool(@"DYYYVideoGesture")) {
        %orig;
        return;
    }

    /* 取触点坐标、手势状态 */
    CGPoint loc = [pan locationInView:self];
    CGFloat w = self.bounds.size.width;
    CGFloat xPct = loc.x / w; // 0.0 ~ 1.0
    UIGestureRecognizerState st = pan.state;

    /* BEGAN：判定左右 20 % 区域 → 进入亮度 / 音量模式 */
    if (st == UIGestureRecognizerStateBegan) {

        gStartY = loc.y;

        if (xPct <= 0.20) { // 左边缘 → 亮度
            gMode = DYEdgeModeBrightness;
            gStartVal = [UIScreen mainScreen].brightness;

        } else if (xPct >= 0.80) { // 右边缘 → 音量
            gMode = DYEdgeModeVolume;
            gStartVal = [[objc_getClass("AVSystemController") sharedAVSystemController] volumeForCategory:@"Audio/Video"];

        } else {
            gMode = DYEdgeModeNone; // 中间区域走原逻辑
        }
    }

    /* 调节阶段：左右边缘时吞掉滚动、修改亮度/音量 */
    if (gMode != DYEdgeModeNone) {

        if (st == UIGestureRecognizerStateChanged) {

            CGFloat delta = (gStartY - loc.y) / self.bounds.size.height; // ↑ 为正
            const CGFloat kScale = 2.0;                                  // 灵敏度
            float newVal = gStartVal + delta * kScale;
            newVal = fminf(fmaxf(newVal, 0.0), 1.0); // Clamp 0~1

            if (gMode == DYEdgeModeBrightness) {
                [UIScreen mainScreen].brightness = newVal;
                // 弹系统亮度 HUD
                [[%c(SBHUDController) sharedInstance] presentHUDWithIcon:@"Brightness" level:newVal];

            } else { // DYEdgeModeVolume
                // iOS 18 音量控制 + 系统音量 HUD
                [[objc_getClass("AVSystemController") sharedAVSystemController] setVolumeTo:newVal forCategory:@"Audio/Video"];
            }

            // 吞掉滚动：归零 translation，防止内容位移
            [pan setTranslation:CGPointZero inView:self];
        }

        /* 结束／取消：状态复位 */
        if (st == UIGestureRecognizerStateEnded || st == UIGestureRecognizerStateCancelled || st == UIGestureRecognizerStateFailed) {
            gMode = DYEdgeModeNone;
        }

        return; // 左右边缘：彻底阻断 %orig，避免翻页
    }

    /* 中间区域：直接执行原先翻页逻辑 */
    %orig;
}

%end

%hook AWELeftSideBarAddChildTransitionObject

- (void)handleShowSliderPanGesture:(id)gr {
    if (DYYYGetBool(@"DYYYDisableSidebarGesture")) {
        return;
    }
    %orig(gr);
}

%end

%hook AWEPlayInteractionUserAvatarElement
- (void)onFollowViewClicked:(UITapGestureRecognizer *)gesture {
    if (DYYYGetBool(@"DYYYFollowTips")) {
        // 获取用户信息
        AWEUserModel *author = nil;
        NSString *nickname = @"";
        NSString *signature = @"";
        NSString *avatarURL = @"";

        if ([self respondsToSelector:@selector(model)]) {
            id model = [self model];
            if ([model isKindOfClass:NSClassFromString(@"AWEAwemeModel")]) {
                author = [model valueForKey:@"author"];
            }
        }

        if (author) {
            // 获取昵称
            if ([author respondsToSelector:@selector(nickname)]) {
                nickname = [author valueForKey:@"nickname"] ?: @"";
            }

            // 获取签名
            if ([author respondsToSelector:@selector(signature)]) {
                signature = [author valueForKey:@"signature"] ?: @"";
            }

            // 获取头像URL
            if ([author respondsToSelector:@selector(avatarThumb)]) {
                AWEURLModel *avatarThumb = [author valueForKey:@"avatarThumb"];
                if (avatarThumb && avatarThumb.originURLList.count > 0) {
                    avatarURL = avatarThumb.originURLList.firstObject;
                }
            }
        }

        NSMutableString *messageContent = [NSMutableString string];
        if (signature.length > 0) {
            [messageContent appendFormat:@"%@", signature];
        }

        NSString *title = nickname.length > 0 ? nickname : @"关注确认";

        [DYYYBottomAlertView showAlertWithTitle:title
                                        message:messageContent
                                      avatarURL:avatarURL
                               cancelButtonText:@"取消"
                              confirmButtonText:@"关注"
                                   cancelAction:nil
                                    closeAction:nil
                                  confirmAction:^{
                                    %orig(gesture);
                                  }];
    } else {
        %orig;
    }
}

%end

%hook AWEPlayInteractionUserAvatarFollowController
- (void)onFollowViewClicked:(UITapGestureRecognizer *)gesture {
    if (DYYYGetBool(@"DYYYFollowTips")) {
        // 获取用户信息
        AWEUserModel *author = nil;
        NSString *nickname = @"";
        NSString *signature = @"";
        NSString *avatarURL = @"";

        if ([self respondsToSelector:@selector(model)]) {
            id model = [self model];
            if ([model isKindOfClass:NSClassFromString(@"AWEAwemeModel")]) {
                author = [model valueForKey:@"author"];
            }
        }

        if (author) {
            // 获取昵称
            if ([author respondsToSelector:@selector(nickname)]) {
                nickname = [author valueForKey:@"nickname"] ?: @"";
            }

            // 获取签名
            if ([author respondsToSelector:@selector(signature)]) {
                signature = [author valueForKey:@"signature"] ?: @"";
            }

            // 获取头像URL
            if ([author respondsToSelector:@selector(avatarThumb)]) {
                AWEURLModel *avatarThumb = [author valueForKey:@"avatarThumb"];
                if (avatarThumb && avatarThumb.originURLList.count > 0) {
                    avatarURL = avatarThumb.originURLList.firstObject;
                }
            }
        }

        NSMutableString *messageContent = [NSMutableString string];
        if (signature.length > 0) {
            [messageContent appendFormat:@"%@", signature];
        }

        NSString *title = nickname.length > 0 ? nickname : @"关注确认";

        [DYYYBottomAlertView showAlertWithTitle:title
                                        message:messageContent
                                      avatarURL:avatarURL
                               cancelButtonText:@"取消"
                              confirmButtonText:@"关注"
                                   cancelAction:nil
                                    closeAction:nil
                                  confirmAction:^{
                                    %orig(gesture);
                                  }];
    } else {
        %orig;
    }
}

%end

%hook AWEFeedTopBarContainer
- (void)didMoveToSuperview {
    %orig;
    applyTopBarTransparency(self);
}
- (void)setAlpha:(CGFloat)alpha {
    NSString *transparentValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYTopBarTransparent"];
    if (transparentValue && transparentValue.length > 0) {
        CGFloat alphaValue = [transparentValue floatValue];
        if (alphaValue >= 0.0 && alphaValue <= 1.0) {
            CGFloat finalAlpha = (alphaValue < 0.011) ? 0.011 : alphaValue;
            %orig(finalAlpha);
        } else {
            %orig(1.0);
        }
    } else {
        %orig(1.0);
    }
}
%end

// 设置修改顶栏标题
%hook AWEHPTopTabItemTextContentView

- (void)layoutSubviews {
    %orig;
    NSDictionary<NSString *, NSString *> *titleMapping = DYYYTopTabTitleMapping();
    if (titleMapping.count == 0) {
        return;
    }

    NSString *accessibilityLabel = nil;
    if ([self.superview respondsToSelector:@selector(accessibilityLabel)]) {
        accessibilityLabel = self.superview.accessibilityLabel;
    }
    if (accessibilityLabel.length == 0) {
        return;
    }

    NSString *newTitle = titleMapping[accessibilityLabel];
    if (newTitle.length == 0) {
        return;
    }

    if ([self respondsToSelector:@selector(setContentText:)]) {
        [self setContentText:newTitle];
    } else {
        [self setValue:newTitle forKey:@"contentText"];
    }
}

%end

%hook AWEDanmakuContentLabel
- (void)setTextColor:(UIColor *)textColor {
    if (DYYYGetBool(@"DYYYEnableDanmuColor")) {
        NSString *danmuColor = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYDanmuColor"];
        if (DYYYGetBool(@"DYYYDanmuRainbowRotating")) {
            danmuColor = @"rainbow_rotating";
        }
        [DYYYUtils applyColorSettingsToLabel:self colorHexString:danmuColor];
    } else {
        %orig(textColor);
    }
}

- (void)setStrokeWidth:(double)strokeWidth {
    if (DYYYGetBool(@"DYYYEnableDanmuColor")) {
        %orig(FLT_MIN);
    } else {
        %orig(strokeWidth);
    }
}

- (void)setStrokeColor:(UIColor *)strokeColor {
    if (DYYYGetBool(@"DYYYEnableDanmuColor")) {
        %orig(nil);
    } else {
        %orig(strokeColor);
    }
}

%end

%hook XIGDanmakuPlayerView

- (id)initWithFrame:(CGRect)frame {
    id orig = %orig;

    ((UIView *)orig).tag = DYYY_IGNORE_GLOBAL_ALPHA_TAG;

    return orig;
}

- (void)setAlpha:(CGFloat)alpha {
    if (DYYYGetBool(@"DYYYCommentShowDanmaku") && alpha == 0.0) {
        return;
    } else {
        %orig(alpha);
    }
}

%end

%hook DDanmakuPlayerView

- (void)setAlpha:(CGFloat)alpha {
    if (DYYYGetBool(@"DYYYCommentShowDanmaku") && alpha == 0.0) {
        return;
    } else {
        %orig(alpha);
    }
}

%end

%hook AWEMarkView

- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYHideLocation")) {
        self.hidden = YES;
        return;
    }
}

%end

%group DYYYSettingsGesture

%hook UIWindow
- (instancetype)initWithFrame:(CGRect)frame {
    UIWindow *window = %orig(frame);
    if (window) {
        UILongPressGestureRecognizer *doubleFingerLongPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleFingerLongPressGesture:)];
        doubleFingerLongPressGesture.numberOfTouchesRequired = 2;
        [window addGestureRecognizer:doubleFingerLongPressGesture];
    }
    return window;
}

%new
- (void)handleDoubleFingerLongPressGesture:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        UIViewController *rootViewController = self.rootViewController;
        if (rootViewController) {
            UIViewController *settingVC = [[DYYYSettingViewController alloc] init];

            if (settingVC) {
                BOOL isIPad = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
                if (@available(iOS 15.0, *)) {
                    if (!isIPad) {
                        settingVC.modalPresentationStyle = UIModalPresentationPageSheet;
                    } else {
                        settingVC.modalPresentationStyle = UIModalPresentationFullScreen;
                    }
                } else {
                    settingVC.modalPresentationStyle = UIModalPresentationFullScreen;
                }

                if (settingVC.modalPresentationStyle == UIModalPresentationFullScreen) {
                    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
                    [closeButton setTitle:@"关闭" forState:UIControlStateNormal];
                    closeButton.translatesAutoresizingMaskIntoConstraints = NO;

                    [settingVC.view addSubview:closeButton];

                    [NSLayoutConstraint activateConstraints:@[
                        [closeButton.trailingAnchor constraintEqualToAnchor:settingVC.view.trailingAnchor constant:-10],
                        [closeButton.topAnchor constraintEqualToAnchor:settingVC.view.topAnchor constant:40], [closeButton.widthAnchor constraintEqualToConstant:80],
                        [closeButton.heightAnchor constraintEqualToConstant:40]
                    ]];

                    [closeButton addTarget:self action:@selector(closeSettings:) forControlEvents:UIControlEventTouchUpInside];
                }

                UIView *handleBar = [[UIView alloc] init];
                handleBar.backgroundColor = [UIColor whiteColor];
                handleBar.layer.cornerRadius = 2.5;
                handleBar.translatesAutoresizingMaskIntoConstraints = NO;
                [settingVC.view addSubview:handleBar];

                [NSLayoutConstraint activateConstraints:@[
                    [handleBar.centerXAnchor constraintEqualToAnchor:settingVC.view.centerXAnchor], [handleBar.topAnchor constraintEqualToAnchor:settingVC.view.topAnchor constant:8],
                    [handleBar.widthAnchor constraintEqualToConstant:40], [handleBar.heightAnchor constraintEqualToConstant:5]
                ]];

                [rootViewController presentViewController:settingVC animated:YES completion:nil];
            }
        }
    }
}

%new
- (void)closeSettings:(UIButton *)button {
    [button.superview.window.rootViewController dismissViewControllerAnimated:YES completion:nil];
}

- (void)makeKeyAndVisible {
    %orig;

    if (!isFloatSpeedButtonEnabled)
        return;

    if (speedButton && ![speedButton isDescendantOfView:self]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self addSubview:speedButton];
          [speedButton loadSavedPosition];
          [speedButton resetFadeTimer];
        });
    }
}
%end

%end

%hook AWEBaseListViewController
- (void)viewDidLayoutSubviews {
    %orig;
    [self applyBlurEffectIfNeeded];
}

%new
- (void)applyBlurEffectIfNeeded {
    if (DYYYGetBool(@"DYYYEnableCommentBlur") && [self isKindOfClass:NSClassFromString(@"AWECommentPanelContainerSwiftImpl.CommentContainerInnerViewController")]) {
        // 动态获取用户设置的透明度
        float userTransparency = [[[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYCommentBlurTransparent"] floatValue];
        if (userTransparency <= 0 || userTransparency > 1) {
            userTransparency = 0.9;
        }

        // 应用毛玻璃效果
        [DYYYUtils applyBlurEffectToView:self.view transparency:userTransparency blurViewTag:999];
    }
}
%end

%hook AWEFeedVideoButton
- (id)touchUpInsideBlock {
    id r = %orig;

    // 只有收藏按钮才显示确认弹窗
    if (DYYYGetBool(@"DYYYCollectTips") && [self.accessibilityLabel isEqualToString:@"收藏"]) {

        dispatch_async(dispatch_get_main_queue(), ^{
          [DYYYBottomAlertView showAlertWithTitle:@"收藏确认"
                                          message:@"是否确认/取消收藏？"
                                        avatarURL:nil
                                 cancelButtonText:nil
                                confirmButtonText:nil
                                     cancelAction:nil
                                      closeAction:nil
                                    confirmAction:^{
                                      if (r && [r isKindOfClass:NSClassFromString(@"NSBlock")]) {
                                          ((void (^)(void))r)();
                                      }
                                    }];
        });

        return nil;
    }

    return r;
}
%end

%hook AWEPlayInteractionProgressContainerView
- (void)layoutSubviews {
    %orig;

    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYEnableFullScreen"]) {
        return;
    }

    static char kDYProgressBgKey;
    NSArray *bgViews = objc_getAssociatedObject(self, &kDYProgressBgKey);
    if (!bgViews) {
        NSMutableArray *tmp = [NSMutableArray array];
        for (UIView *subview in self.subviews) {
            if ([subview class] == [UIView class]) {
                [tmp addObject:subview];
            }
        }
        bgViews = [tmp copy];
        objc_setAssociatedObject(self, &kDYProgressBgKey, bgViews, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    for (UIView *v in bgViews) {
        v.backgroundColor = [UIColor clearColor];
    }
}

%end

%hook AWEFeedProgressSlider

- (void)setAlpha:(CGFloat)alpha {
    if (DYYYGetBool(@"DYYYShowScheduleDisplay")) {
        if (DYYYGetBool(@"DYYYHideVideoProgress")) {
            %orig(0);
        } else {
            %orig(1.0);
        }
    } else {
        %orig;
    }
}

%new
- (NSString *)dyyy_formatTimeFromSeconds:(CGFloat)seconds {
    CGFloat safeSeconds = seconds;
    if (safeSeconds < 0) {
        safeSeconds = 0;
    }

    NSInteger total = (NSInteger)floor(safeSeconds);
    NSInteger hours = total / 3600;
    NSInteger minutes = (total % 3600) / 60;
    NSInteger secs = total % 60;

    if (hours > 0) {
        return [NSString stringWithFormat:@"%02ld:%02ld:%02ld", (long)hours, (long)minutes, (long)secs];
    }
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)minutes, (long)secs];
}

%new
- (CGFloat)dyyy_modelDurationInSeconds {
    id delegate = self.progressSliderDelegate;
    if (!delegate || ![delegate respondsToSelector:@selector(model)]) {
        return 0;
    }

    id model = [delegate valueForKey:@"model"];
    if (!model || ![model respondsToSelector:@selector(videoDuration)]) {
        return 0;
    }

    CGFloat videoDurationMs = [[model valueForKey:@"videoDuration"] doubleValue];
    if (videoDurationMs <= 0) {
        return 0;
    }
    return videoDurationMs / 1000.0;
}

%new
- (CGFloat)dyyy_scheduleVerticalOffset {
    CGFloat verticalOffset = -12.5;
    NSString *offsetValueString = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYTimelineVerticalPosition"];
    if (offsetValueString.length > 0) {
        CGFloat configuredOffset = [offsetValueString floatValue];
        if (configuredOffset != 0) {
            verticalOffset = configuredOffset;
        }
    }
    return verticalOffset;
}

%new
- (void)dyyy_removeScheduleLabels {
    UIView *parentView = self.superview;
    if (!parentView) {
        return;
    }
    [parentView layoutIfNeeded];
    [self layoutIfNeeded];
    [[parentView viewWithTag:10001] removeFromSuperview];
    [[parentView viewWithTag:10002] removeFromSuperview];
}

%new
- (void)dyyy_updateScheduleLabelsWithCurrentTime:(CGFloat)currentTime totalDuration:(CGFloat)totalDuration {
    if (!DYYYGetBool(@"DYYYShowScheduleDisplay")) {
        [self dyyy_removeScheduleLabels];
        return;
    }

    if (![NSThread isMainThread]) {
        __weak __typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
          [weakSelf dyyy_updateScheduleLabelsWithCurrentTime:currentTime totalDuration:totalDuration];
        });
        return;
    }

    UIView *parentView = self.superview;
    if (!parentView) {
        return;
    }
    [parentView layoutIfNeeded];
    [self layoutIfNeeded];

    NSString *scheduleStyle = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYScheduleStyle"];
    BOOL showRightRemainingTime = [scheduleStyle isEqualToString:@"进度条右侧剩余"];
    BOOL showRightCompleteTime = [scheduleStyle isEqualToString:@"进度条右侧完整"];
    BOOL showLeftRemainingTime = [scheduleStyle isEqualToString:@"进度条左侧剩余"];
    BOOL showLeftCompleteTime = [scheduleStyle isEqualToString:@"进度条左侧完整"];

    BOOL shouldShowLeftLabel = !showRightRemainingTime && !showRightCompleteTime;
    BOOL shouldShowRightLabel = !showLeftRemainingTime && !showLeftCompleteTime;

    CGFloat modelDuration = [self dyyy_modelDurationInSeconds];
    CGFloat effectiveTotalDuration = totalDuration > 0 ? totalDuration : modelDuration;
    if (effectiveTotalDuration < 0) {
        effectiveTotalDuration = 0;
    }

    CGFloat effectiveCurrentTime = currentTime;
    if (effectiveCurrentTime < 0) {
        effectiveCurrentTime = 0;
    }
    if (effectiveTotalDuration > 0 && effectiveCurrentTime > effectiveTotalDuration) {
        effectiveCurrentTime = effectiveTotalDuration;
    }

    CGRect sliderFrameInParent = [self convertRect:self.bounds toView:parentView];
    if (CGRectGetWidth(sliderFrameInParent) <= 1.0 || CGRectGetHeight(sliderFrameInParent) <= 1.0) {
        return;
    }
    CGFloat labelYPosition = CGRectGetMinY(sliderFrameInParent) + [self dyyy_scheduleVerticalOffset];
    CGFloat labelHeight = 15.0;
    UIFont *labelFont = [UIFont systemFontOfSize:8];
    NSString *labelColorHex = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYProgressLabelColor"];

    UILabel *leftLabel = (UILabel *)[parentView viewWithTag:10001];
    if (leftLabel && ![leftLabel isKindOfClass:[UILabel class]]) {
        [leftLabel removeFromSuperview];
        leftLabel = nil;
    }

    if (shouldShowLeftLabel) {
        if (!leftLabel) {
            leftLabel = [[UILabel alloc] init];
            leftLabel.backgroundColor = [UIColor clearColor];
            leftLabel.tag = 10001;
            [parentView addSubview:leftLabel];
        }

        leftLabel.font = labelFont;
        NSString *newLeftText = nil;
        if (showLeftRemainingTime) {
            newLeftText = [self dyyy_formatTimeFromSeconds:MAX(effectiveTotalDuration - effectiveCurrentTime, 0)];
        } else if (showLeftCompleteTime) {
            newLeftText = [NSString stringWithFormat:@"%@/%@", [self dyyy_formatTimeFromSeconds:effectiveCurrentTime], [self dyyy_formatTimeFromSeconds:effectiveTotalDuration]];
        } else {
            newLeftText = [self dyyy_formatTimeFromSeconds:effectiveCurrentTime];
        }

        if (![leftLabel.text isEqualToString:newLeftText]) {
            leftLabel.text = newLeftText;
        }
        [leftLabel sizeToFit];
        leftLabel.frame = CGRectMake(CGRectGetMinX(sliderFrameInParent), labelYPosition, CGRectGetWidth(leftLabel.bounds), labelHeight);
        [DYYYUtils applyColorSettingsToLabel:leftLabel colorHexString:labelColorHex];
    } else {
        [leftLabel removeFromSuperview];
    }

    UILabel *rightLabel = (UILabel *)[parentView viewWithTag:10002];
    if (rightLabel && ![rightLabel isKindOfClass:[UILabel class]]) {
        [rightLabel removeFromSuperview];
        rightLabel = nil;
    }

    if (shouldShowRightLabel) {
        if (!rightLabel) {
            rightLabel = [[UILabel alloc] init];
            rightLabel.backgroundColor = [UIColor clearColor];
            rightLabel.tag = 10002;
            [parentView addSubview:rightLabel];
        }

        rightLabel.font = labelFont;
        NSString *newRightText = nil;
        if (showRightRemainingTime) {
            newRightText = [self dyyy_formatTimeFromSeconds:MAX(effectiveTotalDuration - effectiveCurrentTime, 0)];
        } else if (showRightCompleteTime) {
            newRightText = [NSString stringWithFormat:@"%@/%@", [self dyyy_formatTimeFromSeconds:effectiveCurrentTime], [self dyyy_formatTimeFromSeconds:effectiveTotalDuration]];
        } else {
            newRightText = [self dyyy_formatTimeFromSeconds:effectiveTotalDuration];
        }

        if (![rightLabel.text isEqualToString:newRightText]) {
            rightLabel.text = newRightText;
        }
        [rightLabel sizeToFit];
        CGFloat rightLabelX = MAX(CGRectGetMaxX(sliderFrameInParent) - CGRectGetWidth(rightLabel.bounds), CGRectGetMinX(sliderFrameInParent));
        rightLabel.frame = CGRectMake(rightLabelX, labelYPosition, CGRectGetWidth(rightLabel.bounds), labelHeight);
        [DYYYUtils applyColorSettingsToLabel:rightLabel colorHexString:labelColorHex];
    } else {
        [rightLabel removeFromSuperview];
    }
}

- (void)setLimitUpperActionArea:(BOOL)arg1 {
    %orig;
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      [weakSelf dyyy_updateScheduleLabelsWithCurrentTime:0 totalDuration:0];
    });
}

- (void)setHidden:(BOOL)hidden {
    %orig;
    BOOL hideVideoProgress = DYYYGetBool(@"DYYYHideVideoProgress");
    BOOL showScheduleDisplay = DYYYGetBool(@"DYYYShowScheduleDisplay");
    if (hideVideoProgress && showScheduleDisplay && !hidden) {
        self.alpha = 0;
    }
}

%end

%hook AWEPlayInteractionTimestampElement

- (id)timestampLabel {
    UILabel *label = %orig;
    BOOL isEnableArea = DYYYGetBool(@"DYYYEnableArea");
    if (!isEnableArea) {
        return label;
    }

    NSString *labelColorHex = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYLabelColor"];
    if (DYYYGetBool(@"DYYYEnableRandomGradient")) {
        labelColorHex = @"random_gradient";
    }

    BOOL boldEnabled = DYYYGetBool(@"DYYYBoldTimestamp");
    if (boldEnabled && label.font) {
        UIFont *boldFont = [UIFont boldSystemFontOfSize:label.font.pointSize];
        label.font = boldFont;
    }

    NSString *cityCode = self.model.cityCode;
    NSString *regionCode = nil;
    if ([self.model respondsToSelector:@selector(region)]) {
        regionCode = [self.model performSelector:@selector(region)];
    }

    if (cityCode && ([cityCode isEqualToString:@"0"] || [cityCode integerValue] == 0)) {
        cityCode = nil;
    }

    static NSCache *locationCache;
    static NSMutableSet *inFlight;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        locationCache = [[NSCache alloc] init];
        locationCache.countLimit = 100;
        inFlight = [[NSMutableSet alloc] init];
    });

    void (^updateLabelWithLocation)(UILabel *, NSString *) = ^(UILabel *lbl, NSString *location) {
        if (location.length == 0) return;

        NSString *currentText = lbl.text ?: @"";
        if ([currentText containsString:location]) return;

        if ([currentText containsString:@"IP属地："]) {
            NSRange range = [currentText rangeOfString:@"IP属地："];
            NSString *baseText = [currentText substringToIndex:range.location];
            lbl.text = [NSString stringWithFormat:@"%@IP属地：%@", baseText, location];
        } else if (currentText.length > 0) {
            lbl.text = [NSString stringWithFormat:@"%@  IP属地：%@", currentText, location];
        }

        [DYYYUtils applyColorSettingsToLabel:lbl colorHexString:labelColorHex];
    };

    if (cityCode.length == 0 && regionCode.length == 0) {
        updateLabelWithLocation(label, @"未知地区");
        return label;
    }

    NSString *cacheKey = cityCode.length > 0 ? cityCode : regionCode;

    NSString *cachedLocation = [locationCache objectForKey:cacheKey];
    if (cachedLocation) {
        updateLabelWithLocation(label, cachedLocation);

        NSString *ipScaleValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYNicknameScale"];
        if (ipScaleValue.length > 0) {
            UIFont *originalFont = label.font;
            CGFloat offset = DYYYGetFloat(@"DYYYIPLabelVerticalOffset");
            if (offset > 0) {
                label.transform = CGAffineTransformMakeTranslation(0, -offset);
            } else {
                label.transform = CGAffineTransformMakeTranslation(0, -3);
            }
            label.font = originalFont;
        }
        return label;
    }

    NSString *displayLocation = nil;

    if (cityCode.length > 0) {
        displayLocation = [CityManager.sharedInstance getCityNameWithCode:cityCode];

        if (!displayLocation && regionCode.length > 0) {
            displayLocation = [CityManager.sharedInstance getCountryNameWithCode:regionCode];
        }

        if (!displayLocation) {
            @synchronized(inFlight) {
                if ([inFlight containsObject:cityCode]) {
                    return label;
                }
                [inFlight addObject:cityCode];
            }

            [CityManager fetchLocationWithGeonameId:cityCode completionHandler:^(NSDictionary *locationInfo, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    @synchronized(inFlight) {
                        [inFlight removeObject:cityCode];
                    }

                    NSString *apiLocation = nil;

                    if (!error && locationInfo) {
                        NSString *cityName = locationInfo[@"adminName1"];
                        NSString *countryName = locationInfo[@"countryName"];

                        if (cityName && countryName) {
                            if ([cityName isEqualToString:countryName]) {
                                apiLocation = countryName;
                            } else {
                                apiLocation = [NSString stringWithFormat:@"%@ %@", countryName, cityName];
                            }
                        } else if (countryName) {
                            apiLocation = countryName;
                        } else if (cityName) {
                            apiLocation = cityName;
                        }
                    }

                    if (apiLocation) {
                        [locationCache setObject:apiLocation forKey:cacheKey];
                        updateLabelWithLocation(label, apiLocation);
                    }
                });
            }];

            return label;
        }
    }

    if (!displayLocation && !cityCode && regionCode.length > 0) {
        displayLocation = [CityManager.sharedInstance getCountryNameWithCode:regionCode];
    }

    if (!displayLocation) {
        displayLocation = @"未知地区";
        updateLabelWithLocation(label, displayLocation);
        return label;
    }

    [locationCache setObject:displayLocation forKey:cacheKey];
    updateLabelWithLocation(label, displayLocation);

    NSString *ipScaleValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYNicknameScale"];
    if (ipScaleValue.length > 0) {
        UIFont *originalFont = label.font;
        CGFloat offset = DYYYGetFloat(@"DYYYIPLabelVerticalOffset");
        if (offset > 0) {
            label.transform = CGAffineTransformMakeTranslation(0, -offset);
        } else {
            label.transform = CGAffineTransformMakeTranslation(0, -3);
        }
        label.font = originalFont;
    }
    return label;
}

+ (BOOL)shouldActiveWithData:(id)arg1 context:(id)arg2 {
    return DYYYGetBool(@"DYYYEnableArea");
}

%end

%hook AWEPlayInteractionProgressController

%new
- (void)dyyy_syncScheduleLabelsWithCurrentTime:(CGFloat)currentTime totalDuration:(CGFloat)totalDuration {
    if (!DYYYGetBool(@"DYYYShowScheduleDisplay")) {
        return;
    }

    id progressSlider = self.progressSlider;
    if (progressSlider && [progressSlider respondsToSelector:@selector(dyyy_updateScheduleLabelsWithCurrentTime:totalDuration:)]) {
        [progressSlider dyyy_updateScheduleLabelsWithCurrentTime:currentTime totalDuration:totalDuration];
    }

    if ([progressSlider isKindOfClass:[UIView class]]) {
        [(UIView *)progressSlider dyyy_updateScheduleLabelsLegacyWithCurrentTime:currentTime totalDuration:totalDuration model:self.model];
    }
}

- (void)updateProgressSliderWithTime:(CGFloat)arg1 totalDuration:(CGFloat)arg2 {
    %orig;
    [self dyyy_syncScheduleLabelsWithCurrentTime:arg1 totalDuration:arg2];
    // 2.2-9-23 黑线状态机覆盖：用户实测黑线在新视频出现、暂停消失、点播放消失、下一视频又出现、
    // 悬浮清屏也藏不掉——说明它是进度状态机每次状态变化时重显示的，之前只在 layout 时藏一次会被下一次
    // 状态更新覆盖掉。这里跑在每次进度更新后（播放时持续触发），状态机刚显示完就再藏一次，压过它。
    // 只在全屏开时藏，函数内部已按开关判断，关时按标记恢复，不动进度条本身。
    @try {
        id ps = self.progressSlider;
        if ([ps isKindOfClass:[UIView class]]) {
            DYYYFullscreenProgressSyncBlackLines((UIView *)ps);
        }
    } @catch (__unused NSException *e) {
    }
}

%end

%hook AWEDProgressCoreContainer

%new
- (void)dyyy_syncScheduleLabelsWithCurrentTime:(CGFloat)currentTime totalDuration:(CGFloat)totalDuration {
    if (!DYYYGetBool(@"DYYYShowScheduleDisplay")) {
        return;
    }

    id progressSlider = self.progressSlider;
    if (progressSlider && [progressSlider respondsToSelector:@selector(dyyy_updateScheduleLabelsWithCurrentTime:totalDuration:)]) {
        [progressSlider dyyy_updateScheduleLabelsWithCurrentTime:currentTime totalDuration:totalDuration];
    }

    id model = nil;
    if ([self respondsToSelector:@selector(model)]) {
        model = [self valueForKey:@"model"];
    }

    if ([progressSlider isKindOfClass:[UIView class]]) {
        [(UIView *)progressSlider dyyy_updateScheduleLabelsLegacyWithCurrentTime:currentTime totalDuration:totalDuration model:model];
    }
}

- (void)updateProgressSliderWithTime:(CGFloat)arg1 totalDuration:(CGFloat)arg2 {
    %orig;
    [self dyyy_syncScheduleLabelsWithCurrentTime:arg1 totalDuration:arg2];
    // 2.2-9-23 同上：跑在每次进度更新后，压过状态机对黑线的重显示
    @try {
        id ps = self.progressSlider;
        if ([ps isKindOfClass:[UIView class]]) {
            DYYYFullscreenProgressSyncBlackLines((UIView *)ps);
        }
    } @catch (__unused NSException *e) {
    }
}

%end

%hook AWEPlayInteractionDescriptionScrollView

- (void)layoutSubviews {
    %orig;

    self.transform = CGAffineTransformIdentity;

    NSString *descriptionOffsetValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYDescriptionVerticalOffset"];
    CGFloat verticalOffset = 0;
    if (descriptionOffsetValue.length > 0) {
        verticalOffset = [descriptionOffsetValue floatValue];
    }

    UIView *parentView = self.superview;
    UIView *grandParentView = nil;

    if (parentView) {
        grandParentView = parentView.superview;
    }

    if (grandParentView && verticalOffset != 0) {
        CGAffineTransform translationTransform = CGAffineTransformMakeTranslation(0, verticalOffset);
        grandParentView.transform = translationTransform;
    }
}

%end

// 对新版文案的偏移（33.0以上）
%hook AWEPlayInteractionDescriptionLabel

static char kLongPressGestureKey;
static NSString *const kDYYYLongPressCopyEnabledKey = @"DYYYLongPressCopyTextEnabled";

- (void)didMoveToWindow {
    %orig;

    BOOL longPressCopyEnabled = DYYYGetBool(kDYYYLongPressCopyEnabledKey);

    if (![[NSUserDefaults standardUserDefaults] objectForKey:kDYYYLongPressCopyEnabledKey]) {
        longPressCopyEnabled = NO;
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kDYYYLongPressCopyEnabledKey];
    }

    UIGestureRecognizer *existingGesture = objc_getAssociatedObject(self, &kLongPressGestureKey);
    if (existingGesture && !longPressCopyEnabled) {
        [self removeGestureRecognizer:existingGesture];
        objc_setAssociatedObject(self, &kLongPressGestureKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    if (longPressCopyEnabled && !objc_getAssociatedObject(self, &kLongPressGestureKey)) {
        UILongPressGestureRecognizer *highPriorityLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleHighPriorityLongPress:)];
        highPriorityLongPress.minimumPressDuration = 0.3;

        [self addGestureRecognizer:highPriorityLongPress];

        UIView *currentView = self;
        while (currentView.superview) {
            currentView = currentView.superview;

            for (UIGestureRecognizer *recognizer in currentView.gestureRecognizers) {
                if ([recognizer isKindOfClass:[UILongPressGestureRecognizer class]] || [recognizer isKindOfClass:[UIPinchGestureRecognizer class]]) {
                    [recognizer requireGestureRecognizerToFail:highPriorityLongPress];
                }
            }
        }

        objc_setAssociatedObject(self, &kLongPressGestureKey, highPriorityLongPress, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%new
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if ([gestureRecognizer.view isEqual:self] && [gestureRecognizer isKindOfClass:[UILongPressGestureRecognizer class]]) {
        return NO;
    }
    return YES;
}

%new
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if ([gestureRecognizer.view isEqual:self] && [gestureRecognizer isKindOfClass:[UILongPressGestureRecognizer class]]) {
        return YES;
    }
    return NO;
}

%new
- (void)handleHighPriorityLongPress:(UILongPressGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {

        NSString *description = self.text;

        if (description.length > 0) {
            [[UIPasteboard generalPasteboard] setString:description];
            [DYYYToast showSuccessToastWithMessage:@"视频文案已复制"];
        }
    }
}

- (void)layoutSubviews {
    %orig;

    self.transform = CGAffineTransformIdentity;

    NSString *descriptionOffsetValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYDescriptionVerticalOffset"];
    CGFloat verticalOffset = 0;
    if (descriptionOffsetValue.length > 0) {
        verticalOffset = [descriptionOffsetValue floatValue];
    }

    UIView *parentView = self.superview;
    UIView *grandParentView = nil;

    if (parentView) {
        grandParentView = parentView.superview;
    }

    if (grandParentView && verticalOffset != 0) {
        CGAffineTransform translationTransform = CGAffineTransformMakeTranslation(0, verticalOffset);
        grandParentView.transform = translationTransform;
    }
}

%end

%hook AWEUserNameLabel

- (void)layoutSubviews {
    %orig;

    self.transform = CGAffineTransformIdentity;

    // 添加垂直偏移支持
    NSString *verticalOffsetValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYNicknameVerticalOffset"];
    CGFloat verticalOffset = 0;
    if (verticalOffsetValue.length > 0) {
        verticalOffset = [verticalOffsetValue floatValue];
    }

    UIView *parentView = self.superview;
    UIView *grandParentView = nil;

    if (parentView) {
        grandParentView = parentView.superview;
    }

    // 检查祖父视图是否为 AWEBaseElementView 类型
    if (grandParentView && [grandParentView.superview isKindOfClass:%c(AWEBaseElementView)]) {
        CGRect scaledFrame = grandParentView.frame;
        CGFloat translationX = -scaledFrame.origin.x;

        CGAffineTransform translationTransform = CGAffineTransformMakeTranslation(translationX, verticalOffset);
        grandParentView.transform = translationTransform;
    }
}

%end

%hook AWEFeedVideoButton

- (void)setImage:(id)arg1 {
    UIImage *imageToApply = arg1;
    NSString *nameString = nil;

    if ([self respondsToSelector:@selector(imageNameString)]) {
        IMP imp = [self methodForSelector:@selector(imageNameString)];
        if (imp) {
            NSString *(*func)(id, SEL) = (NSString * (*)(id, SEL)) imp;
            if (func) {
                nameString = func(self, @selector(imageNameString));
            }
        }
    }

    NSString *customFileName = DYYYCustomIconFileNameForButtonName(nameString);
    if (customFileName.length > 0) {
        UIImage *customImage = DYYYLoadCustomImage(customFileName, CGSizeMake(44.0, 44.0));
        if (customImage) {
            imageToApply = customImage;
        }
    }

    %orig(imageToApply);
}

%end

%hook AWENormalModeTabBarGeneralPlusButton
- (void)setImage:(UIImage *)image forState:(UIControlState)state {

    UIImage *imageToApply = image;
    if ([self.accessibilityLabel isEqualToString:@"拍摄"]) {
        UIImage *customImage = DYYYLoadCustomImage(@"tab_plus.png", CGSizeZero);
        if (customImage) {
            imageToApply = customImage;
        }
    }

    %orig(imageToApply, state);
}
%end

// 获取资源的地址
%hook AWEURLModel
%new - (NSURL *)getDYYYSrcURLDownload {
    NSURL *bestURL;
    for (NSString *url in self.originURLList) {
        if ([url containsString:@"video_mp4"] || [url containsString:@".jpeg"] || [url containsString:@".mp3"]) {
            bestURL = [NSURL URLWithString:url];
        }
    }

    if (bestURL == nil) {
        bestURL = [NSURL URLWithString:[self.originURLList firstObject]];
    }

    return bestURL;
}
%end

// 屏蔽版本更新
%hook AWEVersionUpdateManager

- (void)startVersionUpdateWorkflow:(id)arg1 completion:(id)arg2 {
    if (DYYYGetBool(@"DYYYNoUpdates")) {
        if (arg2) {
            void (^completionBlock)(void) = arg2;
            completionBlock();
        }
    } else {
        %orig;
    }
}

- (id)workflow {
    return DYYYGetBool(@"DYYYNoUpdates") ? nil : %orig;
}

- (id)badgeModule {
    return DYYYGetBool(@"DYYYNoUpdates") ? nil : %orig;
}

%end

// 应用内推送毛玻璃效果
%hook AWEInnerNotificationWindow

- (void)layoutSubviews {
    %orig;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYEnableNotificationTransparency"]) {
        [self setupBlurEffectForNotificationView];
    }
}

- (void)didMoveToWindow {
    %orig;
    if (self.window && DYYYGetBool(@"DYYYEnableNotificationTransparency")) {
        [self setupBlurEffectForNotificationView];
    }
}

%new
- (void)setupBlurEffectForNotificationView {
    for (UIView *subview in self.subviews) {
        if ([NSStringFromClass([subview class]) containsString:@"AWEInnerNotificationContainerView"]) {
            [self applyBlurEffectToView:subview];
            break;
        }
    }
}

%new
- (void)applyBlurEffectToView:(UIView *)containerView {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!containerView) {
          return;
      }

      containerView.backgroundColor = [UIColor clearColor];

      float userRadius = [[[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYNotificationCornerRadius"] floatValue];
      if (!userRadius || userRadius < 0 || userRadius > 50) {
          userRadius = 12;
      }

      containerView.layer.cornerRadius = userRadius;
      containerView.layer.masksToBounds = YES;

      for (UIView *subview in containerView.subviews) {
          if ([subview isKindOfClass:[UIVisualEffectView class]] && subview.tag == 999) {
              [subview removeFromSuperview];
          }
      }

      BOOL isDarkMode = [DYYYUtils isDarkMode];
      UIBlurEffectStyle blurStyle = isDarkMode ? UIBlurEffectStyleDark : UIBlurEffectStyleLight;
      UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:blurStyle];
      UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];

      blurView.frame = containerView.bounds;
      blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
      blurView.tag = 999;
      blurView.layer.cornerRadius = userRadius;
      blurView.layer.masksToBounds = YES;

      float userTransparency = [[[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYCommentBlurTransparent"] floatValue];
      if (userTransparency <= 0 || userTransparency > 1) {
          userTransparency = 0.5;
      }

      blurView.alpha = userTransparency;

      [containerView insertSubview:blurView atIndex:0];

      [self clearBackgroundRecursivelyInView:containerView];

      [self setLabelsColorWhiteInView:containerView];
    });
}

%new
- (void)setLabelsColorWhiteInView:(UIView *)view {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)subview;
            NSString *text = label.text;

            if (![text isEqualToString:@"回复"] && ![text isEqualToString:@"查看"] && ![text isEqualToString:@"续火花"]) {
                label.textColor = [UIColor whiteColor];
            }
        }
        [self setLabelsColorWhiteInView:subview];
    }
}

%new
- (void)clearBackgroundRecursivelyInView:(UIView *)view {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UIVisualEffectView class]] && subview.tag == 999 && [subview isKindOfClass:[UIButton class]]) {
            continue;
        }
        subview.backgroundColor = [UIColor clearColor];
        [self clearBackgroundRecursivelyInView:subview];
    }
}

%end

// 为 AWEUserActionSheetView 添加毛玻璃效果
%hook AWEUserActionSheetView

- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYEnableSheetBlur")) {
        [self applyBlurEffectAndWhiteText];
    }
}

%new
- (void)applyBlurEffectAndWhiteText {
    // 应用毛玻璃效果到容器视图
    if (self.containerView) {
        self.containerView.backgroundColor = [UIColor clearColor];

        // 动态获取用户设置的透明度
        float userTransparency = [[[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYSheetBlurTransparent"] floatValue];
        if (userTransparency <= 0 || userTransparency > 1) {
            userTransparency = 0.9; // 默认值0.9
        }

        [DYYYUtils applyBlurEffectToView:self.containerView transparency:userTransparency blurViewTag:9999];
        [DYYYUtils clearBackgroundRecursivelyInView:self.containerView];
        // 调用新的通用方法设置文本颜色，这里没有排除需求，所以传入 nil Block
        [DYYYUtils applyTextColorRecursively:[UIColor whiteColor] inView:self.containerView shouldExcludeViewBlock:nil];
    }
}

%end

%hook _TtC33AWECommentLongPressPanelSwiftImpl32CommentLongPressPanelCopyElement

- (void)elementTapped {
    if (DYYYGetBool(@"DYYYCommentCopyText")) {
        AWECommentLongPressPanelContext *commentPageContext = [self commentPageContext];
        AWECommentModel *selectdComment = [commentPageContext selectdComment];
        if (!selectdComment) {
            AWECommentLongPressPanelParam *params = [commentPageContext params];
            selectdComment = [params selectdComment];
        }
        NSString *descText = [selectdComment content];
        [[UIPasteboard generalPasteboard] setString:descText];
        [DYYYToast showSuccessToastWithMessage:@"评论已复制"];
    }
}
%end

// 启用自动勾选原图
%hook AWEIMPhotoPickerFunctionModel

- (void)setUseShadowIcon:(BOOL)arg1 {
    BOOL enabled = DYYYGetBool(@"DYYYAutoSelectOriginalPhoto");
    if (enabled) {
        %orig(YES);
    } else {
        %orig(arg1);
    }
}

- (BOOL)isSelected {
    BOOL enabled = DYYYGetBool(@"DYYYAutoSelectOriginalPhoto");
    if (enabled) {
        return YES;
    }
    return %orig;
}

%end

// 屏蔽直播PCDN
%hook HTSLiveStreamPcdnManager

+ (void)start {
    BOOL disablePCDN = DYYYGetBool(@"DYYYDisableLivePCDN");
    if (!disablePCDN) {
        %orig;
    } else {
        NSLog(@"[DYYY] HTSLiveStreamPcdnManager start blocked");
    }
}

+ (void)configAndStartLiveIO {
    BOOL disablePCDN = DYYYGetBool(@"DYYYDisableLivePCDN");
    if (!disablePCDN) {
        %orig;
    } else {
        NSLog(@"[DYYY] HTSLiveStreamPcdnManager configAndStartLiveIO blocked");
    }
}

%end

// PCDN启动任务hook
%hook IESLiveLaunchTaskPcdn

- (void)excute {
    BOOL disablePCDN = DYYYGetBool(@"DYYYDisableLivePCDN");
    if (disablePCDN) {
        NSLog(@"[DYYY] IESLiveLaunchTaskPcdn excute blocked");
        return;
    }
    %orig;
}

%end

// 投屏忽略 VPN 检测
%hook BDByteCastUtils

+ (BOOL)netVPNStatus {
    if (DYYYGetBool(@"DYYYDisableCastVPNCheck")) {
        return NO;
    }
    return %orig;
}

%end

%hook BDByteCastNetUtilities

- (BOOL)getVPNStatus {
    if (DYYYGetBool(@"DYYYDisableCastVPNCheck")) {
        return NO;
    }
    return %orig;
}

%end

%hook BDByteCastMonitorManager

- (BOOL)netVPNStatus {
    if (DYYYGetBool(@"DYYYDisableCastVPNCheck")) {
        return NO;
    }
    return %orig;
}

- (void)setNetVPNStatus:(BOOL)netVPNStatus {
    if (DYYYGetBool(@"DYYYDisableCastVPNCheck")) {
        %orig(NO);
        return;
    }
    %orig(netVPNStatus);
}

%end

%hook BDByteCastEnvInfo

- (BOOL)isVPNActive {
    if (DYYYGetBool(@"DYYYDisableCastVPNCheck")) {
        return NO;
    }
    return %orig;
}

- (void)setIsVPNActive:(BOOL)isVPNActive {
    if (DYYYGetBool(@"DYYYDisableCastVPNCheck")) {
        %orig(NO);
        return;
    }
    %orig(isVPNActive);
}

%end

%hook BDByteScreenCastContext

- (BOOL)isVPNActive {
    if (DYYYGetBool(@"DYYYDisableCastVPNCheck")) {
        return NO;
    }
    return %orig;
}

- (void)setIsVPNActive:(BOOL)isVPNActive {
    if (DYYYGetBool(@"DYYYDisableCastVPNCheck")) {
        %orig(NO);
        return;
    }
    %orig(isVPNActive);
}

%end

// 调整直播默认清晰度功能
static NSArray<NSString *> *dyyy_qualityRank = nil;

%hook HTSLiveStreamQualityFragment

- (void)setupStreamQuality:(id)arg1 {
    %orig;

    NSString *preferredQuality = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYLiveQuality"];
    if (!preferredQuality || [preferredQuality isEqualToString:@"自动"]) {
        NSLog(@"[DYYY] Live quality auto - skipping hook");
        return;
    }

    BOOL preferLower = YES;
    NSLog(@"[DYYY] preferredQuality=%@ preferLower=%@", preferredQuality, @(preferLower));

    NSArray *qualities = self.streamQualityArray;
    if (!qualities || qualities.count == 0) {
        qualities = [self getQualities];
    }
    if (!qualities || qualities.count == 0) {
        return;
    }

    if (!dyyy_qualityRank) {
        dyyy_qualityRank = @[ @"蓝光帧彩", @"蓝光", @"超清", @"高清", @"标清" ];
    }
    NSArray *orderedNames = dyyy_qualityRank;

    // Map available names to their indices in the provided order
    NSMutableDictionary<NSString *, NSNumber *> *nameToIndex = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *availableNames = [NSMutableArray array];
    NSMutableArray<NSNumber *> *rankArray = [NSMutableArray array];
    for (NSInteger i = 0; i < qualities.count; i++) {
        id q = qualities[i];
        NSString *name = nil;
        if ([q respondsToSelector:@selector(name)]) {
            name = [q name];
        } else {
            name = [q valueForKey:@"name"];
        }
        if (name) {
            [availableNames addObject:name];
            nameToIndex[name] = @(i);
            NSInteger rank = [orderedNames indexOfObject:name];
            if (rank != NSNotFound) {
                [rankArray addObject:@(rank)];
            }
        }
    }
    NSLog(@"[DYYY] available qualities: %@", availableNames);

    BOOL qualityDesc = YES; // ranks ascending -> high to low
    BOOL qualityAsc = YES;  // ranks descending -> low to high
    for (NSInteger i = 1; i < rankArray.count; i++) {
        NSInteger prev = rankArray[i - 1].integerValue;
        NSInteger curr = rankArray[i].integerValue;
        if (curr < prev) {
            qualityDesc = NO;
        }
        if (curr > prev) {
            qualityAsc = NO;
        }
    }

    NSInteger count = availableNames.count;
    NSInteger (^convertIndex)(NSInteger) = ^NSInteger(NSInteger idx) {
      if (qualityAsc && !qualityDesc) {
          return count - 1 - idx;
      }
      return idx;
    };

    NSArray *searchOrder = orderedNames;

    NSNumber *indexToUse = nameToIndex[preferredQuality];
    if (indexToUse) {
        NSInteger finalIdx = convertIndex(indexToUse.integerValue);
        NSLog(@"[DYYY] exact quality %@ found at index %ld", preferredQuality, (long)finalIdx);
        [self setResolutionWithIndex:finalIdx isManual:YES beginChange:nil completion:nil];
        return;
    }

    NSInteger targetPos = [orderedNames indexOfObject:preferredQuality];
    if (targetPos == NSNotFound) {
        NSLog(@"[DYYY] preferred quality %@ not in list", preferredQuality);
        return;
    }

    NSInteger step = preferLower ? 1 : -1;
    BOOL applied = NO;
    for (NSInteger pos = targetPos + step; pos >= 0 && pos < searchOrder.count; pos += step) {
        NSString *candidate = searchOrder[pos];
        NSNumber *idx = nameToIndex[candidate];
        if (idx) {
            NSInteger finalIdx = convertIndex(idx.integerValue);
            NSLog(@"[DYYY] fallback quality %@ at index %ld", candidate, (long)finalIdx);
            [self setResolutionWithIndex:finalIdx isManual:YES beginChange:nil completion:nil];
            applied = YES;
            break;
        }
    }
    if (!applied) {
        NSLog(@"[DYYY] no suitable fallback quality found");
    }
}

%end

// 强制启用新版抖音长按 UI（现代风）
%hook AWELongPressPanelDataManager
+ (BOOL)enableModernLongPressPanelConfigWithSceneIdentifier:(id)arg1 {
    return DYYYGetBool(@"DYYYEnableModernPanel");
}
%end

%hook AWELongPressPanelABSettings
+ (NSUInteger)modernLongPressPanelStyleMode {
    if (!DYYYGetBool(@"DYYYEnableModernPanel")) {
        return %orig;
    }

    BOOL forceBlur = DYYYGetBool(@"DYYYLongPressPanelBlur");
    BOOL forceDark = DYYYGetBool(@"DYYYLongPressPanelDark");

    if (forceBlur && forceDark) {
        return 1;
    } else if (!forceBlur && !forceDark) {
        BOOL isDarkMode = [DYYYUtils isDarkMode];
        return isDarkMode ? 1 : 2;
    }
}
%end

%hook AWEModernLongPressPanelUIConfig
+ (NSUInteger)modernLongPressPanelStyleMode {
    if (!DYYYGetBool(@"DYYYEnableModernPanel")) {
        return %orig;
    }

    BOOL forceBlur = DYYYGetBool(@"DYYYLongPressPanelBlur");
    BOOL forceDark = DYYYGetBool(@"DYYYLongPressPanelDark");

    if (forceBlur && forceDark) {
        return 1;
    } else if (!forceBlur && !forceDark) {
        BOOL isDarkMode = [DYYYUtils isDarkMode];
        return isDarkMode ? 1 : 2;
    }
}
%end

// 禁用个人资料自动进入橱窗
%hook AWEUserTabListModel

- (NSInteger)profileLandingTab {
    if (DYYYGetBool(@"DYYYDefaultEnterWorks")) {
        return 0;
    } else {
        return %orig;
    }
}

%end

%group AutoPlay

%hook AWEAwemeDetailTableViewController

- (BOOL)hasIphoneAutoPlaySwitch {
    return YES;
}

%end

%hook AWEAwemeDetailContainerPlayControlConfig

- (BOOL)enableUserProfilePostAutoPlay {
    return YES;
}

%end

%hook AWEFeedIPhoneAutoPlayManager

- (BOOL)isAutoPlayOpen {
    return YES;
}

%end

%hook AWEFeedModuleService

- (BOOL)getFeedIphoneAutoPlayState {
    return YES;
}
%end

%hook AWEFeedIPhoneAutoPlayManager

- (BOOL)getFeedIphoneAutoPlayState {
    BOOL r = %orig;
    return YES;
}
%end

%end

%hook AWEPlayInteractionSpeedController

static BOOL hasChangedSpeed = NO;
static CGFloat currentLongPressSpeed = 0;
static CGFloat initialTouchX = 0;
static BOOL isGestureActive = NO;

- (CGFloat)longPressFastSpeedValue {
    float longPressSpeed = DYYYGetFloat(@"DYYYLongPressSpeed");
    if (longPressSpeed == 0) {
        longPressSpeed = 2.0;
    }
    return longPressSpeed;
}

- (void)changeSpeed:(double)speed {
    float longPressSpeed = DYYYGetFloat(@"DYYYLongPressSpeed");

    if (isGestureActive && currentLongPressSpeed > 0) {
        %orig(currentLongPressSpeed);
        return;
    }

    if (speed == 2.0) {
        if (!hasChangedSpeed) {
            if (longPressSpeed != 0 && longPressSpeed != 2.0) {
                hasChangedSpeed = YES;
                %orig(longPressSpeed);
                return;
            }
        } else {
            hasChangedSpeed = NO;
            %orig(1.0);
            return;
        }
    }

    if (longPressSpeed == 0 || longPressSpeed == 2) {
        %orig(speed);
        return;
    }
}

- (void)handleLongPressFastSpeed:(UILongPressGestureRecognizer *)gesture {
    %orig;

    if (!DYYYGetBool(@"DYYYEnableLongPressSpeedGesture")) {
        return;
    }

    CGPoint location = [gesture locationInView:gesture.view];

    static CGFloat initialTouchY = 0;

    if (gesture.state == UIGestureRecognizerStateBegan) {
        initialTouchY = location.y;
        isGestureActive = YES;

        float longPressSpeed = DYYYGetFloat(@"DYYYLongPressSpeed");
        if (longPressSpeed == 0) {
            longPressSpeed = 2.0;
        }
        currentLongPressSpeed = longPressSpeed;
    }
    else if (gesture.state == UIGestureRecognizerStateChanged && isGestureActive) {
        CGFloat deltaY = location.y - initialTouchY;
        CGFloat threshold = 10.0;

        if (fabs(deltaY) > threshold) {
            CGFloat speedChange;
            speedChange = (deltaY > 0) ? 0.25 : -0.25;

            CGFloat newSpeed = currentLongPressSpeed + speedChange;
            newSpeed = MAX(0.5, MIN(3.0, newSpeed));

            if (newSpeed != currentLongPressSpeed) {
                currentLongPressSpeed = newSpeed;
                initialTouchY = location.y;
                [self changeSpeed:currentLongPressSpeed];
            }
        }
    }
    else if (gesture.state == UIGestureRecognizerStateEnded ||
             gesture.state == UIGestureRecognizerStateCancelled) {
        isGestureActive = NO;
        currentLongPressSpeed = 0;
        initialTouchY = 0;
    }
}
%end

%hook UILabel

- (void)setText:(NSString *)text {
    UIView *superview = self.superview;

    if ([superview isKindOfClass:%c(AFDFastSpeedView)] && text) {
        CGFloat displaySpeed = isGestureActive && currentLongPressSpeed > 0 ? currentLongPressSpeed : DYYYGetFloat(@"DYYYLongPressSpeed");
        if (displaySpeed == 0) {
            displaySpeed = 2.0;
        }

        NSString *speedString = [NSString stringWithFormat:@"%.2f", displaySpeed];
        if ([speedString hasSuffix:@".00"]) {
            speedString = [speedString substringToIndex:speedString.length - 3];
        } else if ([speedString hasSuffix:@"0"] && [speedString containsString:@"."]) {
            speedString = [speedString substringToIndex:speedString.length - 1];
        }

        if ([text containsString:@"2"]) {
            text = [text stringByReplacingOccurrencesOfString:@"2" withString:speedString];
        }
    }

    %orig(text);
}
%end

// 强制启用保存他人头像
%hook AFDProfileAvatarFunctionManager
- (BOOL)shouldShowSaveAvatarItem {
    BOOL shouldEnable = DYYYGetBool(@"DYYYEnableSaveAvatar");
    if (shouldEnable) {
        return YES;
    }
    return %orig;
}
%end

%hook AWECommentMediaDownloadConfigLivePhoto

BOOL commentLivePhotoNotWaterMark = DYYYGetBool(@"DYYYCommentLivePhotoNotWaterMark");

- (BOOL)needClientWaterMark {
    return commentLivePhotoNotWaterMark ? 0 : %orig;
}

- (BOOL)needClientEndWaterMark {
    return commentLivePhotoNotWaterMark ? 0 : %orig;
}

- (id)watermarkConfig {
    return commentLivePhotoNotWaterMark ? nil : %orig;
}

%end

%hook AWECommentImageModel
- (id)downloadUrl {
    if (DYYYGetBool(@"DYYYCommentNotWaterMark")) {
        return self.originUrl;
    }
    return %orig;
}
%end

%group EnableStickerSaveMenu
static __weak YYAnimatedImageView *targetStickerView = nil;
static BOOL dyyyShouldUseLastStickerURL = NO;

%hook _TtCV28AWECommentPanelListSwiftImpl6NEWAPI27CommentCellStickerComponent

- (void)handleLongPressWithGes:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        if ([gesture.view isKindOfClass:%c(YYAnimatedImageView)]) {
            targetStickerView = (YYAnimatedImageView *)gesture.view;
            NSLog(@"DYYY 长按表情：%@", targetStickerView);
        } else {
            targetStickerView = nil;
        }
    }

    %orig;
}

%end

%hook _TtC33AWECommentLongPressPanelSwiftImpl37CommentLongPressPanelSaveImageElement

- (BOOL)elementShouldShow {
    BOOL shouldShow = %orig;
    if (!DYYYGetBool(@"DYYYForceDownloadEmotion") && !DYYYGetBool(@"DYYYForceDownloadCommentAudio")) {
        return shouldShow;
    }
    AWECommentLongPressPanelContext *context = [self commentPageContext];
    AWECommentModel *selected = [context selectdComment] ?: [[context params] selectdComment];
    AWEIMStickerModel *sticker = [selected sticker];
    NSArray *originURLList = sticker.staticURLModel.originURLList;
    if (originURLList.count > 0) {
        return YES;
    }
    AWECommentAudioModel *audio = [selected audioModel];
    if (audio && audio.content) {
        return YES;
    }
    return shouldShow;
}

- (void)elementTapped {
    AWECommentLongPressPanelContext *context = [self commentPageContext];
    AWECommentLongPressPanelParam *params = [context params];
    AWECommentModel *comment = [context selectdComment] ?: [params selectdComment];
    
    // 判断保存类型(表情包/音频/图片)
    AWEIMStickerModel *sticker = [comment sticker];
    NSArray *stickerURLList = sticker.staticURLModel.originURLList;
    BOOL hasSticker = (stickerURLList.count > 0);

    AWECommentAudioModel *audio = [comment audioModel];
    BOOL hasAudio = (audio && audio.content);
    
    NSArray *imageList = nil;
    if ([comment respondsToSelector:@selector(imageList)]) {
        imageList = [comment imageList];
    }
    BOOL hasImages = (imageList && imageList.count > 0);
    
    // 表情包保存逻辑
    if (hasSticker && DYYYGetBool(@"DYYYForceDownloadEmotion")) {
        NSString *urlString = dyyyShouldUseLastStickerURL ? stickerURLList.lastObject : stickerURLList.firstObject;
        dyyyShouldUseLastStickerURL = NO;
        NSURL *stickerURL = [NSURL URLWithString:urlString];
        
        if (stickerURL) {
            [DYYYManager downloadMedia:stickerURL
                             mediaType:MediaTypeHeic
                                 audio:nil
                            completion:^(BOOL success) {
                              if (!success && stickerURLList.count > 1) {
                                  dyyyShouldUseLastStickerURL = YES;
                              }
                            }];
            return;
        }
    }

    // 音频保存逻辑
    if (hasAudio && DYYYGetBool(@"DYYYForceDownloadCommentAudio")) {
        NSString *audioContent = audio.content;
        
        NSString *userName = @"未知用户";
        if (comment.author && [comment.author respondsToSelector:@selector(nickname)]) {
            NSString *nickname = [comment.author performSelector:@selector(nickname)];
            if (nickname && nickname.length > 0) {
                userName = nickname;
            }
        }
        
        [DYYYManager downloadAndShareCommentAudio:audioContent
                                         userName:userName
                                       createTime:comment.createTime];
        return;
    }

    // 图片保存逻辑
    if (hasImages && DYYYGetBool(@"DYYYForceDownloadCommentImage")) {
        // 检查 is_pic_inflow 判断是保存全部还是单张
        // is_pic_inflow = 1: 点开具体图片后长按 -> 只保存当前图片
        // is_pic_inflow = 0: 直接在评论区长按 -> 保存全部图片
        NSDictionary *extraParams = [params extraParams];
        BOOL isPicInflow = NO;
        if (extraParams && [extraParams isKindOfClass:[NSDictionary class]]) {
            id isPicInflowValue = extraParams[@"is_pic_inflow"];
            if (isPicInflowValue) {
                isPicInflow = [isPicInflowValue integerValue] == 1;
            }
        }
        
        NSInteger currentIndex = -1; // -1 表示保存全部
        
        if (isPicInflow) {
            // 使用 DYYYUtils 封装的方法查找目标控制器
            UIViewController *topVC = [DYYYUtils topView];
            
            // 获取 Ivar 定义的类和目标控制器类
            Class ivarClass = NSClassFromString(@"AWECommentMediaFeedSwfitImpl.CommentMediaFeedCellViewController");
            Class targetClass = NSClassFromString(@"AWECommentMediaFeedSwfitImpl.CommentMediaFeedCommonImageCellViewController");
            
            if (ivarClass && targetClass && topVC) {
                Ivar multiIndexIvar = class_getInstanceVariable(ivarClass, "currentIndexInMultiImageList");
                if (multiIndexIvar) {
                    UIViewController *cellVC = [DYYYUtils findViewControllerOfClass:targetClass inViewController:topVC];
                    if (cellVC) {
                        ptrdiff_t offset = ivar_getOffset(multiIndexIvar);
                        NSInteger *ptr = (NSInteger *)((char *)(__bridge void *)cellVC + offset);
                        currentIndex = *ptr;
                    }
                }
            }
        }
        
        NSString *hint = (currentIndex >= 0) ? @"正在保存当前图片..." : 
            [NSString stringWithFormat:@"正在保存 %lu 张图片...", (unsigned long)imageList.count];
        [DYYYUtils showToast:hint];
        
        [DYYYManager saveCommentImages:imageList
                            currentIndex:currentIndex
                            completion:^(NSInteger successCount, NSInteger livePhotoCount, NSInteger failedCount) {
            NSMutableString *message = [NSMutableString stringWithFormat:@"成功保存 %ld 张", (long)successCount];
            if (livePhotoCount > 0) {
                [message appendFormat:@"\n(含 %ld 张实况照片)", (long)livePhotoCount];
            }
            if (failedCount > 0) {
                [message appendFormat:@"\n失败 %ld 张", (long)failedCount];
            }
            [DYYYUtils showToast:message];
        }];
        return;
    }
    
    // 默认行为
    %orig;
}

%end

%hook UIMenu

+ (instancetype)menuWithTitle:(NSString *)title image:(UIImage *)image identifier:(UIMenuIdentifier)identifier options:(UIMenuOptions)options children:(NSArray<UIMenuElement *> *)children {
    BOOL hasAddStickerOption = NO;
    BOOL hasSaveLocalOption = NO;

    for (UIMenuElement *element in children) {
        NSString *elementTitle = nil;

        if ([element isKindOfClass:%c(UIAction)]) {
            elementTitle = [(UIAction *)element title];
        } else if ([element isKindOfClass:%c(UICommand)]) {
            elementTitle = [(UICommand *)element title];
        }

        if ([elementTitle isEqualToString:@"添加到表情"]) {
            hasAddStickerOption = YES;
        } else if ([elementTitle isEqualToString:@"保存到相册"]) {
            hasSaveLocalOption = YES;
        }
    }

    if (hasAddStickerOption && !hasSaveLocalOption) {
        NSMutableArray *newChildren = [children mutableCopy];

        UIAction *saveAction = [%c(UIAction) actionWithTitle:@"保存到相册"
                                                                 image:nil
                                                            identifier:nil
                                                               handler:^(__kindof UIAction *_Nonnull action) {
                                                                 // 使用全局变量 targetStickerView 保存当前长按的表情
                                                                 if (targetStickerView) {
                                                                     [DYYYManager saveAnimatedSticker:targetStickerView];
                                                                 } else {
                                                                     [DYYYUtils showToast:@"无法获取表情视图"];
                                                                 }
                                                               }];

        [newChildren addObject:saveAction];
        return %orig(title, image, identifier, options, newChildren);
    }

    return %orig;
}

%end
%end

%hook AWEIMEmoticonPreviewV2

// 添加保存按钮
- (void)layoutSubviews {
    %orig;
    static char kHasSaveButtonKey;
    BOOL DYYYForceDownloadPreviewEmotion = DYYYGetBool(@"DYYYForceDownloadPreviewEmotion");
    if (DYYYForceDownloadPreviewEmotion) {
        if (!objc_getAssociatedObject(self, &kHasSaveButtonKey)) {
            UIButton *saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
            UIImage *downloadIcon = [UIImage systemImageNamed:@"arrow.down.circle"];
            [saveButton setImage:downloadIcon forState:UIControlStateNormal];
            [saveButton setTintColor:[UIColor whiteColor]];
            saveButton.backgroundColor = [UIColor colorWithRed:0.0 green:0.5 blue:0.9 alpha:0.5];

            saveButton.layer.shadowColor = [UIColor blackColor].CGColor;
            saveButton.layer.shadowOffset = CGSizeMake(0, 2);
            saveButton.layer.shadowOpacity = 0.3;
            saveButton.layer.shadowRadius = 3;

            saveButton.translatesAutoresizingMaskIntoConstraints = NO;
            [self addSubview:saveButton];
            CGFloat buttonSize = 24.0;
            saveButton.layer.cornerRadius = buttonSize / 2;

            [NSLayoutConstraint activateConstraints:@[
                [saveButton.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-15], [saveButton.rightAnchor constraintEqualToAnchor:self.rightAnchor constant:-10],
                [saveButton.widthAnchor constraintEqualToConstant:buttonSize], [saveButton.heightAnchor constraintEqualToConstant:buttonSize]
            ]];

            saveButton.userInteractionEnabled = YES;
            [saveButton addTarget:self action:@selector(dyyy_saveButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
            objc_setAssociatedObject(self, &kHasSaveButtonKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

%new
- (void)dyyy_saveButtonTapped:(UIButton *)sender {
    // 获取表情包URL
    AWEIMEmoticonModel *emoticonModel = self.model;
    if (!emoticonModel) {
        [DYYYUtils showToast:@"无法获取表情包信息"];
        return;
    }

    NSString *urlString = nil;
    MediaType mediaType = MediaTypeImage;

    // 尝试动态URL
    if ([emoticonModel valueForKey:@"animate_url"]) {
        urlString = [emoticonModel valueForKey:@"animate_url"];
    }
    // 如果没有动态URL，则使用静态URL
    else if ([emoticonModel valueForKey:@"static_url"]) {
        urlString = [emoticonModel valueForKey:@"static_url"];
    }
    // 使用animateURLModel获取URL
    else if ([emoticonModel valueForKey:@"animateURLModel"]) {
        AWEURLModel *urlModel = [emoticonModel valueForKey:@"animateURLModel"];
        if (urlModel.originURLList.count > 0) {
            urlString = urlModel.originURLList[0];
        }
    }

    if (!urlString) {
        [DYYYUtils showToast:@"无法获取表情包链接"];
        return;
    }

    NSURL *url = [NSURL URLWithString:urlString];
    [DYYYManager downloadMedia:url
                     mediaType:MediaTypeHeic
                         audio:nil
                    completion:^(BOOL success){
                    }];
}

%end

static NSString *DYYYIMMessageStringValue(id object, NSString *selectorName) {
    if (!object || selectorName.length == 0) {
        return nil;
    }
    SEL selector = NSSelectorFromString(selectorName);
    if (!selector || ![object respondsToSelector:selector]) {
        return nil;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id value = [object performSelector:selector];
#pragma clang diagnostic pop
    if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
        return value;
    }
    return nil;
}

static NSURL *DYYYIMEmotionDownloadURLFromMessage(AWEIMGiphyMessage *giphyMessage) {
    if (!giphyMessage) {
        return nil;
    }
    NSString *urlString = nil;
    if (giphyMessage.giphyURL.originURLList.count > 0) {
        urlString = giphyMessage.giphyURL.originURLList.firstObject;
    }
    if (urlString.length == 0) {
        NSString *animateURL = DYYYIMMessageStringValue(giphyMessage, @"animateURL");
        if (animateURL.length > 0) {
            urlString = animateURL;
        }
    }
    if (urlString.length == 0) {
        NSString *displayIconURL = DYYYIMMessageStringValue(giphyMessage, @"displayIconURL");
        if (displayIconURL.length > 0) {
            urlString = displayIconURL;
        }
    }
    if (urlString.length == 0) {
        return nil;
    }
    return [NSURL URLWithString:urlString];
}

static AWEIMCustomMenuModel *DYYYIMCreateDownloadMenuItem(AWEIMReusableCommonCell *cell) {
    if (!cell) {
        return nil;
    }
    __weak AWEIMReusableCommonCell *weakCell = cell;
    AWEIMCustomMenuModel *menuItem = [%c(AWEIMCustomMenuModel) new];
    menuItem.title = @"保存表情";
    menuItem.imageName = @"im_emoticon_interactive_tab_new";
    menuItem.trackerName = @"保存表情";
    menuItem.willPerformMenuActionSelectorBlock = ^(id arg1) {
      AWEIMReusableCommonCell *strongCell = weakCell;
      if (!strongCell) {
          [DYYYUtils showToast:@"无法获取表情包信息"];
          return;
      }
      AWEIMMessageComponentContext *context = (AWEIMMessageComponentContext *)strongCell.currentContext;
      if (!context || ![context.message isKindOfClass:%c(AWEIMGiphyMessage)]) {
          [DYYYUtils showToast:@"无法获取表情包信息"];
          return;
      }
      NSURL *downloadURL = DYYYIMEmotionDownloadURLFromMessage((AWEIMGiphyMessage *)context.message);
      if (!downloadURL) {
          [DYYYUtils showToast:@"无法获取表情包链接"];
          return;
      }
      [DYYYManager downloadMedia:downloadURL
                       mediaType:MediaTypeHeic
                           audio:nil
                      completion:^(BOOL success){
                      }];
    };
    return menuItem;
}

static NSArray *DYYYIMMenuItemsByAddingDownloadAction(NSArray *menuItems, id cell) {
    if (!DYYYGetBool(@"DYYYForceDownloadIMEmotion")) {
        return menuItems;
    }
    if (!menuItems || !cell) {
        return menuItems;
    }
    AWEIMReusableCommonCell *commonCell = [cell isKindOfClass:%c(AWEIMReusableCommonCell)] ? (AWEIMReusableCommonCell *)cell : nil;
    if (!commonCell) {
        return menuItems;
    }
    AWEIMMessageComponentContext *context = (AWEIMMessageComponentContext *)commonCell.currentContext;
    if (!context || ![context.message isKindOfClass:%c(AWEIMGiphyMessage)]) {
        return menuItems;
    }
    for (AWEIMCustomMenuModel *item in menuItems) {
        if ([item isKindOfClass:%c(AWEIMCustomMenuModel)] && [item.title isEqualToString:@"保存表情"]) {
            return menuItems;
        }
    }
    NSMutableArray *newMenuItems = [menuItems mutableCopy];
    AWEIMCustomMenuModel *downloadItem = DYYYIMCreateDownloadMenuItem(commonCell);
    if (downloadItem) {
        [newMenuItems addObject:downloadItem];
    }
    return newMenuItems ?: menuItems;
}

%group DYYYIMMenuLegacyGroup
%hook AWEIMCustomMenuComponent
- (void)msg_showMenuForBubbleFrameInScreen:(CGRect)bubbleFrame tapLocationInScreen:(CGPoint)tapLocation menuItemList:(NSArray *)menuItems moreEmoticon:(BOOL)moreEmoticon onCell:(id)cell extra:(id)extra {
    NSArray *updatedMenuItems = DYYYIMMenuItemsByAddingDownloadAction(menuItems, cell);
    %orig(bubbleFrame, tapLocation, updatedMenuItems, moreEmoticon, cell, extra);
}
%end
%end

%group DYYYIMMenuTapLocationGroup
%hook AWEIMCustomMenuComponent
- (void)msg_showMenuForBubbleFrameInScreen:(CGRect)bubbleFrame tapLocationInScreen:(CGPoint)tapLocation menuItemList:(NSArray *)menuItems menuPanelOptions:(unsigned long long)menuPanelOptions moreEmoticon:(BOOL)moreEmoticon onCell:(id)cell extra:(id)extra {
    NSArray *updatedMenuItems = DYYYIMMenuItemsByAddingDownloadAction(menuItems, cell);
    %orig(bubbleFrame, tapLocation, updatedMenuItems, menuPanelOptions, moreEmoticon, cell, extra);
}
%end
%end

%group DYYYIMMenuHighLowGroup
%hook AWEIMCustomMenuComponent
- (void)msg_showMenuForBubbleFrameInScreen:(CGRect)bubbleFrame highLocationInScreen:(CGPoint)highLocation lowLocationInScreen:(CGPoint)lowLocation tryHighLocationFirst:(BOOL)tryHighLocationFirst menuItemList:(NSArray *)menuItems menuPanelOptions:(unsigned long long)menuPanelOptions onCell:(id)cell extra:(id)extra {
    NSArray *updatedMenuItems = DYYYIMMenuItemsByAddingDownloadAction(menuItems, cell);
    %orig(bubbleFrame, highLocation, lowLocation, tryHighLocationFirst, updatedMenuItems, menuPanelOptions, cell, extra);
}
%end
%end

%hook AWEFeedTabJumpGuideView

- (void)layoutSubviews {
    %orig;
    [self removeFromSuperview];
}

%end

%hook AWEFeedLiveMarkView
- (void)setHidden:(BOOL)hidden {
    if (DYYYGetBool(@"DYYYHideAvatarButton")) {
        hidden = YES;
    }

    %orig(hidden);
}
%end

// 隐藏头像加号和透明
%hook LOTAnimationView
- (void)layoutSubviews {
    %orig;
    // 确保只有头像的LOTAnimationView才则执行该逻辑, 防止误杀
    if ([self.superview isKindOfClass:%c(AWEPlayInteractionFollowPromptView)]) {
        // 检查是否需要隐藏加号
        if (DYYYGetBool(@"DYYYHideLOTAnimationView") || DYYYGetBool(@"DYYYHideFollowPromptView")) {
            [self removeFromSuperview];
            return;
        }
        // 应用透明度设置
        NSString *transparencyValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYAvatarViewTransparency"];
        if (transparencyValue && transparencyValue.length > 0) {
            CGFloat alphaValue = [transparencyValue floatValue];
            self.alpha = alphaValue;
        }
    }
}
%end

// 首页头像隐藏和透明
%hook AWEAdAvatarView
- (void)layoutSubviews {
    %orig;

    // 检查是否需要隐藏头像
    if (DYYYGetBool(@"DYYYHideAvatarButton")) {
        self.hidden = YES;
        return;
    }

    // 应用透明度设置
    NSString *transparencyValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYAvatarViewTransparency"];
    if (transparencyValue && transparencyValue.length > 0) {
        CGFloat alphaValue = [transparencyValue floatValue];
        if (alphaValue >= 0.0 && alphaValue <= 1.0) {
            self.alpha = alphaValue;
        }
    }
}
%end

// 移除同城吃喝玩乐提示框
%hook AWENearbySkyLightCapsuleView
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideNearbyCapsuleView")) {
        [self removeFromSuperview];
        return;
    }
    %orig;
}
%end


// 隐藏右下音乐和取消静音按钮
%hook AFDCancelMuteAwemeView
- (void)layoutSubviews {
    %orig;

    UIView *superview = self.superview;

    if ([superview isKindOfClass:NSClassFromString(@"AWEBaseElementView")]) {
        if (DYYYGetBool(@"DYYYHideCancelMute")) {
            self.hidden = YES;
            return;
        }
    }
}
%end

// 隐藏弹幕按钮
%hook AWEPlayDanmakuInputContainView

- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYHideDanmuButton")) {
        self.hidden = YES;
        return;
    }
}

%end

// 隐藏评论区免费去看短剧
%hook AWEShowPlayletCommentHeaderView
- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHideCommentViews")) {
        self.hidden = YES;
        return;
    }
}

%end

// 隐藏评论区定位
%hook AWEPOIEntryAnchorView

- (void)p_addViews {
    if (DYYYGetBool(@"DYYYHideCommentViews")) {
        return;
    }
    %orig;
}

%end

// 隐藏评论音乐
%hook AWECommentGuideLunaAnchorView
- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYHideCommentViews")) {
        [self setHidden:YES];
    }

    if (DYYYGetBool(@"DYYYMusicCopyText")) {
        UILabel *label = nil;
        if ([self respondsToSelector:@selector(preTitleLabel)]) {
            label = [self valueForKey:@"preTitleLabel"];
        }
        if (label && [label isKindOfClass:[UILabel class]]) {
            label.text = @"";
        }
    }
}

- (void)p_didClickSong {
    if (DYYYGetBool(@"DYYYMusicCopyText")) {
        // 通过 KVC 拿到内部的 songButton
        UIButton *btn = nil;
        if ([self respondsToSelector:@selector(songButton)]) {
            btn = (UIButton *)[self valueForKey:@"songButton"];
        }

        // 获取歌曲名并复制到剪贴板
        if (btn && [btn isKindOfClass:[UIButton class]]) {
            NSString *song = btn.currentTitle;
            if (song.length) {
                [UIPasteboard generalPasteboard].string = song;
                [DYYYToast showSuccessToastWithMessage:@"歌曲名已复制"];
            }
        }
    } else {
        %orig;
    }
}

%end

// Swift 类组
%group CommentHeaderGeneralGroup
%hook AWECommentPanelHeaderSwiftImpl_CommentHeaderGeneralView
- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYHideCommentViews")) {
        [self setHidden:YES];
    }
}
%end
%end
%group CommentHeaderGoodsGroup
%hook AWECommentPanelHeaderSwiftImpl_CommentHeaderGoodsView
- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYHideCommentViews")) {
        [self setHidden:YES];
    }
}
%end
%end
%group CommentHeaderTemplateGroup
%hook AWECommentPanelHeaderSwiftImpl_CommentHeaderTemplateAnchorView
- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYHideCommentViews")) {
        [self setHidden:YES];
    }
}
%end
%end
%group CommentBottomTipsVCGroup
%hook AWECommentPanelListSwiftImpl_CommentBottomTipsContainerViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    if (DYYYGetBool(@"DYYYHideCommentTips")) {
        ((UIViewController *)self).view.hidden = YES;
    }
}
%end
%end

// 去除隐藏大家都在搜后的留白
%hook AWESearchAnchorListModel

- (BOOL)hideWords {
    return DYYYGetBool(@"DYYYHideCommentViews");
}

%end

// 隐藏观看历史搜索
%hook AWEDiscoverFeedEntranceView
- (id)init {
    if (DYYYGetBool(@"DYYYHideInteractionSearch")) {
        return nil;
    }
    return %orig;
}
%end

// 隐藏校园提示
%hook AWETemplateTagsCommonView

- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYHideTemplateTags")) {
        UIView *parentView = self.superview;
        if (parentView) {
            parentView.hidden = YES;
        } else {
            self.hidden = YES;
        }
    }
}

%end



// 隐藏消息页顶栏头像气泡
%hook AFDSkylightCellBubble
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideAvatarBubble")) {
        [self removeFromSuperview];
    }
    %orig;
}
%end

// 隐藏消息页开启通知提示
%hook AWEIMMessageTabOptPushBannerView

- (instancetype)initWithFrame:(CGRect)frame {
    if (DYYYGetBool(@"DYYYHidePushBanner")) {
        return %orig(CGRectMake(frame.origin.x, frame.origin.y, 0, 0));
    }
    return %orig;
}

%end

// 隐藏消息页顶栏红包
%hook AWEIMMessageTabSideBarView
- (void)layoutSubviews {
    %orig;

    if (!DYYYGetBool(@"DYYYHideMessageTabRedPacket")) {
        return;
    }

    UIView *parentView = self.superview;
    if (!parentView) {
        return;
    }

    NSArray<UIView *> *siblings = [parentView.subviews copy];
    if (siblings.count <= 1) {
        return;
    }

    for (UIView *subview in siblings) {
        if (subview != self) {
            [subview removeFromSuperview];
        }
    }
}
%end

// 隐藏我的添加朋友
%hook AWEProfileNavigationButton
- (void)setupUI {

    if (DYYYGetBool(@"DYYYHideButton")) {
        return;
    }
    %orig;
}
%end

// 隐藏朋友"关注/不关注"按钮
%hook AWEFeedUnfollowFamiliarFollowAndDislikeView
- (void)showUnfollowFamiliarView {
    if (DYYYGetBool(@"DYYYHideFamiliar")) {
        self.hidden = YES;
        return;
    }
    %orig;
}
%end

// 隐藏朋友日常按钮
%hook AWEFamiliarNavView
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideFamiliar")) {
        self.hidden = YES;
    }
    %orig;
}
%end

// 隐藏分享给朋友提示
%hook AWEPlayInteractionStrongifyShareContentView

- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHideShareContentView")) {
        UIView *parentView = self.superview;
        if (parentView) {
            parentView.hidden = YES;
        } else {
            self.hidden = YES;
        }
    }
}

%end


%hook AWELeftSideBarEntranceView

- (void)setRedDot:(id)redDot {
    %orig(nil);
}

- (void)setNumericalRedDot:(id)numericalRedDot {
    %orig(nil);
}

- (void)layoutSubviews {
    %orig;

    // 隐藏左侧边栏的 badge
    for (UIView *subview in self.subviews) {
        if ([subview isKindOfClass:%c(DUXBadge)]) {
            subview.hidden = YES;
            break;
        }
    }

    UIResponder *responder = self;
    UIViewController *parentVC = nil;
    while ((responder = [responder nextResponder])) {
        if ([responder isKindOfClass:%c(AWEFeedContainerViewController)]) {
            parentVC = (UIViewController *)responder;
            break;
        }
    }

    if (!(parentVC && [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideLeftSideBar"])) {
        return;
    }

    static char kDYLeftSideViewCacheKey;
    NSArray *cachedViews = objc_getAssociatedObject(self, &kDYLeftSideViewCacheKey);
    if (!cachedViews) {
        NSMutableArray *views = [NSMutableArray array];
        for (UIView *subview in self.subviews) {
            if ([subview isKindOfClass:%c(DUXBaseImageView)]) {
                [views addObject:subview];
            }
        }
        cachedViews = [views copy];
        objc_setAssociatedObject(self, &kDYLeftSideViewCacheKey, cachedViews, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    for (UIView *v in cachedViews) {
        v.hidden = YES;
    }
}

%end

%hook AWEFeedVideoButton

- (void)layoutSubviews {
    %orig;

    NSString *accessibilityLabel = self.accessibilityLabel;

    BOOL hideBtn = NO;
    BOOL hideLabel = NO;

    if ([accessibilityLabel isEqualToString:@"点赞"]) {
        hideBtn = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideLikeButton"];
        hideLabel = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideLikeLabel"];
    } else if ([accessibilityLabel isEqualToString:@"评论"]) {
        hideBtn = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCommentButton"];
        hideLabel = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCommentLabel"];
    } else if ([accessibilityLabel isEqualToString:@"分享"]) {
        hideBtn = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideShareButton"];
        hideLabel = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideShareLabel"];
    } else if ([accessibilityLabel isEqualToString:@"收藏"]) {
        hideBtn = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCollectButton"];
        hideLabel = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCollectLabel"];
    }

    if (!hideBtn && !hideLabel) {
        return; // 设置未启用，无需额外处理
    }

    if (hideBtn) {
        [self removeFromSuperview];
        return;
    }

    static char kDYLabelCacheKey;
    NSArray *cachedLabels = objc_getAssociatedObject(self, &kDYLabelCacheKey);
    if (!cachedLabels) {
        NSMutableArray *labels = [NSMutableArray array];
        for (UIView *subview in self.subviews) {
            if ([subview isKindOfClass:[UILabel class]]) {
                [labels addObject:subview];
            }
        }
        cachedLabels = [labels copy];
        objc_setAssociatedObject(self, &kDYLabelCacheKey, cachedLabels, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    for (UILabel *label in cachedLabels) {
        label.hidden = hideLabel;
    }
}

%end

%hook UIButton

- (void)layoutSubviews {
    %orig;

    NSString *accessibilityLabel = self.accessibilityLabel;

    if ([accessibilityLabel isEqualToString:@"拍照搜同款"] || [accessibilityLabel isEqualToString:@"扫一扫"]) {
        if (DYYYGetBool(@"DYYYHideScancode")) {
            [self removeFromSuperview];
        }
    }

    if ([accessibilityLabel isEqualToString:@"返回"]) {
        if (DYYYGetBool(@"DYYYHideBack")) {
            UIView *parent = self.superview;
            // 父视图是AWEBaseElementView(排除用户主页返回按钮) 按钮类不是AWENoxusHighlightButton(排除横屏返回按钮)
            if ([parent isKindOfClass:%c(AWEBaseElementView)] && ![self isKindOfClass:%c(AWENoxusHighlightButton)]) {
                [self removeFromSuperview];
            }
            return;
        }
    }
}

%end

%hook AWEIMFeedVideoQuickReplayInputViewController

- (void)viewDidLayoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYHideReply")) {
        [self.view removeFromSuperview];
        return;
    }
}

%end

%hook AWEHPSearchBubbleEntranceView
- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYHideSearchBubble")) {
        [self removeFromSuperview];
        return;
    }
}

%end

%hook AWEFeedLiveTabTopSelectionView
- (void)setHideTimer:(id)timer {
    if (DYYYGetBool(@"DYYYDisableAutoHideLive")) {
        timer = nil;
    }
    %orig(timer);
}
%end

%hook AWEMusicCoverButton

- (void)layoutSubviews {
    %orig;
    NSString *accessibilityLabel = self.accessibilityLabel;
    if ([accessibilityLabel isEqualToString:@"音乐详情"]) {
        if (DYYYGetBool(@"DYYYHideMusicButton")) {
            UIView *parent = self.superview;
            if (parent) {
                [parent removeFromSuperview];
            }
            return;
        }
    }
}

%end

%hook AWEPlayInteractionListenFeedView
- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYHideMusicButton")) {
        [self removeFromSuperview];
        return;
    }
}
%end

%hook AWEPlayInteractionFollowPromptView

- (void)layoutSubviews {
    %orig;

    NSString *accessibilityLabel = self.accessibilityLabel;

    if ([accessibilityLabel isEqualToString:@"关注"]) {
        if (DYYYGetBool(@"DYYYHideAvatarButton") || DYYYGetBool(@"DYYYHideFollowPromptView")) {
            self.userInteractionEnabled = NO;
            self.hidden = YES;
            return;
        }
    }
}

%end

%hook AWEPlayInteractionElementMaskView
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideGradient")) {
        self.hidden = YES;
        return;
    }
    %orig;
}
%end

%hook AWEGradientView
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideGradient")) {
        UIView *parent = self.superview;
        if ([parent.accessibilityLabel isEqualToString:@"暂停，按钮"] || [parent.accessibilityLabel isEqualToString:@"播放，按钮"] || [parent.accessibilityLabel isEqualToString:@"“切换视角，按钮"] ||
            [parent isKindOfClass:%c(AWEStoryProgressContainerView)]) {
            self.hidden = YES;
        }
        return;
    }
    %orig;
}
%end

%hook AWEHotSpotBlurView
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideGradient")) {
        self.hidden = YES;
        return;
    }
    %orig;
}
%end

%hook AWEHotSearchInnerBottomView
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideHotSearch")) {
        [self removeFromSuperview];
        return;
    }
    %orig;
}
%end

// 隐藏双指缩放虾线
%hook AWELoadingAndVolumeView

- (void)layoutSubviews {
    %orig;
    self.hidden = YES;
    return;
}

%end

// 隐藏状态栏
%hook AWEFeedRootViewController
- (BOOL)prefersStatusBarHidden {
    if (DYYYGetBool(@"DYYYHideStatusbar") || (DYYYGetBool(@"DYYYHideStatusBarOnClear") && hideButton && hideButton.isElementsHidden)) {
        return YES;
    } else {
        if (class_getInstanceMethod([self class], @selector(prefersStatusBarHidden)) != class_getInstanceMethod([%c(AWEFeedRootViewController) class], @selector(prefersStatusBarHidden))) {
            return %orig;
        }
        return NO;
    }
}
%end

// 直播状态栏
%hook IESLiveAudienceViewController
- (BOOL)prefersStatusBarHidden {
    if (DYYYGetBool(@"DYYYHideStatusbar") || (DYYYGetBool(@"DYYYHideStatusBarOnClear") && hideButton && hideButton.isElementsHidden)) {
        return YES;
    } else {
        if (class_getInstanceMethod([self class], @selector(prefersStatusBarHidden)) !=
            class_getInstanceMethod([%c(IESLiveAudienceViewController) class], @selector(prefersStatusBarHidden))) {
            return %orig;
        }
        return NO;
    }
}
%end

// 主页状态栏
%hook AWEAwemeDetailTableViewController
- (BOOL)prefersStatusBarHidden {
    if (DYYYGetBool(@"DYYYHideStatusbar") || (DYYYGetBool(@"DYYYHideStatusBarOnClear") && hideButton && hideButton.isElementsHidden)) {
        return YES;
    } else {
        if (class_getInstanceMethod([self class], @selector(prefersStatusBarHidden)) !=
            class_getInstanceMethod([%c(AWEAwemeDetailTableViewController) class], @selector(prefersStatusBarHidden))) {
            return %orig;
        }
        return NO;
    }
}
%end

// 热点状态栏
%hook AWEAwemeHotSpotTableViewController
- (BOOL)prefersStatusBarHidden {
    if (DYYYGetBool(@"DYYYHideStatusbar") || (DYYYGetBool(@"DYYYHideStatusBarOnClear") && hideButton && hideButton.isElementsHidden)) {
        return YES;
    } else {
        if (class_getInstanceMethod([self class], @selector(prefersStatusBarHidden)) !=
            class_getInstanceMethod([%c(AWEAwemeHotSpotTableViewController) class], @selector(prefersStatusBarHidden))) {
            return %orig;
        }
        return NO;
    }
}
%end

// 图文状态栏
%hook AWEFullPageFeedNewContainerViewController
- (BOOL)prefersStatusBarHidden {
    if (DYYYGetBool(@"DYYYHideStatusbar") || (DYYYGetBool(@"DYYYHideStatusBarOnClear") && hideButton && hideButton.isElementsHidden)) {
        return YES;
    } else {
        if (class_getInstanceMethod([self class], @selector(prefersStatusBarHidden)) !=
            class_getInstanceMethod([%c(AWEFullPageFeedNewContainerViewController) class], @selector(prefersStatusBarHidden))) {
            return %orig;
        }
        return NO;
    }
}
%end

// 纯净模式状态栏
%hook AFDPureModePageContainerViewController
- (BOOL)prefersStatusBarHidden {
    if (DYYYGetBool(@"DYYYHideStatusbar") || (DYYYGetBool(@"DYYYHideStatusBarOnClear") && hideButton && hideButton.isElementsHidden)) {
        return YES;
    } else {
        if (class_getInstanceMethod([self class], @selector(prefersStatusBarHidden)) !=
            class_getInstanceMethod([%c(AFDPureModePageContainerViewController) class], @selector(prefersStatusBarHidden))) {
            return %orig;
        }
        return NO;
    }
}
%end


%hook AWEPlayInteractionSearchAnchorView

- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideInteractionSearch")) {
        [self removeFromSuperview];
        return;
    }
    %orig;
}

%end


// 隐藏暂停关键词
%hook AWEFeedPauseRelatedWordComponent

- (id)updateViewWithModel:(id)arg0 {
    if (DYYYGetBool(@"DYYYHidePauseVideoRelatedWord")) {
        return nil;
    }
    return %orig;
}

- (id)pauseContentWithModel:(id)arg0 {
    if (DYYYGetBool(@"DYYYHidePauseVideoRelatedWord")) {
        return nil;
    }
    return %orig;
}

- (id)recommendsWords {
    if (DYYYGetBool(@"DYYYHidePauseVideoRelatedWord")) {
        return nil;
    }
    return %orig;
}

- (void)showRelatedRecommendPanelControllerWithSelectedText:(id)arg0 {
    if (DYYYGetBool(@"DYYYHidePauseVideoRelatedWord")) {
        return;
    }
    %orig;
}

- (void)setupUI {
    %orig;
    if (DYYYGetBool(@"DYYYHidePauseVideoRelatedWord")) {
        if (self.relatedView) {
            self.relatedView.hidden = YES;
        }
    }
}

%end

// 隐藏视频顶部搜索框、隐藏搜索框背景、应用全局透明
%hook AWESearchEntranceView

- (void)layoutSubviews {

    if (DYYYGetBool(@"DYYYHideSearchEntrance")) {
        self.hidden = YES;
        return;
    }
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideSearchEntranceIndicator"]) {
        static char kDYSearchIndicatorKey;
        NSArray *indicatorViews = objc_getAssociatedObject(self, &kDYSearchIndicatorKey);
        if (!indicatorViews) {
            NSMutableArray *tmp = [NSMutableArray array];
            for (UIView *subviews in self.subviews) {
                if ([subviews isKindOfClass:%c(UIImageView)] && [NSStringFromClass([((UIImageView *)subviews).image class]) isEqualToString:@"_UIResizableImage"]) {
                    [tmp addObject:subviews];
                }
            }
            indicatorViews = [tmp copy];
            objc_setAssociatedObject(self, &kDYSearchIndicatorKey, indicatorViews, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        for (UIImageView *imgView in indicatorViews) {
            imgView.hidden = YES;
        }
    }

    %orig;
}

%end

// 隐藏视频滑条
%hook AWEStoryProgressSlideView

- (void)layoutSubviews {
    %orig;

    BOOL shouldHide = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideStoryProgressSlide"];
    if (!shouldHide)
        return;

    static char kDYStoryProgressCacheKey;
    UIView *targetView = objc_getAssociatedObject(self, &kDYStoryProgressCacheKey);
    if (!targetView) {
        for (UIView *obj in self.subviews) {
            if ([obj isKindOfClass:NSClassFromString(@"UISlider")] || obj.frame.size.height < 5) {
                targetView = obj.superview;
                break;
            }
        }
        if (targetView) {
            objc_setAssociatedObject(self, &kDYStoryProgressCacheKey, targetView, OBJC_ASSOCIATION_ASSIGN);
        }
    }

    if (targetView) {
        targetView.hidden = YES;
    }
}

%end

// 隐藏好友分享私信
%hook AFDNewFastReplyView

- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYHidePrivateMessages")) {
        UIView *parentView = self.superview;
        if (parentView) {
            parentView.hidden = YES;
        } else {
            self.hidden = YES;
        }
    }
}

%end



// 隐藏直播发现
%hook AWEFeedLiveTabRevisitControlView

- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYHideLiveDiscovery")) {
        self.hidden = YES;
        return;
    }
}
%end

%hook IESLiveDynamicRankListEntranceView
- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHideLiveDetail")) {
        self.hidden = YES;
        return;
    }
}
%end

%hook _TtC18IESLiveRevenueImpl34IESLiveDynamicRankListEntranceView
- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHideLiveDetail")) {
        self.hidden = YES;
        return;
    }
}
%end

%hook IESLiveMatrixEntranceView
- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHideLiveDetail")) {
        self.hidden = YES;
        return;
    }
}
%end

%hook IESLiveShortTouchActionView
- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHideTouchView")) {
        self.hidden = YES;
        return;
    }
}
%end

%hook IESLiveLotteryAnimationViewNew
- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHideTouchView")) {
        self.hidden = YES;
        return;
    }
}
%end

%hook IESLiveConfigurableShortTouchEntranceView
- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHideTouchView")) {
        self.hidden = YES;
        return;
    }
}
%end

%hook IESLiveRedEnvelopeAniLynxView
- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHideTouchView")) {
        self.hidden = YES;
        return;
    }
}
%end

// 隐藏直播点歌
%hook IESLiveKTVSongIndicatorView
- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHideKTVSongIndicator")) {
        self.hidden = YES;
        return;
    }
}
%end

// 隐藏昵称右侧
%hook UILabel

static NSHashTable *processedParentViews = nil;

+ (void)load {
    %orig;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      processedParentViews = [NSHashTable weakObjectsHashTable];
    });
}

- (void)layoutSubviews {
    %orig;

    BOOL hideRightLabel = DYYYGetBool(@"DYYYHideRightLabel");
    if (!hideRightLabel)
        return;

    NSString *accessibilityLabel = self.accessibilityLabel;
    if (!accessibilityLabel || accessibilityLabel.length == 0)
        return;

    // 避免重复处理同一个父视图
    UIView *parentView = self.superview;
    if (!parentView)
        return;

    @synchronized(processedParentViews) {
        if ([processedParentViews containsObject:parentView]) {
            return;
        }
    }

    NSString *trimmedLabel = [accessibilityLabel stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    BOOL shouldRemove = NO;

    if ([trimmedLabel hasSuffix:@"人共创"] && trimmedLabel.length > 3) {
        NSString *prefix = [trimmedLabel substringToIndex:trimmedLabel.length - 3];
        NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
        shouldRemove = ([prefix rangeOfCharacterFromSet:nonDigits].location == NSNotFound);
    }

    if (!shouldRemove) {
        shouldRemove = [trimmedLabel isEqualToString:@"章节要点"] || [trimmedLabel isEqualToString:@"图集"] || [trimmedLabel isEqualToString:@"下一章"];
    }

    if (shouldRemove) {
        @synchronized(processedParentViews) {
            [processedParentViews addObject:parentView];
        }

        UIView *grandparentView = parentView.superview; // 爷爷视图

        if (grandparentView) {

            dispatch_async(dispatch_get_main_queue(), ^{
              if ([grandparentView isKindOfClass:[UIStackView class]]) {
                  UIStackView *stackView = (UIStackView *)grandparentView;
                  [stackView removeArrangedSubview:parentView];
              }

              [parentView removeFromSuperview];

              // 强制刷新爷爷视图布局
              [grandparentView setNeedsLayout];
              [grandparentView layoutIfNeeded];
            });
        }
    }
}

%end

// 隐藏顶栏关注下的提示线
%hook AWEFeedMultiTabSelectedContainerView

- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHideTopBarLine")) {
        self.hidden = YES;
    }
}

%end

%hook AFDRecommendToFriendEntranceLabel
- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHideRecommendTips")) {
        if (self.accessibilityLabel) {
            [self removeFromSuperview];
        }
    }
}

%end

// 隐藏自己无公开作品的视图
%hook AWEProfileMixItemCollectionViewCell
- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHidePostView")) {
        if ([self.accessibilityLabel isEqualToString:@"私密作品"]) {
            self.hidden = YES;
            return;
        }
    }
}
%end

%hook AWEProfilePostEmptyPublishGuideCollectionViewCell

- (void)didMoveToSuperview {
    %orig;
    if (DYYYGetBool(@"DYYYHidePostView")) {
        if ([(UIView *)self superview]) {
            [(UIView *)self setHidden:YES];
        }
    }
}

%end

%hook AWEProfileTaskCardStyleListCollectionViewCell
- (BOOL)shouldShowPublishGuide {
    if (DYYYGetBool(@"DYYYHidePostView")) {
        return NO;
    }
    return %orig;
}
%end

%hook AWEProfileRichEmptyView

- (void)setTitle:(id)title {
    if (DYYYGetBool(@"DYYYHidePostView")) {
        return;
    }
    %orig(title);
}

- (void)setDetail:(id)detail {
    if (DYYYGetBool(@"DYYYHidePostView")) {
        return;
    }
    %orig(detail);
}
%end

// 隐藏关注直播顶端的直播视图
%hook AWENewLiveSkylightViewController

- (void)showSkylight:(BOOL)arg0 animated:(BOOL)arg1 actionMethod:(unsigned long long)arg2 {
    if (DYYYGetBool(@"DYYYHideLiveView")) {
        return;
    }
    %orig(arg0, arg1, arg2);
}

- (void)updateIsSkylightShowing:(BOOL)arg0 {
    if (DYYYGetBool(@"DYYYHideLiveView")) {
        %orig(NO);
    } else {
        %orig(arg0);
    }
}

%end

// 隐藏关注直播
%hook AWELiveSkylightViewModel

- (id)dataSource {
	BOOL DYYYHideConcernCapsuleView = DYYYGetBool(@"DYYYHideConcernCapsuleView");
	if (DYYYHideConcernCapsuleView) {
		return nil;
	}
	return %orig;
}

- (void)setDataSource:(id)dataSource {
	BOOL DYYYHideConcernCapsuleView = DYYYGetBool(@"DYYYHideConcernCapsuleView");
	if (DYYYHideConcernCapsuleView) {
		%orig(nil);
		return;
	}
	%orig;
}

%end

%hook AWELiveAutoEnterStyleAView

- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYHideLiveView")) {
        self.hidden = YES;
        return;
    }
}

%end

// 隐藏同城顶端
%hook AWENearbyFullScreenViewModel

- (void)setShowSkyLight:(id)arg1 {
    if (DYYYGetBool(@"DYYYHideMenuView")) {
        arg1 = nil;
    }
    %orig(arg1);
}

- (void)setHaveSkyLight:(id)arg1 {
    if (DYYYGetBool(@"DYYYHideMenuView")) {
        arg1 = nil;
    }
    %orig(arg1);
}

%end

// 隐藏笔记
%hook AWECorrelationItemTag

- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHideItemTag")) {
        self.hidden = YES;
        return;
    }
}

%end

// 屏蔽模板按钮组件（底部互动）- hook button 方法返回 nil
%hook AWEPlayInteractionTemplateButton
- (id)button {
	BOOL DYYYHideBottomInteraction = DYYYGetBool(@"DYYYHideBottomInteraction");
	if (DYYYHideBottomInteraction) {
		return nil;
	}
	return %orig;
}

- (void)setButton:(id)button {
	BOOL DYYYHideBottomInteraction = DYYYGetBool(@"DYYYHideBottomInteraction");
	if (DYYYHideBottomInteraction) {
		return;  // 不设置按钮
	}
	%orig;
}
%end

// 隐藏右上搜索，但可点击
%hook AWEHPDiscoverFeedEntranceView

- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYHideDiscover")) {
        UIView *firstSubview = self.subviews.firstObject;
        if ([firstSubview isKindOfClass:[UIImageView class]]) {
            ((UIImageView *)firstSubview).image = nil;
        }
    }
}

%end

// 隐藏点击进入直播间
%hook AWELiveFeedStatusLabel
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideEnterLive")) {
        UIView *parentView = self.superview;
        UIView *grandparentView = parentView.superview;

        if (grandparentView) {
            grandparentView.hidden = YES;
            return;
        } else if (parentView) {
            parentView.hidden = YES;
            return;
        } else {
            self.hidden = YES;
            return;
        }
    }
    %orig;
}
%end

// 去除消息群直播提示
%hook AWEIMCellLiveStatusContainerView

- (void)p_initUI {
    if (![[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYHideGroupLiveIndicator"])
        %orig;
}
%end

%hook AWELiveStatusIndicatorView

- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideGroupLiveIndicator")) {
        self.hidden = YES;
        return;
    }
    %orig;
}
%end

%hook AWELiveFeedLabelTagView
- (void)layoutSubviews {

    if (DYYYGetBool(@"DYYYHideLiveCapsuleView")) {
        UIView *parentView = self.superview;
        if (parentView) {
            parentView.hidden = YES;
            return;
        } else {
            self.hidden = YES;
            return;
        }
    }
    %orig;
}

%end

%hook AWEPlayInteractionLiveExtendGuideView
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideLiveCapsuleView")) {
        [self removeFromSuperview];
        return;
    }
    %orig;
}
%end

// 隐藏首页直播胶囊
%hook AWEHPTopTabItemBadgeContentView
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideConcernCapsuleView")) {
        self.hidden = YES;
        return;
    }
    %orig;
}
%end

// 隐藏群商店
%hook AWEIMFansGroupTopDynamicDomainTemplateView
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideGroupShop")) {
        self.hidden = YES;
        return;
    }
    %orig;
}
%end

// 去除群聊天输入框上方快捷方式
%hook AWEIMInputActionBarInteractor

- (void)p_setupUI {
    if (DYYYGetBool(@"DYYYHideGroupInputActionBar")) {
        self.hidden = YES;
        return;
    }
    %orig;
}
%end

// 隐藏相机定位
%hook AWETemplateCommonView
- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHideCameraLocation")) {
        [self removeFromSuperview];
    }
}
%end

// 隐藏侧栏红点
%hook AWEHPTopBarCTAItemView

- (void)showRedDot {
    if (![[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYHideSidebarDot"])
        %orig;
}

- (void)hideCountRedDot {
    if (![[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYHideSidebarDot"])
        %orig;
}

- (void)layoutSubviews {
    %orig;

    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideSidebarDot"]) {
        return;
    }

    static char kDYSidebarBadgeCacheKey;
    NSArray *cachedBadges = objc_getAssociatedObject(self, &kDYSidebarBadgeCacheKey);
    if (!cachedBadges) {
        NSMutableArray *badges = [NSMutableArray array];
        for (UIView *subview in self.subviews) {
            if ([subview isKindOfClass:%c(DUXBadge)]) {
                [badges addObject:subview];
            }
        }
        cachedBadges = [badges copy];
        objc_setAssociatedObject(self, &kDYSidebarBadgeCacheKey, cachedBadges, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    for (UIView *badge in cachedBadges) {
        badge.hidden = YES;
    }
}
%end

// 隐藏搜同款
%hook ACCStickerContainerView
- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHideSearchSame")) {
        [self removeFromSuperview];
    }
}
%end

// 隐藏礼物展馆
%hook BDXWebView
- (void)layoutSubviews {
    %orig;

    BOOL enabled = DYYYGetBool(@"DYYYHideGiftPavilion");
    if (!enabled)
        return;

    NSString *title = [self valueForKey:@"title"];

    if ([title containsString:@"任务Banner"] || [title containsString:@"活动Banner"]) {
        self.hidden = YES;
    }
}
%end

%hook AWEVideoTypeTagView

- (void)setupUI {
    if (![[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYHideLiveGIF"])
        %orig;
}
%end

// 隐藏直播广场
%hook IESLiveFeedDrawerEntranceView
- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYHideLivePlayground")) {
        self.hidden = YES;
    }
}

%end

// 隐藏直播退出清屏、投屏按钮
%hook IESLiveButton

- (void)layoutSubviews {
    %orig;
    BOOL hideClear = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideLiveRoomClear"];
    BOOL hideMirror = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideLiveRoomMirroring"];
    BOOL hideFull = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideLiveRoomFullscreen"];
    BOOL hideClose = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideLiveRoomClose"];

    if (!(hideClear || hideMirror || hideFull)) {
        return;
    }

    NSString *label = self.accessibilityLabel;
    if (hideClear && [label isEqualToString:@"退出清屏"] && self.superview) {
        [self.superview removeFromSuperview];
        return;
    } else if (hideMirror && [label isEqualToString:@"投屏"] && self.superview) {
        self.superview.hidden = YES;
        return;
    } else if (hideFull && [label isEqualToString:@"横屏"] && self.superview) {
        static char kDYLiveButtonCacheKey;
        NSArray *cached = objc_getAssociatedObject(self, &kDYLiveButtonCacheKey);
        if (!cached) {
            cached = [self.subviews copy];
            objc_setAssociatedObject(self, &kDYLiveButtonCacheKey, cached, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        for (UIView *subview in cached) {
            subview.hidden = YES;
        }
        return;
    } else if (hideClose && [self.superview isKindOfClass:%c(HTSLive4LayerContainerView)]) {
        self.hidden = YES;
        return;
    }
}

%end

// 隐藏直播间右上方关闭直播按钮
%hook IESLiveLayoutPlaceholderView
- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHideLiveRoomClose")) {
        [self removeFromSuperview];
        return;
    }
}
%end

// 隐藏直播间流量弹窗
%hook AWELiveFlowAlertView
- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHideCellularAlert")) {
        self.hidden = YES;
        return;
    }
}
%end

// 隐藏直播间商品和推广
%hook IESECLivePluginLayoutView
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideLiveGoodsMsg")) {
        self.hidden = YES;
        return;
    }
    %orig;
}
%end

%hook IESECLiveCardSizeComponent
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideLiveGoodsMsg")) {
        self.hidden = YES;
        return;
    }
    %orig;
}
%end

%hook IESECLiveGoodsCardView
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideLiveGoodsMsg")) {
        self.hidden = YES;
        return;
    }
    %orig;
}
%end

%hook IESLiveBottomRightCardView
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideLiveGoodsMsg")) {
        self.hidden = YES;
        return;
    }
    %orig;
}
%end

%hook IESLiveGameCPExplainCardContainerImpl
- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHideLiveGoodsMsg")) {
        self.hidden = YES;
        return;
    }
}
%end

%hook AWEPOILivePurchaseAtmosphereView
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideLiveGoodsMsg") && self.superview) {
        self.superview.hidden = YES;
        return;
    }
    %orig;
}
%end

%hook IESLiveActivityBannnerView
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideLiveGoodsMsg")) {
        [self removeFromSuperview];
        return;
    }
    %orig;
}
%end

// 隐藏直播间点赞动画
%hook HTSLiveDiggView
- (void)setIconImageView:(UIImageView *)arg1 {
    if (DYYYGetBool(@"DYYYHideLiveLikeAnimation")) {
        %orig(nil);
    } else {
        %orig(arg1);
    }
}
%end

// 隐藏直播间文字贴纸
%hook IESLiveStickerView
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideStickerView")) {
        [self removeFromSuperview];
        return;
    }
    %orig;
}
%end

// 隐藏直播间礼物挑战
%hook IESLiveGroupLiveComponentView
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideGroupComponent")) {
        [self removeFromSuperview];
        return;
    }
    %orig;
}
%end

// 预约直播
%hook IESLivePreAnnouncementPanelViewNew
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideStickerView")) {
        self.hidden = YES;
        return;
    }
    %orig;
}
%end

// 隐藏会员进场特效
%hook IESLiveDynamicUserEnterView
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideLivePopup")) {
        self.hidden = YES;
        return;
    }
    %orig;
}
%end

// 会员进场特效: 高版本启用swift类名
%hook _TtC18IESLiveRevenueImpl32IESLiveSwiftDynamicUserEnterView
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideLivePopup")) {
        self.hidden = YES;
        return;
    }
    %orig;
}
%end

// 隐藏特殊进场特效
%hook PlatformCanvasView
- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHideLivePopup")) {
        UIView *pview = self.superview;
        UIView *gpview = pview.superview;
        // 基于accessibilitylabel的判断
        BOOL isLynxView = [pview isKindOfClass:%c(UILynxView)] && [gpview isKindOfClass:%c(LynxView)] && [gpview.accessibilityLabel isEqualToString:@"lynxview"];
        // 基于最近的视图控制器IESLiveAudienceViewController的判断
        UIViewController *vc = [DYYYUtils firstAvailableViewControllerFromView:self];
        BOOL isLiveAudienceVC = [vc isKindOfClass:%c(IESLiveAudienceViewController)];
        if (isLynxView && isLiveAudienceVC) {
            self.hidden = YES;
        }
    }
    return;
}
%end

// 特殊视频进场特效:高版本启用swift类名
%hook _TtC18IESLiveRevenueImpl35IESLiveSwiftVideoLayerUserEnterView
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideLivePopup")) {
        self.hidden = YES;
        return;
    }
    %orig;
}
%end

%hook IESLiveDanmakuVariousView
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideLiveDanmaku")) {
        self.hidden = YES;
        return;
    }
    %orig;
}

%end

%hook IESLiveDanmakuSupremeView
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYHideLiveDanmaku")) {
        self.hidden = YES;
        return;
    }
    %orig;
}
%end

%hook IESLiveHotMessageView
- (void)layoutSubviews {

    if (DYYYGetBool(@"DYYYHideLiveHotMessage")) {
        self.hidden = YES;
        return;
    }
    %orig;
}
%end

%hook AWEHotListDataController

%new
- (NSNumber *)dyyy_numberValueForLowLikesFilter:(id)rawValue {
    if (!rawValue || rawValue == [NSNull null]) {
        return nil;
    }

    if ([rawValue isKindOfClass:[NSNumber class]]) {
        return (NSNumber *)rawValue;
    }

    if ([rawValue isKindOfClass:[NSString class]]) {
        NSString *trimmed = [(NSString *)rawValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) {
            return nil;
        }

        NSScanner *integerScanner = [NSScanner scannerWithString:trimmed];
        long long integerValue = 0;
        if ([integerScanner scanLongLong:&integerValue] && integerScanner.isAtEnd) {
            return @(integerValue);
        }

        NSScanner *doubleScanner = [NSScanner scannerWithString:trimmed];
        double doubleValue = 0.0;
        if ([doubleScanner scanDouble:&doubleValue] && doubleScanner.isAtEnd) {
            return @((long long)llround(doubleValue));
        }
    }

    return nil;
}

%new
- (NSNumber *)dyyy_resolvedDiggCountForAweme:(AWEAwemeModel *)aweme {
    if (!aweme) {
        return nil;
    }

    static NSArray<NSString *> *diggKeyPaths = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        diggKeyPaths = @[
            @"statistics.diggCount",
            @"statistics.digg_count",
            @"diggCount",
            @"digg_count",
            @"feedSequenceExtendFeature.digg_count",
            @"feedSequenceExtendFeature.diggCount",
            @"recommendFeedExtendFeature.digg_count",
            @"recommendFeedExtendFeature.diggCount"
        ];
    });

    for (NSString *keyPath in diggKeyPaths) {
        id rawValue = nil;
        @try {
            rawValue = [aweme valueForKeyPath:keyPath];
        } @catch (__unused NSException *exception) {
            rawValue = nil;
        }

        NSNumber *resolved = [self dyyy_numberValueForLowLikesFilter:rawValue];
        if (resolved) {
            return resolved;
        }
    }

    return nil;
}

- (id)transferAwemeListIfNeededWithArray:(id)arg1 isInitFetch:(BOOL)arg2 {
    NSArray *orig = %orig;
    if (![orig isKindOfClass:[NSArray class]] || orig.count == 0) {
        return orig;
    }

    // --- 配置读取 ---
    NSInteger daysThreshold = DYYYGetInteger(@"DYYYFilterTimeLimit");
    BOOL skipLive = DYYYGetBool(@"DYYYSkipLive"); // 读取直播过滤开关
    NSInteger minLikesThreshold = DYYYGetInteger(@"DYYYFilterLowLikes"); // 读取低赞过滤阈值 (例如: 1000)
    BOOL skipPhotoText = DYYYGetBool(@"DYYYSkipPhotoText"); // 图文过滤
    BOOL skipPhoto = DYYYGetBool(@"DYYYSkipPhoto"); // 图集过滤

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval thresholdInSeconds = MAX(daysThreshold, 0) * 86400.0;

    // 第一阶段：先做稳定字段过滤（直播/时间/类型）
    NSMutableArray *baseFiltered = [NSMutableArray arrayWithCapacity:orig.count];

    for (id obj in orig) {
        if (![obj isKindOfClass:%c(AWEAwemeModel)]) {
            [baseFiltered addObject:obj];
            continue;
        }

        AWEAwemeModel *m = (AWEAwemeModel *)obj;

        // 1. 广告白名单
        if ([m respondsToSelector:@selector(isAds)] && m.isAds) {
            [baseFiltered addObject:obj];
            continue;
        }

        // 2. 直播过滤逻辑 (仅依赖 cellRoom)
        if (skipLive && [m respondsToSelector:@selector(cellRoom)] && m.cellRoom != nil) {
            continue; // 命中直播过滤，跳过
        }

        // 2.1 图文模式过滤逻辑（推荐页）
        if (skipPhotoText &&
            [m respondsToSelector:@selector(isNewTextMode)] &&
            m.isNewTextMode &&
            [m respondsToSelector:@selector(referString)] &&
            [m.referString isEqualToString:@"homepage_hot"]) {
            continue; // 图文模式且来自推荐页，跳过
        }

        // 2.2 图集过滤逻辑（推荐页）
        if (skipPhoto &&
            [m respondsToSelector:@selector(awemeType)] &&
            m.awemeType == 68 &&
            [m respondsToSelector:@selector(referString)] &&
            [m.referString isEqualToString:@"homepage_hot"]) {
            continue; // 图集且来自推荐页，跳过
        }

        // 3. 时间限制过滤
        if (daysThreshold > 0 && [m respondsToSelector:@selector(createTime)]) {
            NSTimeInterval vTs = [m.createTime doubleValue];
            if (vTs > 1e12) {
                vTs /= 1000.0; // 毫秒转秒
            }

            if (vTs > 0 && (now - vTs) > thresholdInSeconds) {
                continue; // 超过设定时限，跳过
            }
        }

        [baseFiltered addObject:obj];
    }

    if (minLikesThreshold <= 0 || baseFiltered.count == 0) {
        return [baseFiltered copy];
    }

    // 第二阶段：低赞过滤（字段缺失时放行，避免误杀）
    NSMutableArray *lowLikesFiltered = [NSMutableArray arrayWithCapacity:baseFiltered.count];
    NSInteger awemeCount = 0;
    NSInteger unresolvedLikesCount = 0;
    NSInteger filteredByLowLikesCount = 0;

    for (id obj in baseFiltered) {
        if (![obj isKindOfClass:%c(AWEAwemeModel)]) {
            [lowLikesFiltered addObject:obj];
            continue;
        }

        awemeCount++;
        AWEAwemeModel *m = (AWEAwemeModel *)obj;
        NSNumber *diggCountValue = [self dyyy_resolvedDiggCountForAweme:m];
        NSInteger diggCount = diggCountValue.integerValue;

        // 新版部分链路点赞字段会短暂缺失/回填为0，这里按未知放行，避免整批误过滤
        if (!diggCountValue || diggCount <= 0) {
            unresolvedLikesCount++;
            [lowLikesFiltered addObject:obj];
            continue;
        }

        if (diggCount < minLikesThreshold) {
            filteredByLowLikesCount++;
            continue;
        }

        [lowLikesFiltered addObject:obj];
    }

    CGFloat unresolvedRatio = awemeCount > 0 ? ((CGFloat)unresolvedLikesCount / (CGFloat)awemeCount) : 0.0f;
    BOOL shouldRollbackLowLikes = (awemeCount >= 3 && lowLikesFiltered.count <= 1 && unresolvedRatio >= 0.5f);
    BOOL shouldPreventEmptyBatch = (awemeCount >= 3 && lowLikesFiltered.count == 0 && filteredByLowLikesCount > 0);

    if (shouldRollbackLowLikes || shouldPreventEmptyBatch) {
        NSLog(@"[DYYY] 低赞过滤回退: total=%ld kept=%ld unresolved=%ld lowLikesFiltered=%ld threshold=%ld",
              (long)awemeCount,
              (long)lowLikesFiltered.count,
              (long)unresolvedLikesCount,
              (long)filteredByLowLikesCount,
              (long)minLikesThreshold);
        return [baseFiltered copy];
    }

    return [lowLikesFiltered copy];
}

%end

%hook AWEAwemeModel

- (id)initWithDictionary:(id)arg1 error:(id *)arg2 {
    id orig = %orig;
    if (orig && [self contentFilter])
        return nil;
    return orig;
}

%new
- (BOOL)contentFilter {
    BOOL noAds = DYYYGetBool(@"DYYYNoAds");
    BOOL skipAllLive = DYYYGetBool(@"DYYYSkipAllLive");
    BOOL skipHotSpot = DYYYGetBool(@"DYYYSkipHotSpot");
    BOOL skipPhoto = DYYYGetBool(@"DYYYSkipPhoto");
    BOOL skipPhotoText = DYYYGetBool(@"DYYYSkipPhotoText");
    BOOL skipMusic = DYYYGetBool(@"DYYYSkipMusic");
    BOOL skipAIInteraction = DYYYGetBool(@"DYYYSkipAIInteraction");
    BOOL filterHDR = DYYYGetBool(@"DYYYFilterFeedHDR") || DYYYShouldFilterGlobalHDR();

    BOOL shouldFilterAds = noAds && (self.isAds);
    BOOL shouldFilterHotSpot = skipHotSpot && self.hotSpotLynxCardModel;
    BOOL shouldFilterAllLive = skipAllLive && [self.videoFeedTag isEqualToString:@"直播中"];
    BOOL isRecommendFeed = [self.referString isEqualToString:@"homepage_hot"];
    BOOL shouldskipPhoto = skipPhoto && (self.awemeType == 68) && isRecommendFeed;
    BOOL shouldskipPhotoText = skipPhotoText && self.isNewTextMode && isRecommendFeed;
    BOOL shouldFilterMusic = skipMusic && self.musicCard && isRecommendFeed; // or self.awemeType == 155
    BOOL shouldFilterAIInteraction = skipAIInteraction && (self.awemeType == 162) && isRecommendFeed;
    BOOL shouldFilterHDR = NO;
    BOOL shouldFilterLowLikes = NO;
    BOOL shouldFilterKeywords = NO;
    BOOL shouldFilterProp = NO;
    BOOL shouldFilterTime = NO;
    BOOL shouldFilterUser = NO;

    // 获取用户设置的需要过滤的关键词
    NSString *filterKeywords = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYFilterKeywords"];
    NSArray *keywordsList = nil;

    if (filterKeywords.length > 0) {
        keywordsList = [filterKeywords componentsSeparatedByString:@","];
    }

    // 过滤包含指定拍同款的视频
    NSString *filterProp = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYFilterProp"];
    NSArray *propKeywordsList = nil;

    if (filterProp.length > 0) {
        propKeywordsList = [filterProp componentsSeparatedByString:@","];
    }

    // 获取需要过滤的用户列表
    NSString *filterUsers = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYFilterUsers"];

    // 检查是否需要过滤特定用户
    if (isRecommendFeed && filterUsers.length > 0 && self.author) {
        NSArray *usersList = [filterUsers componentsSeparatedByString:@","];
        NSString *currentShortID = self.author.shortID;
        NSString *currentNickname = self.author.nickname;

        if (currentShortID.length > 0) {
            for (NSString *userInfo in usersList) {
                // 解析"昵称-id"格式
                NSArray *components = [userInfo componentsSeparatedByString:@"-"];
                if (components.count >= 2) {
                    NSString *userId = [components lastObject];
                    NSString *userNickname = [[components subarrayWithRange:NSMakeRange(0, components.count - 1)] componentsJoinedByString:@"-"];

                    if ([userId isEqualToString:currentShortID]) {
                        shouldFilterUser = YES;
                        break;
                    }
                }
            }
        }
    }

    // 仅在推荐页过滤关键词和道具
    if (isRecommendFeed) {
        // 过滤包含特定关键词的视频
        if (keywordsList.count > 0) {
            // 检查视频标题
            if (self.descriptionString.length > 0) {
                for (NSString *keyword in keywordsList) {
                    NSString *trimmedKeyword = [keyword stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (trimmedKeyword.length > 0 && [self.descriptionString containsString:trimmedKeyword]) {
                        shouldFilterKeywords = YES;
                        break;
                    }
                }
            }
        }

        // 过滤包含特定道具的视频
        if (propKeywordsList.count > 0 && self.propGuideV2) {
            NSString *propName = self.propGuideV2.propName;
            if (propName.length > 0) {
                for (NSString *propKeyword in propKeywordsList) {
                    NSString *trimmedKeyword = [propKeyword stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (trimmedKeyword.length > 0 && [propName containsString:trimmedKeyword]) {
                        shouldFilterProp = YES;
                        break;
                    }
                }
            }
        }
    }


    // 检查是否为HDR视频
    if (filterHDR && self.video && self.video.bitrateModels) {
        for (id bitrateModel in self.video.bitrateModels) {
            NSNumber *hdrType = [bitrateModel valueForKey:@"hdrType"];
            NSNumber *hdrBit = [bitrateModel valueForKey:@"hdrBit"];

            // 如果hdrType=1且hdrBit=10，则视为HDR视频
            if (hdrType && [hdrType integerValue] == 1 && hdrBit && [hdrBit integerValue] == 10) {
                shouldFilterHDR = YES;
                break;
            }
        }
    }
    return shouldFilterAds || shouldFilterAllLive || shouldFilterHotSpot || shouldFilterHDR || shouldFilterKeywords || shouldFilterProp ||
           shouldFilterTime || shouldFilterUser;
}

- (AWEECommerceLabel *)ecommerceBelowLabel {
    if (DYYYGetBool(@"DYYYHideHisShop")) {
        return nil;
    }
    return %orig;
}

- (void)setEcommerceBelowLabel:(id)label {
	if (DYYYGetBool(@"DYYYHideHisShop")) {
		%orig(nil);
		return;
	}
	%orig;
}

- (void)setDescriptionString:(NSString *)desc {
    NSString *labelStyle = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYLabelStyle"];
    BOOL hideLabel = [labelStyle isEqualToString:@"文案标签隐藏"];
    if (hideLabel) {
        // 过滤掉所有以 # 开头的标签
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"#\\S+" options:0 error:nil];
        NSString *filtered = [regex stringByReplacingMatchesInString:desc options:0 range:NSMakeRange(0, desc.length) withTemplate:@""];
        // 去除首尾空白字符
        filtered = [filtered stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        // 为空则赋nil，避免显示空行
        desc = filtered.length > 0 ? filtered : nil;
    }
    %orig(desc);
}

- (void)setTextExtras:(NSArray *)extras {
    NSString *labelStyle = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYLabelStyle"];
    BOOL disableLabelSearch = [labelStyle isEqualToString:@"文案标签禁止跳转搜索"] || [labelStyle isEqualToString:@"文案标签隐藏"];
    if (disableLabelSearch && [extras isKindOfClass:[NSArray class]]) {
        NSMutableArray *filtered = [NSMutableArray array];
        for (AWEAwemeTextExtraModel *model in extras) {
            if (model.userID.length > 0) {
                [filtered addObject:model];
            }
        }
        extras = [filtered copy];
    }
    %orig(extras);
}

// 固定设置为 1，启用自定义背景色
- (NSUInteger)awe_playerBackgroundViewShowType {
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYVideoBGColor"]) {
        return 1;
    }
    return %orig;
}

- (UIColor *)awe_smartBackgroundColor {
    NSString *colorHex = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYVideoBGColor"];
    if (colorHex && colorHex.length > 0) {
        CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
        UIColor *customColor = [DYYYUtils colorFromSchemeHexString:colorHex targetWidth:screenWidth];
        if (customColor)
            return customColor;
    }
    return %orig;
}

//屏蔽章节要点数据
- (NSArray *)chapterList {
	BOOL hideChapterList = DYYYGetBool(@"DYYYHideChapterProgress");
	if (hideChapterList) {
		return @[]; // 返回空数组
	}
	return %orig;
}

// 屏蔽共创数据
- (id)acceptedCoCreators {
	BOOL DYYYHideGongChuang = DYYYGetBool(@"DYYYHideGongChuang");
	if (DYYYHideGongChuang) {
		return @[]; // 永远为空
	}
	return %orig;
}

- (id)unAcceptedCoCreators {
	BOOL DYYYHideGongChuang = DYYYGetBool(@"DYYYHideGongChuang");
	if (DYYYHideGongChuang) {
		return @[];
	}
	return %orig;
}

- (NSInteger)acceptedCoCreatorsNums {
	BOOL DYYYHideGongChuang = DYYYGetBool(@"DYYYHideGongChuang");
	if (DYYYHideGongChuang) {
		return 0;
	}
	return %orig;
}

- (id)awe_coCreatorPoster {
	BOOL DYYYHideGongChuang = DYYYGetBool(@"DYYYHideGongChuang");
	if (DYYYHideGongChuang) {
		return nil;
	}
	return %orig;
}

- (id)awe_coCreatorFromAuthor {
	BOOL DYYYHideGongChuang = DYYYGetBool(@"DYYYHideGongChuang");
	if (DYYYHideGongChuang) {
		return nil;
	}
	return %orig;
}

- (id)awe_userModelWithCoCreator:(id)creator {
	BOOL DYYYHideGongChuang = DYYYGetBool(@"DYYYHideGongChuang");
	if (DYYYHideGongChuang) {
		return nil;
	}
	return %orig;
}


// 屏蔽相关视频推荐
- (id)relatedVideoExtra {
	BOOL DYYYHideBottomRelated = DYYYGetBool(@"DYYYHideBottomRelated");
	if (DYYYHideBottomRelated) {
		return nil;
	}
	return %orig;
}

- (id)relatedVideo {
	BOOL DYYYHideBottomRelated = DYYYGetBool(@"DYYYHideBottomRelated");
	if (DYYYHideBottomRelated) {
		return nil;
	}
	return %orig;
}

- (id)playletRelatedVideoInfoModel {
	BOOL DYYYHideBottomRelated = DYYYGetBool(@"DYYYHideBottomRelated");
	if (DYYYHideBottomRelated) {
		return nil;
	}
	return %orig;
}

// 屏蔽评论搜索锚点
- (id)commonSearchAnchor {
	BOOL DYYYHideCommentLongPressSearch = DYYYGetBool(@"DYYYHideCommentLongPressSearch");
	if (DYYYHideCommentLongPressSearch) {
		return nil;
	}
	return %orig;
}

- (void)setCommonSearchAnchor:(id)arg {
	BOOL DYYYHideCommentLongPressSearch = DYYYGetBool(@"DYYYHideCommentLongPressSearch");
	if (DYYYHideCommentLongPressSearch) {
		%orig(nil);
		return;
	}
	%orig;
}

// 屏蔽汽水音乐锚点
- (id)relatedMusicAnchor {
	BOOL DYYYHideQuqishuiting = DYYYGetBool(@"DYYYHideQuqishuiting");
	if (DYYYHideQuqishuiting) {
		return nil;
	}
	return %orig;
}

- (void)setRelatedMusicAnchor:(id)anchor {
	BOOL DYYYHideQuqishuiting = DYYYGetBool(@"DYYYHideQuqishuiting");
	if (DYYYHideQuqishuiting) {
		%orig(nil);
		return;
	}
	%orig;
}

// 屏蔽底栏热点
- (id)hotSpotRawData {
	BOOL DYYYHideHotspot = DYYYGetBool(@"DYYYHideHotspot");
	if (DYYYHideHotspot) {
		return nil;
	}
	return %orig;
}

- (void)setHotSpotRawData:(id)data {
	BOOL DYYYHideHotspot = DYYYGetBool(@"DYYYHideHotspot");
	if (DYYYHideHotspot) {
		%orig(nil);
		return;
	}
	%orig;
}

- (id)hotSpotListModel {
	BOOL DYYYHideHotspot = DYYYGetBool(@"DYYYHideHotspot");
	if (DYYYHideHotspot) {
		return nil;
	}
	return %orig;
}

- (void)setHotSpotListModel:(id)model {
	BOOL DYYYHideHotspot = DYYYGetBool(@"DYYYHideHotspot");
	if (DYYYHideHotspot) {
		%orig(nil);
		return;
	}
	%orig;
}

- (NSString *)templateBarsString {
	BOOL DYYYHideHotspot = DYYYGetBool(@"DYYYHideHotspot");
	if (DYYYHideHotspot) {
		return @"";
	}
	return %orig;
}

- (void)setTemplateBarsString:(NSString *)string {
	BOOL DYYYHideHotspot = DYYYGetBool(@"DYYYHideHotspot");
	if (DYYYHideHotspot) {
		%orig(@"");
		return;
	}
	%orig;
}

// 屏蔽底部合集（只对推荐页生效）
- (id)mixInfo {
	BOOL DYYYHideTemplateVideo = DYYYGetBool(@"DYYYHideTemplateVideo");
	if (DYYYHideTemplateVideo && [self.referString isEqualToString:@"homepage_hot"]) {
		return nil;
	}
	return %orig;
}

// 屏蔽短剧信息（复用屏蔽合集开关，只对推荐页生效）
- (id)playletInfoModel {
	BOOL DYYYHideTemplatePlaylet = DYYYGetBool(@"DYYYHideTemplatePlaylet");
	if (DYYYHideTemplatePlaylet && [self.referString isEqualToString:@"homepage_hot"]) {
		return nil;
	}
	return %orig;
}

// 屏蔽锚点信息
- (id)anchorInfo {
	BOOL DYYYHideFeedAnchorContainer = DYYYGetBool(@"DYYYHideFeedAnchorContainer");
	if (DYYYHideFeedAnchorContainer) {
		return nil;
	}
	return %orig;
}

- (void)setAnchorInfo:(id)info {
	BOOL DYYYHideFeedAnchorContainer = DYYYGetBool(@"DYYYHideFeedAnchorContainer");
	if (DYYYHideFeedAnchorContainer) {
		%orig(nil);
		return;
	}
	%orig;
}

- (id)localLifeAnchorInfo {
	BOOL DYYYHideFeedAnchorContainer = DYYYGetBool(@"DYYYHideFeedAnchorContainer");
	if (DYYYHideFeedAnchorContainer) {
		return nil;
	}
	return %orig;
}

- (void)setLocalLifeAnchorInfo:(id)info {
	BOOL DYYYHideFeedAnchorContainer = DYYYGetBool(@"DYYYHideFeedAnchorContainer");
	if (DYYYHideFeedAnchorContainer) {
		%orig(nil);
		return;
	}
	%orig;
}

- (id)nearbyFeedDualAnchorInfo {
	BOOL DYYYHideFeedAnchorContainer = DYYYGetBool(@"DYYYHideFeedAnchorContainer");
	if (DYYYHideFeedAnchorContainer) {
		return nil;
	}
	return %orig;
}

- (void)setNearbyFeedDualAnchorInfo:(id)info {
	BOOL DYYYHideFeedAnchorContainer = DYYYGetBool(@"DYYYHideFeedAnchorContainer");
	if (DYYYHideFeedAnchorContainer) {
		%orig(nil);
		return;
	}
	%orig;
}

- (id)minorAnchorInfo {
	BOOL DYYYHideFeedAnchorContainer = DYYYGetBool(@"DYYYHideFeedAnchorContainer");
	if (DYYYHideFeedAnchorContainer) {
		return nil;
	}
	return %orig;
}

- (void)setMinorAnchorInfo:(id)info {
	BOOL DYYYHideFeedAnchorContainer = DYYYGetBool(@"DYYYHideFeedAnchorContainer");
	if (DYYYHideFeedAnchorContainer) {
		%orig(nil);
		return;
	}
	%orig;
}

// 屏蔽通用锚点（合并到锚点信息）
- (id)commonAnchor {
	BOOL DYYYHideFeedAnchorContainer = DYYYGetBool(@"DYYYHideFeedAnchorContainer");
	if (DYYYHideFeedAnchorContainer) { 
		return nil;
	}
	return %orig;
}

- (void)setCommonAnchor:(id)anchor {
	BOOL DYYYHideFeedAnchorContainer = DYYYGetBool(@"DYYYHideFeedAnchorContainer");
	if (DYYYHideFeedAnchorContainer) {
		%orig(nil);
		return;
	}
	%orig;
}

// 屏蔽作者声明及风险提示
- (id)riskInfoModel {
	BOOL DYYYHideAntiAddictedNotice = DYYYGetBool(@"DYYYHideAntiAddictedNotice");
	if (DYYYHideAntiAddictedNotice) {
		return nil;
	}
	return %orig;
}

- (void)setRiskInfoModel:(id)model {
	BOOL DYYYHideAntiAddictedNotice = DYYYGetBool(@"DYYYHideAntiAddictedNotice");
	if (DYYYHideAntiAddictedNotice) {
		%orig(nil);
		return;
	}
	%orig;
}

%end



//以下部分为新增
// 屏蔽头像直播
%hook AWEUserModel

- (NSNumber *)roomID {
	BOOL DYYYHideAvatarLive = DYYYGetBool(@"DYYYHideAvatarLive");
	if (DYYYHideAvatarLive) {
		return @(0);
	}
	return %orig;
}

%end


// 屏蔽头像光圈
%hook AWEUserModel

- (id)storyRing {
	BOOL DYYYHideAvatarRing = DYYYGetBool(@"DYYYHideAvatarRing");
	if (DYYYHideAvatarRing) {
		return nil;
	}
	return %orig;
}

- (void)setStoryRing:(id)ring {
	BOOL DYYYHideAvatarRing = DYYYGetBool(@"DYYYHideAvatarRing");
	if (DYYYHideAvatarRing) {
		%orig(nil);
		return;
	}
	%orig;
}

%end

%hook AWECodeGenStoryRingInfoModel

- (NSArray *)storyRingsModelArray {
	BOOL DYYYHideAvatarRing = DYYYGetBool(@"DYYYHideAvatarRing");
	if (DYYYHideAvatarRing) {
		return @[];
	}
	return %orig;
}

- (void)setStoryRingsModelArray:(NSArray *)array {
	BOOL DYYYHideAvatarRing = DYYYGetBool(@"DYYYHideAvatarRing");
	if (DYYYHideAvatarRing) {
		%orig(@[]);
		return;
	}
	%orig;
}

%end

// 屏蔽挑战贴纸
%hook AWEInteractionHashtagStickerModel

- (id)hashtagInfo {
	BOOL DYYYHideChallengeStickers = DYYYGetBool(@"DYYYHideChallengeStickers");
	if (DYYYHideChallengeStickers) {
		return nil;
	}
	return %orig;
}

- (void)setHashtagInfo:(id)info {
	BOOL DYYYHideChallengeStickers = DYYYGetBool(@"DYYYHideChallengeStickers");
	if (DYYYHideChallengeStickers) {
		%orig(nil);
		return;
	}
	%orig;
}

- (id)hashtagId {
	BOOL DYYYHideChallengeStickers = DYYYGetBool(@"DYYYHideChallengeStickers");
	if (DYYYHideChallengeStickers) {
		return nil;
	}
	return %orig;
}

- (id)hashtagName {
	BOOL DYYYHideChallengeStickers = DYYYGetBool(@"DYYYHideChallengeStickers");
	if (DYYYHideChallengeStickers) {
		return nil;
	}
	return %orig;
}

%end

// 屏蔽互动贴纸
%hook AWEInteractionEditTagStickerModel

- (id)editTagInfo {
	if (DYYYGetBool(@"DYYYHideEditTag")) {
		return nil;
	}
	return %orig;
}

- (void)setEditTagInfo:(id)info {
	if (DYYYGetBool(@"DYYYHideEditTag")) {
		%orig(nil);
		return;
	}
	%orig;
}

%end


// 隐藏下面底部热点框
%hook AWEHotSpotListModel

- (BOOL)disableDisplay {
	BOOL DYYYHideHotspot = DYYYGetBool(@"DYYYHideHotspot");
	if (DYYYHideHotspot) {
		return YES;
	}
	return %orig;
}

- (BOOL)disableDisplayInner {
	BOOL DYYYHideHotspot = DYYYGetBool(@"DYYYHideHotspot");
	if (DYYYHideHotspot) {
		return YES;
	}
	return %orig;
}

- (NSString *)hotSpotTipTitleHeader {
	BOOL DYYYHideHotspot = DYYYGetBool(@"DYYYHideHotspot");
	if (DYYYHideHotspot) {
		return @"";
	}
	return %orig;
}

- (NSString *)hotSpotTipTitle {
	BOOL DYYYHideHotspot = DYYYGetBool(@"DYYYHideHotspot");
	if (DYYYHideHotspot) {
		return @"";
	}
	return %orig;
}

- (NSString *)hotSpotTipTitleFooter {
	BOOL DYYYHideHotspot = DYYYGetBool(@"DYYYHideHotspot");
	if (DYYYHideHotspot) {
		return @"";
	}
	return %orig;
}

- (NSString *)hotInfoWord {
	BOOL DYYYHideHotspot = DYYYGetBool(@"DYYYHideHotspot");
	if (DYYYHideHotspot) {
		return @"";
	}
	return %orig;
}

- (NSString *)i18NTipTitle {
	BOOL DYYYHideHotspot = DYYYGetBool(@"DYYYHideHotspot");
	if (DYYYHideHotspot) {
		return @"";
	}
	return %orig;
}

- (NSString *)tipSchema {
	BOOL DYYYHideHotspot = DYYYGetBool(@"DYYYHideHotspot");
	if (DYYYHideHotspot) {
		return nil;
	}
	return %orig;
}

- (NSDictionary *)extraDictionary {
	BOOL DYYYHideHotspot = DYYYGetBool(@"DYYYHideHotspot");
	if (DYYYHideHotspot) {
		return @{};
	}
	return %orig;
}

- (NSDictionary *)relativityExtra {
	BOOL DYYYHideHotspot = DYYYGetBool(@"DYYYHideHotspot");
	if (DYYYHideHotspot) {
		return @{};
	}
	return %orig;
}

%end

// 屏蔽精选标签
%hook AWETemplateStaticLabelInfoModel

- (NSArray *)containers {
	if (DYYYGetBool(@"DYYYHideTemplateLabel")) {
		return @[];
	}
	return %orig;
}

- (void)setContainers:(NSArray *)containers {
	if (DYYYGetBool(@"DYYYHideTemplateLabel")) {
		%orig(@[]);
		return;
	}
	%orig;
}

%end

// 隐藏好友推荐
%hook AFDFriendRecommendTagView

- (void)layoutSubviews {
	if (DYYYGetBool(@"DYYYHideFriendRecommend")) {
		self.hidden = YES;
		return;
	}
	%orig;
}

%end

// 屏蔽汽水音乐锚点 - hook AWERelatedMusicAnchorModel
%hook AWERelatedMusicAnchorModel

- (instancetype)init {
	BOOL DYYYHideQuqishuiting = DYYYGetBool(@"DYYYHideQuqishuiting");
	if (DYYYHideQuqishuiting) {
		return nil;
	}
	return %orig;
}

- (instancetype)initWithDictionary:(id)dict error:(NSError **)error {
	BOOL DYYYHideQuqishuiting = DYYYGetBool(@"DYYYHideQuqishuiting");
	if (DYYYHideQuqishuiting) {
		return nil;
	}
	return %orig;
}

%end

// 屏蔽汽水音乐 - 清空 commentTopBarInfo
%hook AWEMusicExtraModel

- (id)commentTopBarInfo {
	BOOL DYYYHideQuqishuiting = DYYYGetBool(@"DYYYHideQuqishuiting");
	if (DYYYHideQuqishuiting) {
		return nil;
	}
	return %orig;
}

- (void)setCommentTopBarInfo:(id)info {
	BOOL DYYYHideQuqishuiting = DYYYGetBool(@"DYYYHideQuqishuiting");
	if (DYYYHideQuqishuiting) {
		%orig(nil);
		return;
	}
	%orig;
}

%end


// 拦截开屏广告 - hook TTAdSplashModel，直接返回 nil
%hook TTAdSplashModel

+ (id)alloc {
	if (DYYYGetBool(@"DYYYNoAds")) {
		return nil;  // 直接返回 nil，阻止对象创建
	}
	return %orig;
}

%end

%hook AWEOriginalAdModel
- (instancetype)init {
	BOOL noAds = DYYYGetBool(@"DYYYNoAds");
	if (noAds) {
		return nil;  // 阻止创建，直接返回 nil
	}
	return %orig;
}

- (instancetype)initWithDictionary:(id)dict error:(NSError **)error {
	BOOL noAds = DYYYGetBool(@"DYYYNoAds");
	if (noAds) {
		return nil;  // 阻止创建，直接返回 nil
	}
	return %orig;
}
%end

// 屏蔽 AWEGeneralSearchModel 中的广告卡（强判定）
%hook AWEGeneralSearchModel
- (instancetype)initWithDictionary:(id)dict error:(NSError **)error {
	id orig = %orig;
	
	BOOL noAds = DYYYGetBool(@"DYYYNoAds");
	if (!noAds || !orig) {
		return orig;
	}
	
	// 强判定：检查是否为广告卡（检查 commonDynamicPatchModel.is_ad == 1）
	if ([[orig valueForKeyPath:@"commonDynamicPatchModel.is_ad"] integerValue] == 1) {
		return nil;
	}
	
	return orig;
}
%end

// 去除启动视频广告
%hook AWEAwesomeSplashFeedCellOldAccessoryView

// 在方法入口处添加控制逻辑
- (id)ddExtraView {
	if (DYYYGetBool(@"DYYYNoAds")) {
		return NULL; // 返回空视图
	}

	// 正常模式调用原始方法
	return %orig;
}

%end

// 屏蔽青少年模式弹窗
%hook AWETeenModeAlertView
- (BOOL)show {
	if (DYYYGetBool(@"DYYYHideTeenMode")) {
		return NO;
	}
	return %orig;
}
%end

// 屏蔽青少年模式弹窗
%hook AWETeenModeSimpleAlertView
- (BOOL)show {
	if (DYYYGetBool(@"DYYYHideTeenMode")) {
		return NO;
	}
	return %orig;
}
%end













%hook AWEFeedCommentConfigModel
- (void)setCommentInputConfigText:(NSString *)text {
    NSString *customText = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYCommentContent"];
    if (customText && customText.length > 0) {
        text = customText;
    }
    %orig(text);
}
%end

%hook AWEAwemeStatusModel
- (void)setListenVideoStatus:(NSInteger)status {
    if (status == 1 && DYYYGetBool(@"DYYYEnableBackgroundListen")) {
        status = 2;
    }
    %orig(status);
}
%end

%hook MTKView

- (void)layoutSubviews {
    %orig;
    UIViewController *vc = [DYYYUtils firstAvailableViewControllerFromView:self];
    Class playVCClass = NSClassFromString(@"AWEPlayVideoViewController");
    if (vc && playVCClass && [vc isKindOfClass:playVCClass]) {
        NSString *colorHex = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYVideoBGColor"];
        if (colorHex && colorHex.length > 0) {
            CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
            UIColor *customColor = [DYYYUtils colorFromSchemeHexString:colorHex targetWidth:screenWidth];
            if (customColor)
                self.backgroundColor = customColor;
        }
    }
}

%end

%hook AWEPlayInteractionUserAvatarView
- (void)layoutSubviews {
    %orig;

    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideFollowPromptView"]) {
        return;
    }

    static char kDYAvatarCacheKey;
    NSArray *viewCache = objc_getAssociatedObject(self, &kDYAvatarCacheKey);
    if (!viewCache) {
        NSMutableArray *tmp = [NSMutableArray array];
        for (UIView *subview in self.subviews) {
            if ([subview isMemberOfClass:[UIView class]]) {
                [tmp addObject:subview];
            }
        }
        viewCache = [tmp copy];
        objc_setAssociatedObject(self, &kDYAvatarCacheKey, viewCache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    for (UIView *container in viewCache) {
        for (UIView *child in container.subviews) {
            child.alpha = 0.0;
        }
    }
}
%end

%hook AWEPlayInteractionViewController

- (void)onPlayer:(id)arg0 didDoubleClick:(id)arg1 {
    BOOL isPopupEnabled = DYYYGetBool(@"DYYYEnableDoubleTapMenu");
    BOOL isDirectCommentEnabled = DYYYGetBool(@"DYYYEnableDoubleOpenComment");

    // 直接打开评论区的情况
    if (isDirectCommentEnabled) {
        [self performCommentAction];
        return;
    }

    if (isPopupEnabled) {
        AWEAwemeModel *awemeModel = nil;

        awemeModel = [self performSelector:@selector(awemeModel)];

        AWEVideoModel *videoModel = awemeModel.video;
        AWEMusicModel *musicModel = awemeModel.music;
        NSURL *audioURL = nil;
        if (musicModel && musicModel.playURL && musicModel.playURL.originURLList.count > 0) {
            audioURL = [NSURL URLWithString:musicModel.playURL.originURLList.firstObject];
        }

        // 确定内容类型（视频或图片）
        BOOL isImageContent = (awemeModel.awemeType == 68);
        // 判断是否为新版实况照片
        BOOL isNewLivePhoto = (awemeModel.video && awemeModel.animatedImageVideoInfo != nil);
        NSString *downloadTitle;

        if (isImageContent) {
            AWEImageAlbumImageModel *currentImageModel = nil;
            if (awemeModel.currentImageIndex > 0 && awemeModel.currentImageIndex <= awemeModel.albumImages.count) {
                currentImageModel = awemeModel.albumImages[awemeModel.currentImageIndex - 1];
            } else {
                currentImageModel = awemeModel.albumImages.firstObject;
            }

            if (awemeModel.albumImages.count > 1) {
                downloadTitle = (currentImageModel.clipVideo != nil || awemeModel.isLivePhoto) ? @"保存当前实况" : @"保存当前图片";
            } else {
                downloadTitle = (currentImageModel.clipVideo != nil || awemeModel.isLivePhoto) ? @"保存实况" : @"保存图片";
            }
        } else if (isNewLivePhoto) {
            downloadTitle = @"保存实况";
        } else {
            downloadTitle = @"保存视频";
        }

        AWEUserActionSheetView *actionSheet = [[NSClassFromString(@"AWEUserActionSheetView") alloc] init];
        NSMutableArray *actions = [NSMutableArray array];

        // 添加下载选项
        if (DYYYGetBool(@"DYYYDoubleTapDownload") || ![[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYDoubleTapDownload"]) {

            AWEUserSheetAction *downloadAction = [NSClassFromString(@"AWEUserSheetAction")
                actionWithTitle:downloadTitle
                        imgName:nil
                        handler:^{
                          if (isImageContent) {
                              // 图片内容
                              AWEImageAlbumImageModel *currentImageModel = nil;
                              if (awemeModel.currentImageIndex > 0 && awemeModel.currentImageIndex <= awemeModel.albumImages.count) {
                                  currentImageModel = awemeModel.albumImages[awemeModel.currentImageIndex - 1];
                              } else {
                                  currentImageModel = awemeModel.albumImages.firstObject;
                              }

                              // 查找非.image后缀的URL
                              NSURL *downloadURL = nil;
                              for (NSString *urlString in currentImageModel.urlList) {
                                  NSURL *url = [NSURL URLWithString:urlString];
                                  NSString *pathExtension = [url.path.lowercaseString pathExtension];
                                  if (![pathExtension isEqualToString:@"image"]) {
                                      downloadURL = url;
                                      break;
                                  }
                              }

                              if (currentImageModel.clipVideo != nil) {
                                  NSURL *videoURL = [currentImageModel.clipVideo.playURL getDYYYSrcURLDownload];
                                  [DYYYManager downloadLivePhoto:downloadURL
                                                        videoURL:videoURL
                                                      completion:^{
                                                      }];
                              } else if (currentImageModel && currentImageModel.urlList.count > 0) {
                                  if (downloadURL) {
                                      [DYYYManager downloadMedia:downloadURL
                                                       mediaType:MediaTypeImage
                                                           audio:nil
                                                      completion:^(BOOL success) {
                                                        if (success) {
                                                        } else {
                                                            [DYYYUtils showToast:@"图片保存已取消"];
                                                        }
                                                      }];
                                  } else {
                                      [DYYYUtils showToast:@"没有找到合适格式的图片"];
                                  }
                              }
                          } else if (isNewLivePhoto) {
                              // 新版实况照片
                              // 使用封面URL作为图片URL
                              NSURL *imageURL = nil;
                              if (videoModel.coverURL && videoModel.coverURL.originURLList.count > 0) {
                                  imageURL = [NSURL URLWithString:videoModel.coverURL.originURLList.firstObject];
                              }

                              // 视频URL从视频模型获取
                              NSURL *videoURL = nil;
                              if (videoModel && videoModel.playURL && videoModel.playURL.originURLList.count > 0) {
                                  videoURL = [NSURL URLWithString:videoModel.playURL.originURLList.firstObject];
                              } else if (videoModel && videoModel.h264URL && videoModel.h264URL.originURLList.count > 0) {
                                  videoURL = [NSURL URLWithString:videoModel.h264URL.originURLList.firstObject];
                              }

                              // 下载实况照片
                              if (imageURL && videoURL) {
                                  [DYYYManager downloadLivePhoto:imageURL
                                                        videoURL:videoURL
                                                      completion:^{
                                                      }];
                              }
                          } else {
                              if (videoModel.h264URL && videoModel.h264URL.originURLList.count > 0) {
                                  NSURL *url = [NSURL URLWithString:videoModel.h264URL.originURLList.firstObject];
                                  [DYYYManager downloadMedia:url
                                                   mediaType:MediaTypeVideo
                                                       audio:audioURL
                                                  completion:^(BOOL success){
                                                  }];
                              }
                          }
                        }];
            [actions addObject:downloadAction];

            // 如果是图集，添加下载所有图片选项
            if (isImageContent && awemeModel.albumImages.count > 1) {
                // 检查是否有实况照片
                BOOL hasLivePhoto = NO;
                for (AWEImageAlbumImageModel *imageModel in awemeModel.albumImages) {
                    if (imageModel.clipVideo != nil) {
                        hasLivePhoto = YES;
                        break;
                    }
                }

                NSString *actionTitle = hasLivePhoto ? @"保存所有实况" : @"保存所有图片";

                AWEUserSheetAction *downloadAllAction = [NSClassFromString(@"AWEUserSheetAction")
                    actionWithTitle:actionTitle
                            imgName:nil
                            handler:^{
                              NSMutableArray *imageURLs = [NSMutableArray array];
                              NSMutableArray *livePhotos = [NSMutableArray array];

                              for (AWEImageAlbumImageModel *imageModel in awemeModel.albumImages) {
                                  if (imageModel.urlList.count > 0) {
                                      // 查找非.image后缀的URL
                                      NSURL *downloadURL = nil;
                                      for (NSString *urlString in imageModel.urlList) {
                                          NSURL *url = [NSURL URLWithString:urlString];
                                          NSString *pathExtension = [url.path.lowercaseString pathExtension];
                                          if (![pathExtension isEqualToString:@"image"]) {
                                              downloadURL = url;
                                              break;
                                          }
                                      }

                                      if (!downloadURL && imageModel.urlList.count > 0) {
                                          downloadURL = [NSURL URLWithString:imageModel.urlList.firstObject];
                                      }

                                      // 检查是否是实况照片
                                      if (imageModel.clipVideo != nil) {
                                          NSURL *videoURL = [imageModel.clipVideo.playURL getDYYYSrcURLDownload];
                                          [livePhotos addObject:@{@"imageURL" : downloadURL.absoluteString, @"videoURL" : videoURL.absoluteString}];
                                      } else {
                                          [imageURLs addObject:downloadURL.absoluteString];
                                      }
                                  }
                              }

                              // 分别处理普通图片和实况照片
                              if (livePhotos.count > 0) {
                                  [DYYYManager downloadAllLivePhotos:livePhotos];
                              }

                              if (imageURLs.count > 0) {
                                  [DYYYManager downloadAllImages:imageURLs];
                              }

                              if (livePhotos.count == 0 && imageURLs.count == 0) {
                                  [DYYYUtils showToast:@"没有找到合适格式的图片"];
                              }
                            }];
                [actions addObject:downloadAllAction];
            }
        }

        // 添加下载音频选项
        if (DYYYGetBool(@"DYYYDoubleTapDownloadAudio") || ![[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYDoubleTapDownloadAudio"]) {

            AWEUserSheetAction *downloadAudioAction = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:@"保存音频"
                                                                                                        imgName:nil
                                                                                                        handler:^{
                                                                                                          if (musicModel && musicModel.playURL && musicModel.playURL.originURLList.count > 0) {
                                                                                                              NSURL *url = [NSURL URLWithString:musicModel.playURL.originURLList.firstObject];
                                                                                                              [DYYYManager downloadMedia:url mediaType:MediaTypeAudio audio:nil completion:nil];
                                                                                                          }
                                                                                                        }];
            [actions addObject:downloadAudioAction];
        }

        // 添加接口保存选项
        if (DYYYGetBool(@"DYYYDoubleInterfaceDownload")) {
            NSString *apiKey = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYInterfaceDownload"];
            if (apiKey.length > 0) {
                AWEUserSheetAction *apiDownloadAction = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:@"接口保存"
                                                                                                          imgName:nil
                                                                                                          handler:^{
                                                                                                            NSString *shareLink = [awemeModel valueForKey:@"shareURL"];
                                                                                                            if (shareLink.length == 0) {
                                                                                                                [DYYYUtils showToast:@"无法获取分享链接"];
                                                                                                                return;
                                                                                                            }

                                                                                                            // 使用封装的方法进行解析下载
                                                                                                            [DYYYManager parseAndDownloadVideoWithShareLink:shareLink apiKey:apiKey awemeModel:awemeModel];
                                                                                                          }];
                [actions addObject:apiDownloadAction];
            }
        }

        // 添加制作视频功能
        if (DYYYGetBool(@"DYYYDoubleCreateVideo") || ![[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYDoubleCreateVideo"]) {
            if (isImageContent) {
                AWEUserSheetAction *createVideoAction = [NSClassFromString(@"AWEUserSheetAction")
                    actionWithTitle:@"制作视频"
                            imgName:nil
                            handler:^{
                              // 收集普通图片URL
                              NSMutableArray *imageURLs = [NSMutableArray array];
                              // 收集实况照片信息（图片URL+视频URL）
                              NSMutableArray *livePhotos = [NSMutableArray array];

                              // 获取背景音乐URL
                              NSString *bgmURL = nil;
                              if (musicModel && musicModel.playURL && musicModel.playURL.originURLList.count > 0) {
                                  bgmURL = musicModel.playURL.originURLList.firstObject;
                              }

                              // 处理所有图片和实况
                              for (AWEImageAlbumImageModel *imageModel in awemeModel.albumImages) {
                                  if (imageModel.urlList.count > 0) {
                                      // 查找非.image后缀的URL
                                      NSString *bestURL = nil;
                                      for (NSString *urlString in imageModel.urlList) {
                                          NSURL *url = [NSURL URLWithString:urlString];
                                          NSString *pathExtension = [url.path.lowercaseString pathExtension];
                                          if (![pathExtension isEqualToString:@"image"]) {
                                              bestURL = urlString;
                                              break;
                                          }
                                      }

                                      if (!bestURL && imageModel.urlList.count > 0) {
                                          bestURL = imageModel.urlList.firstObject;
                                      }

                                      // 如果是实况照片，需要收集图片和视频URL
                                      if (imageModel.clipVideo != nil) {
                                          NSURL *videoURL = [imageModel.clipVideo.playURL getDYYYSrcURLDownload];
                                          if (videoURL) {
                                              [livePhotos addObject:@{@"imageURL" : bestURL, @"videoURL" : videoURL.absoluteString}];
                                          }
                                      } else {
                                          // 普通图片
                                          [imageURLs addObject:bestURL];
                                      }
                                  }
                              }

                              // 调用视频创建API
                              [DYYYManager createVideoFromMedia:imageURLs
                                  livePhotos:livePhotos
                                  bgmURL:bgmURL
                                  progress:^(NSInteger current, NSInteger total, NSString *status) {
                                  }
                                  completion:^(BOOL success, NSString *message) {
                                    if (success) {
                                    } else {
                                        [DYYYUtils showToast:[NSString stringWithFormat:@"视频制作失败: %@", message]];
                                    }
                                  }];
                            }];
                [actions addObject:createVideoAction];
            }
        }

        // 添加复制文案选项
        if (DYYYGetBool(@"DYYYDoubleTapCopyDesc") || ![[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYDoubleTapCopyDesc"]) {

            AWEUserSheetAction *copyTextAction = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:@"复制文案"
                                                                                                   imgName:nil
                                                                                                   handler:^{
                                                                                                     NSString *descText = [awemeModel valueForKey:@"descriptionString"];
                                                                                                     [[UIPasteboard generalPasteboard] setString:descText];
                                                                                                     [DYYYToast showSuccessToastWithMessage:@"文案已复制"];
                                                                                                   }];
            [actions addObject:copyTextAction];
        }

        // 添加打开评论区选项
        if (DYYYGetBool(@"DYYYDoubleTapComment") || ![[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYDoubleTapComment"]) {

            AWEUserSheetAction *openCommentAction = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:@"打开评论"
                                                                                                      imgName:nil
                                                                                                      handler:^{
                                                                                                        [self performCommentAction];
                                                                                                      }];
            [actions addObject:openCommentAction];
        }

        // 添加分享选项
        if (DYYYGetBool(@"DYYYDoubleTapshowSharePanel") || ![[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYDoubleTapshowSharePanel"]) {

            AWEUserSheetAction *showSharePanel = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:@"分享视频"
                                                                                                   imgName:nil
                                                                                                   handler:^{
                                                                                                     [self showSharePanel];
                                                                                                   }];
            [actions addObject:showSharePanel];
        }

        // 添加点赞视频选项
        if (DYYYGetBool(@"DYYYDoubleTapLike") || ![[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYDoubleTapLike"]) {

            AWEUserSheetAction *likeAction = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:@"点赞视频"
                                                                                               imgName:nil
                                                                                               handler:^{
                                                                                                 [self performLikeAction];
                                                                                               }];
            [actions addObject:likeAction];
        }

        // 添加长按面板
        if (DYYYGetBool(@"DYYYDoubleTapshowDislikeOnVideo") || ![[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYDoubleTapshowDislikeOnVideo"]) {

            AWEUserSheetAction *showDislikeOnVideo = [NSClassFromString(@"AWEUserSheetAction") actionWithTitle:@"长按面板"
                                                                                                       imgName:nil
                                                                                                       handler:^{
                                                                                                         [self showDislikeOnVideo];
                                                                                                       }];
            [actions addObject:showDislikeOnVideo];
        }

        // 显示操作表
        [actionSheet setActions:actions];
        [actionSheet show];

        return;
    }

    // 默认行为
    %orig;
}

%end

%hook AFDPrivacyHalfScreenViewController

%new
- (void)updateDarkModeAppearance {
    BOOL isDarkMode = [DYYYUtils isDarkMode];

    UIView *contentView = self.view.subviews.count > 1 ? self.view.subviews[1] : nil;
    if (contentView) {
        if (isDarkMode) {
            contentView.backgroundColor = [UIColor colorWithRed:0.13 green:0.13 blue:0.13 alpha:1.0];
        } else {
            contentView.backgroundColor = [UIColor whiteColor];
        }
    }

    // 修改标题文本颜色
    if (self.titleLabel) {
        if (isDarkMode) {
            self.titleLabel.textColor = [UIColor whiteColor];
        } else {
            self.titleLabel.textColor = [UIColor blackColor];
        }
    }

    // 修改内容文本颜色
    if (self.contentLabel) {
        if (isDarkMode) {
            self.contentLabel.textColor = [UIColor lightGrayColor];
        } else {
            self.contentLabel.textColor = [UIColor darkGrayColor];
        }
    }

    // 修改左侧按钮颜色和文字颜色
    if (self.leftCancelButton) {
        if (isDarkMode) {
            [self.leftCancelButton setBackgroundColor:[UIColor colorWithRed:0.25 green:0.25 blue:0.25 alpha:1.0]]; // 暗色模式按钮背景色
            [self.leftCancelButton setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];          // 暗色模式文字颜色
        } else {
            [self.leftCancelButton setBackgroundColor:[UIColor colorWithRed:0.9 green:0.9 blue:0.9 alpha:1.0]]; // 默认按钮背景色
            [self.leftCancelButton setTitleColor:[UIColor darkTextColor] forState:UIControlStateNormal];        // 默认文字颜色
        }
    }
}

- (void)viewDidLoad {
    %orig;
    [self updateDarkModeAppearance];
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [self updateDarkModeAppearance];
}

- (void)configWithImageView:(UIImageView *)imageView
                  lockImage:(UIImage *)lockImage
           defaultLockState:(BOOL)defaultLockState
             titleLabelText:(NSString *)titleText
           contentLabelText:(NSString *)contentText
       leftCancelButtonText:(NSString *)leftButtonText
     rightConfirmButtonText:(NSString *)rightButtonText
       rightBtnClickedBlock:(void (^)(void))rightBtnBlock
     leftButtonClickedBlock:(void (^)(void))leftBtnBlock {

    %orig;
    [self updateDarkModeAppearance];
}

%end

%hook UITextField

- (void)willMoveToWindow:(UIWindow *)newWindow {
    %orig;

    if (newWindow) {
        BOOL isDarkMode = [DYYYUtils isDarkMode];
        self.keyboardAppearance = isDarkMode ? UIKeyboardAppearanceDark : UIKeyboardAppearanceLight;
    }
}

- (BOOL)becomeFirstResponder {
    BOOL isDarkMode = [DYYYUtils isDarkMode];
    self.keyboardAppearance = isDarkMode ? UIKeyboardAppearanceDark : UIKeyboardAppearanceLight;
    return %orig;
}

%end

%hook UITextView

- (void)willMoveToWindow:(UIWindow *)newWindow {
    %orig;

    if (newWindow) {
        BOOL isDarkMode = [DYYYUtils isDarkMode];
        self.keyboardAppearance = isDarkMode ? UIKeyboardAppearanceDark : UIKeyboardAppearanceLight;
    }
}

- (BOOL)becomeFirstResponder {
    BOOL isDarkMode = [DYYYUtils isDarkMode];
    self.keyboardAppearance = isDarkMode ? UIKeyboardAppearanceDark : UIKeyboardAppearanceLight;
    return %orig;
}

%end

// 底栏高度
%hook AWENormalModeTabBar

static Class barBackgroundClass = nil;
static Class generalButtonClass = nil;
static Class plusButtonClass = nil;
static Class tabBarButtonClass = nil;

+ (void)initialize {
    if (self == [%c(AWENormalModeTabBar) class]) {
        barBackgroundClass = NSClassFromString(@"_UIBarBackground");
        generalButtonClass = %c(AWENormalModeTabBarGeneralButton);
        plusButtonClass = %c(AWENormalModeTabBarGeneralPlusButton);
        tabBarButtonClass = %c(UITabBarButton);
    }
}

%new
- (void)initializeOriginalTabBarHeight {
    if (originalTabBarHeight != kInvalidHeight) {
        if (gCurrentTabBarHeight == kInvalidHeight) {
            gCurrentTabBarHeight = originalTabBarHeight;
        }
        NSLog(@"[DYYY] initializeOriginalTabBarHeight: Skipped! originalTabBarHeight already initialized as %.1f.", originalTabBarHeight);
        return;
    }

    UIWindow *targetWindow = self.window ?: [DYYYUtils getActiveWindow];
    if (self.frame.size.height >= 30) {
        originalTabBarHeight = self.frame.size.height;
        NSLog(@"[DYYY] initializeOriginalTabBarHeight: Success! originalTabBarHeight set to %.1f (from self.frame.size.height)", originalTabBarHeight);
    } else if (targetWindow) {
        CGFloat bottomInset = targetWindow.safeAreaInsets.bottom;
        originalTabBarHeight = 49 + bottomInset;
        NSLog(@"[DYYY] initializeOriginalTabBarHeight: Success! originalTabBarHeight set to %.1f (fallback calculation: 49.0 + %.1f)", originalTabBarHeight, bottomInset);
    } else {
        NSLog(@"[DYYY] initializeOriginalTabBarHeight: Failed! No window available.");
    }
    if (originalTabBarHeight != kInvalidHeight) {
        gCurrentTabBarHeight = originalTabBarHeight;
        NSLog(@"[DYYY] initializeOriginalTabBarHeight: gCurrentTabBarHeight synced to %.1f.", gCurrentTabBarHeight);
    }
}

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        [self initializeOriginalTabBarHeight];
    }
}

- (void)layoutSubviews {
    %orig;

    if (originalTabBarHeight == kInvalidHeight) {
        NSLog(@"[DYYY] layoutSubviews: Fallback! originalTabBarHeight initialization triggered.");
        [self initializeOriginalTabBarHeight];
    }

    if (gCurrentTabBarHeight == kInvalidHeight) {
        gCurrentTabBarHeight = originalTabBarHeight;
        NSLog(@"[DYYY] layoutSubviews: gCurrentTabBarHeight fallback synced to %.1f.", gCurrentTabBarHeight);
    }

    BOOL hideShop = DYYYGetBool(@"DYYYHideShopButton");
    BOOL hideMsg = DYYYGetBool(@"DYYYHideMessageButton");
    BOOL hideFri = DYYYGetBool(@"DYYYHideFriendsButton");
    BOOL hideMe = DYYYGetBool(@"DYYYHideMyButton");
    BOOL isPad = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad);

    NSMutableArray *visibleButtons = [NSMutableArray array];
    UIView *ipadContainerView = nil;

    for (UIView *subview in self.subviews) {
        if ([subview isKindOfClass:generalButtonClass] || [subview isKindOfClass:plusButtonClass]) {
            NSString *label = subview.accessibilityLabel;
            BOOL shouldHide = ([label containsString:@"商城"] && hideShop) || ([label containsString:@"消息"] && hideMsg) || ([label containsString:@"朋友"] && hideFri) ||
                              ([label isEqualToString:@"我"] && hideMe);

            subview.userInteractionEnabled = !shouldHide;
            subview.hidden = shouldHide;

            if (!shouldHide) {
                [visibleButtons addObject:subview];
            }
        } else if ([subview isKindOfClass:tabBarButtonClass]) {
            subview.userInteractionEnabled = NO;
            subview.hidden = YES;
        } else if (isPad && !ipadContainerView && [subview isMemberOfClass:UIView.class] && fabs(subview.frame.size.width - self.bounds.size.width) > 0.1) {
            ipadContainerView = subview;
        }
    }

    [visibleButtons sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
      return [@(a.frame.origin.x) compare:@(b.frame.origin.x)];
    }];

    CGFloat offsetX, totalWidth;
    if (ipadContainerView) {
        offsetX = ipadContainerView.frame.origin.x;
        totalWidth = ipadContainerView.bounds.size.width;
    } else {
        offsetX = 0;
        totalWidth = self.bounds.size.width;
    }
    CGFloat buttonWidth = (visibleButtons.count > 0) ? (totalWidth / visibleButtons.count) : 0;

    // 均匀布局按钮（2.2-9-11 修复底栏中间拥挤）：
    // 实测截图里底栏 5 项中心点（归一化）约为 首页129、朋友369、+500、消息625、我871，
    // 中间两档间距仅 131/125，远小于两边 240/246，中间三项明显挤向中央。
    // 原代码只均分 General/Plus 按钮帧，抖音后续布局或非 General 类的 Tab 项
    // （如朋友头像项）会把内容中心又拉回中央，导致均分失效。
    // 改为：把所有 Tab 项（含其他 UIButton 类、以及 accessibilityLabel 为 首页/朋友/消息/我/商城的项）
    // 都纳入均分，并用中心点 (i+0.5)*buttonWidth 强制对齐，布局后再异步重申一次，
    // 防止抖音后续布局把中间项又拉回中央。隐藏按钮时仍按剩余项均分，不影响其他功能。
    for (UIView *subview in self.subviews) {
        if ([visibleButtons containsObject:subview]) {
            continue;
        }
        NSString *lbl = subview.accessibilityLabel ?: @"";
        BOOL isTabItem = ([subview isKindOfClass:[UIButton class]] ||
                          [lbl isEqualToString:@"首页"] || [lbl containsString:@"朋友"] ||
                          [lbl isEqualToString:@"消息"] || [lbl isEqualToString:@"我"] ||
                          [lbl containsString:@"商城"]);
        if (isTabItem && !subview.hidden && subview.frame.size.width > 20 && subview.frame.size.height > 20) {
            // 与上面隐藏逻辑一致：被隐藏开关藏起的项不纳入
            BOOL shouldHideExtra = ([lbl containsString:@"商城"] && hideShop) || ([lbl containsString:@"消息"] && hideMsg) ||
                                   ([lbl containsString:@"朋友"] && hideFri) || ([lbl isEqualToString:@"我"] && hideMe);
            if (!shouldHideExtra) {
                [visibleButtons addObject:subview];
            }
        }
    }
    [visibleButtons sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
      return [@(a.frame.origin.x) compare:@(b.frame.origin.x)];
    }];
    if (visibleButtons.count > 0) {
        buttonWidth = totalWidth / visibleButtons.count;
    }
    for (NSInteger i = 0; i < visibleButtons.count; i++) {
        UIView *button = visibleButtons[i];
        CGRect f = button.frame;
        f.origin.x = offsetX + i * buttonWidth;
        f.size.width = buttonWidth;
        button.frame = f;
        button.center = CGPointMake(offsetX + (i + 0.5) * buttonWidth, button.center.y);
    }
    // 异步再申一次，防止抖音后续布局覆盖均分结果
    {
        NSArray *buttonsCopy = [visibleButtons copy];
        CGFloat finalOffsetX = offsetX;
        CGFloat finalButtonWidth = buttonWidth;
        dispatch_async(dispatch_get_main_queue(), ^{
          for (NSInteger i = 0; i < buttonsCopy.count; i++) {
              UIView *button = buttonsCopy[i];
              if (!button.window) {
                  continue;
              }
              CGRect f = button.frame;
              f.origin.x = finalOffsetX + i * finalButtonWidth;
              f.size.width = finalButtonWidth;
              button.frame = f;
              button.center = CGPointMake(finalOffsetX + (i + 0.5) * finalButtonWidth, button.center.y);
          }
        });
    }

    // 禁用首页刷新功能
    if (DYYYGetBool(@"DYYYDisableHomeRefresh")) {
        for (UIView *subview in self.subviews) {
            if ([subview isKindOfClass:generalButtonClass]) {
                AWENormalModeTabBarGeneralButton *button = (AWENormalModeTabBarGeneralButton *)subview;
                if ([button.accessibilityLabel isEqualToString:@"首页"]) {
                    // status == 2 表示选中状态
                    button.userInteractionEnabled = (button.status != 2);
                }
            }
        }
    }

    // 背景和分隔线处理
    BOOL hideBottomBg = DYYYGetBool(@"DYYYHideBottomBg");
    BOOL enableFullScreen = DYYYGetBool(@"DYYYEnableFullScreen");

    if (hideBottomBg || enableFullScreen) {
        if (self.skinContainerView) {
            self.skinContainerView.hidden = YES;
        }

        BOOL isHomeSelected = NO;
        BOOL isFriendsSelected = NO;

        if (enableFullScreen && !hideBottomBg) {
            for (UIView *subview in self.subviews) {
                if ([subview isKindOfClass:generalButtonClass]) {
                    AWENormalModeTabBarGeneralButton *button = (AWENormalModeTabBarGeneralButton *)subview;
                    if (button.status == 2) {
                        if ([button.accessibilityLabel isEqualToString:@"首页"])
                            isHomeSelected = YES;
                        else if ([button.accessibilityLabel containsString:@"朋友"])
                            isFriendsSelected = YES;
                    }
                }
            }
        }

        BOOL hideFriendsButton = DYYYGetBool(@"DYYYHideFriendsButton");
        BOOL shouldHideBackgrounds = hideBottomBg || (enableFullScreen && (isHomeSelected || (isFriendsSelected && !hideFriendsButton)));

        // 单次遍历处理所有背景和分割线
        for (UIView *subview in self.subviews) {
            // 跳过底栏按钮
            if ([subview isKindOfClass:generalButtonClass] || [subview isKindOfClass:plusButtonClass]) {
                continue;
            }
            // 隐藏底栏背景
            if ([subview isKindOfClass:barBackgroundClass] || ([subview isMemberOfClass:[UIView class]] && originalTabBarHeight > 0 && fabs(subview.frame.size.height - gCurrentTabBarHeight) < 0.1)) {
                subview.hidden = shouldHideBackgrounds;
            }
            // 隐藏细分割线
            // 2.2-9-22 放宽：@3x 下分隔线可能 2~3pt，之前 <1pt 会漏，全屏开时藏掉细满宽分隔线
            if (subview.frame.size.height > 0 && subview.frame.size.height <= 6 && subview.frame.size.width >= 250) {
                subview.hidden = enableFullScreen;
            }
        }
    } else {
        if (self.skinContainerView) {
            self.skinContainerView.hidden = NO;
        }

        for (UIView *subview in self.subviews) {
            if ([subview isKindOfClass:barBackgroundClass] || [subview isMemberOfClass:[UIView class]]) {
                subview.hidden = NO;
            }
        }
    }
}

- (void)setHidden:(BOOL)hidden {
    %orig(hidden);

    BOOL disableHomeRefresh = DYYYGetBool(@"DYYYDisableHomeRefresh");
    BOOL enableFullScreen = DYYYGetBool(@"DYYYEnableFullScreen");
    BOOL hideBottomBg = DYYYGetBool(@"DYYYHideBottomBg");
    BOOL hideFriendsButton = DYYYGetBool(@"DYYYHideFriendsButton");

    BOOL isHomeSelected = NO;
    BOOL isFriendsSelected = NO;

    for (UIView *subview in self.subviews) {
        if ([subview isKindOfClass:generalButtonClass]) {
            AWENormalModeTabBarGeneralButton *button = (AWENormalModeTabBarGeneralButton *)subview;

            // 禁用首页刷新功能
            if (disableHomeRefresh && [button.accessibilityLabel isEqualToString:@"首页"]) {
                button.userInteractionEnabled = (button.status != 2);
            }

            // 检查当前选中的页
            if (enableFullScreen && button.status == 2) {
                if ([button.accessibilityLabel isEqualToString:@"首页"]) {
                    isHomeSelected = YES;
                } else if ([button.accessibilityLabel containsString:@"朋友"]) {
                    isFriendsSelected = YES;
                }
            }
        }
    }

    if (hideBottomBg || enableFullScreen) {
        if (self.skinContainerView) {
            self.skinContainerView.hidden = YES;
        }

        BOOL shouldHideBackgrounds = NO;
        if (hideBottomBg) {
            shouldHideBackgrounds = YES;
        } else if (enableFullScreen) {
            shouldHideBackgrounds = isHomeSelected || (isFriendsSelected && !hideFriendsButton);
        }

        // 处理所有背景和分割线
        for (UIView *subview in self.subviews) {
            CGFloat subviewHeight = subview.frame.size.height;
            // 跳过底栏按钮
            if ([subview isKindOfClass:generalButtonClass] || [subview isKindOfClass:plusButtonClass]) {
                continue;
            }
            // 隐藏底栏背景
            if ([subview isKindOfClass:barBackgroundClass] || ([subview isMemberOfClass:[UIView class]] && originalTabBarHeight > 0 && fabs(subviewHeight - gCurrentTabBarHeight) < 0.1)) {
                subview.hidden = shouldHideBackgrounds;
            }
            // 2.2-9-22 放宽同上
            if (subviewHeight > 0 && subviewHeight <= 6 && subview.frame.size.width >= 250) {
                subview.hidden = enableFullScreen;
            }
        }
    } else {
        if (self.skinContainerView) {
            self.skinContainerView.hidden = NO;
        }
        for (UIView *subview in self.subviews) {
            if ([subview isKindOfClass:barBackgroundClass] || [subview isMemberOfClass:[UIView class]]) {
                subview.hidden = NO;
            }
        }
    }
}

%end

// 精简平板底栏
%hook AWETabBarElementContainerView

- (void)setHidden:(BOOL)hidden {
    if (DYYYGetBool(@"DYYYHidePadTabBarElements")) {
        %orig(YES);
        return;
    }

    %orig(hidden);
}

%end

%hook AWENormalModeTabBarBadgeContainerView

- (void)layoutSubviews {
    %orig;
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideBottomDot"]) {
        return;
    }

    static char kDYBadgeCacheKey;
    NSArray *badges = objc_getAssociatedObject(self, &kDYBadgeCacheKey);
    if (!badges) {
        NSMutableArray *tmp = [NSMutableArray array];
        for (UIView *subview in [self subviews]) {
            if ([subview isKindOfClass:NSClassFromString(@"DUXBadge")]) {
                [tmp addObject:subview];
            }
        }
        badges = [tmp copy];
        objc_setAssociatedObject(self, &kDYBadgeCacheKey, badges, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    for (UIView *badge in badges) {
        badge.hidden = YES;
    }
}

%end

// 禁用点击首页刷新
%hook AWENormalModeTabBarGeneralButton

- (BOOL)enableRefresh {
    if ([self.accessibilityLabel isEqualToString:@"首页"]) {
        if (DYYYGetBool(@"DYYYDisableHomeRefresh")) {
            return NO;
        }
    }
    return %orig;
}

%end

%hook AWENormalModeTabBarGeneralPlusButton
+ (id)button {
    BOOL isHidePlusButton = DYYYGetBool(@"DYYYHidePlusButton");
    if (isHidePlusButton) {
        return nil;
    }
    return %orig;
}
%end

%hook AWENormalModeTabBarGeneralPlusInnerButton
+ (id)buttonWithParams:(id)arg1 {
    if (DYYYGetBool(@"DYYYHidePlusButton")) {
        return nil;
    }
    return %orig;
}
%end

%hook AWENormalModeTabBarTextView

- (void)layoutSubviews {
    @try {
        %orig;

        if (![NSThread isMainThread]) {
            dispatch_async(dispatch_get_main_queue(), ^{
              [self layoutSubviews];
            });
            return;
        }

        if (!self || !self.superview) {
            return;
        }

        NSString *indexTitle = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYIndexTitle"];
        NSString *friendsTitle = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYFriendsTitle"];
        NSString *msgTitle = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYMsgTitle"];
        NSString *selfTitle = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYSelfTitle"];

        if (!(indexTitle.length || friendsTitle.length || msgTitle.length || selfTitle.length)) {
            return;
        }

        static char kDYTabTextLabelCacheKey;
        NSArray *labelCache = objc_getAssociatedObject(self, &kDYTabTextLabelCacheKey);
        if (!labelCache) {
            NSMutableArray *tmp = [NSMutableArray array];
            if (!tmp) {
                return;
            }

            NSArray *subviews = [self subviews];
            if (!subviews) {
                return;
            }

            for (UIView *subview in subviews) {
                if (subview && [subview isKindOfClass:[UILabel class]]) {
                    [tmp addObject:subview];
                }
            }

            labelCache = [tmp copy];
            if (labelCache) {
                objc_setAssociatedObject(self, &kDYTabTextLabelCacheKey, labelCache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }

        if (!labelCache) {
            return;
        }

        for (UILabel *label in labelCache) {
            if (!label || ![label isKindOfClass:[UILabel class]]) {
                continue;
            }

            NSString *labelText = label.text;
            if (!labelText) {
                continue;
            }

            if ([labelText isEqualToString:@"首页"] && indexTitle.length > 0) {
                label.text = indexTitle;
                dispatch_async(dispatch_get_main_queue(), ^{
                  [self setNeedsLayout];
                });
            } else if ([labelText isEqualToString:@"朋友"] && friendsTitle.length > 0) {
                label.text = friendsTitle;
                dispatch_async(dispatch_get_main_queue(), ^{
                  [self setNeedsLayout];
                });
            } else if ([labelText isEqualToString:@"消息"] && msgTitle.length > 0) {
                label.text = msgTitle;
                dispatch_async(dispatch_get_main_queue(), ^{
                  [self setNeedsLayout];
                });
            } else if ([labelText isEqualToString:@"我"] && selfTitle.length > 0) {
                label.text = selfTitle;
                dispatch_async(dispatch_get_main_queue(), ^{
                  [self setNeedsLayout];
                });
            }
        }

    } @catch (NSException *exception) {
        return;
    }
}
%end

%hook AWENormalModeTabBarFeedView

- (void)layoutSubviews {
    @try {
        %orig;
        if (![[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideDoubleColumnEntry"]) {
            return;
        }

        static char kDYDoubleColumnCacheKey;
        static char kDYDoubleColumnCountKey;
        NSArray *cachedViews = objc_getAssociatedObject(self, &kDYDoubleColumnCacheKey);
        NSNumber *cachedCount = objc_getAssociatedObject(self, &kDYDoubleColumnCountKey);
        if (!cachedViews || cachedCount.unsignedIntegerValue != self.subviews.count) {
            NSMutableArray *views = [NSMutableArray array];
            for (UIView *subview in self.subviews) {
                if (![subview isKindOfClass:[UILabel class]]) {
                    [views addObject:subview];
                }
            }
            cachedViews = [views copy];
            objc_setAssociatedObject(self, &kDYDoubleColumnCacheKey, cachedViews, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, &kDYDoubleColumnCountKey, @(self.subviews.count), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        for (UIView *v in cachedViews) {
            v.hidden = YES;
        }

        if (![NSThread isMainThread]) {
            dispatch_async(dispatch_get_main_queue(), ^{
              [self layoutSubviews];
            });
            return;
        }

        if (!self || !self.superview) {
            return;
        }

        NSString *indexTitle = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYIndexTitle"];

        if (!(indexTitle.length)) {
            return;
        }

        static char kDYTabFeedLabelCacheKey;
        NSArray *labelCache = objc_getAssociatedObject(self, &kDYTabFeedLabelCacheKey);
        if (!labelCache) {
            NSMutableArray *tmp = [NSMutableArray array];
            if (!tmp) {
                return;
            }

            NSArray *subviews = [self subviews];
            if (!subviews) {
                return;
            }

            for (UIView *subview in subviews) {
                if (subview && [subview isKindOfClass:[UILabel class]]) {
                    [tmp addObject:subview];
                }
            }

            labelCache = [tmp copy];
            if (labelCache) {
                objc_setAssociatedObject(self, &kDYTabFeedLabelCacheKey, labelCache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }

        if (!labelCache) {
            return;
        }

        for (UILabel *label in labelCache) {
            if (!label || ![label isKindOfClass:[UILabel class]]) {
                continue;
            }

            NSString *labelText = label.text;
            if (!labelText) {
                continue;
            }

            if ([labelText isEqualToString:@"首页"] && indexTitle.length > 0) {
                label.text = indexTitle;
                dispatch_async(dispatch_get_main_queue(), ^{
                  [self setNeedsLayout];
                });
            }
        }

    } @catch (NSException *exception) {
        return;
    }
}
%end

%hook AWEConcernCellLastView
- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYEnableFullScreen") && gCurrentTabBarHeight > 0) {
        for (UIView *subview in self.subviews) {
            CGRect frame = subview.frame;
            frame.origin.y -= gCurrentTabBarHeight;
            subview.frame = frame;
        }
    }
}
%end

%hook AWECommentInputBackgroundView
- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYHideComment")) {
        [self removeFromSuperview];
        return;
    }

    CGAffineTransform newTransform = CGAffineTransformMakeTranslation(0, originalTabBarHeight - gCurrentTabBarHeight);

    if (!CGAffineTransformEqualToTransform(self.transform, newTransform)) {
        self.transform = newTransform;
    }
}
%end

%hook AWECommentContainerViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    dyyyCommentViewVisible = YES;
    updateSpeedButtonVisibility();
    updateClearButtonVisibility();
    NSString *transparentValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYTopBarTransparent"];
    if (transparentValue && transparentValue.length > 0) {
        CGFloat alphaValue = [transparentValue floatValue];
        if (alphaValue >= 0.0 && alphaValue <= 1.0) {

            UIView *parentView = self.view.superview;
            if (parentView) {
                for (UIView *subview in parentView.subviews) {
                    if ([subview.accessibilityLabel isEqualToString:@"搜索"]) {
                        CGFloat finalAlpha = (alphaValue < 0.011) ? 0.011 : alphaValue;
                        subview.alpha = finalAlpha;
                    }
                }
            }
        }
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    dyyyCommentViewVisible = NO;
    updateSpeedButtonVisibility();
    updateClearButtonVisibility();
}

- (void)viewDidLayoutSubviews {
    %orig;

    if (!DYYYGetBool(@"DYYYEnableCommentBlur"))
        return;

    Class containerViewClass = NSClassFromString(@"AWECommentInputViewSwiftImpl.CommentInputContainerView");
    NSArray<UIView *> *containerViews = [DYYYUtils findAllSubviewsOfClass:containerViewClass inContainer:self.view];
    for (UIView *containerView in containerViews) {
        for (UIView *subview in containerView.subviews) {
            if (subview.hidden == NO && subview.backgroundColor && CGColorGetAlpha(subview.backgroundColor.CGColor) == 1) {
                float userTransparency = [[[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYCommentBlurTransparent"] floatValue];
                if (userTransparency <= 0 || userTransparency > 1) {
                    userTransparency = 0.8;
                }
                [DYYYUtils applyBlurEffectToView:subview transparency:userTransparency blurViewTag:999];
            }
        }
    }

    Class middleContainerClass = NSClassFromString(@"AWECommentInputViewSwiftImpl.CommentInputViewMiddleContainer");
    NSArray<UIView *> *middleContainers = [DYYYUtils findAllSubviewsOfClass:middleContainerClass inContainer:self.view];
    for (UIView *middleContainer in middleContainers) {
        BOOL containsDanmu = NO;
        for (UIView *innerSubviewCheck in middleContainer.subviews) {
            if ([innerSubviewCheck isKindOfClass:[UILabel class]] && [((UILabel *)innerSubviewCheck).text containsString:@"弹幕"]) {
                containsDanmu = YES;
                break;
            }
        }

        if (containsDanmu) {
            UIView *parentView = middleContainer.superview;
            for (UIView *innerSubview in parentView.subviews) {
                if ([innerSubview isKindOfClass:[UIView class]]) {
                    if (innerSubview.subviews.count > 0) {
                        innerSubview.subviews[0].hidden = YES;
                    }

                    UIView *whiteBackgroundView = [[UIView alloc] initWithFrame:innerSubview.bounds];
                    whiteBackgroundView.backgroundColor = [UIColor whiteColor];
                    whiteBackgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                    [innerSubview addSubview:whiteBackgroundView];
                    break;
                }
            }
        } else {
            for (UIView *subview in middleContainer.subviews) {
                if (subview.hidden == NO && subview.backgroundColor && CGColorGetAlpha(subview.backgroundColor.CGColor) == 1) {
                    [DYYYUtils applyBlurEffectToView:subview transparency:0.2f blurViewTag:999];
                }
            }
        }
    }
}

%end

// 开启评论区毛玻璃后滚动区域填满底部
%hook AWEListKitMagicCollectionView

- (void)layoutSubviews {
    %orig;

    if (!DYYYGetBool(@"DYYYEnableCommentBlur")) {
        return;
    }

    UICollectionView *collectionView = (UICollectionView *)self;

    UIView *superview = collectionView.superview;
    CGRect targetFrame = superview.bounds;
    if (superview == nil || CGSizeEqualToSize(targetFrame.size, CGSizeZero) || CGRectEqualToRect(collectionView.frame, targetFrame)) {
        return;
    }

    collectionView.frame = targetFrame;

    CGFloat commentOffset = 166.0;

    UIEdgeInsets inset = collectionView.contentInset;
    inset.bottom = commentOffset;
    collectionView.contentInset = inset;
    collectionView.scrollIndicatorInsets = inset;
}

%end

%hook UIView

- (id)initWithFrame:(CGRect)frame {
    UIView *view = %orig;
    if (hideButton && hideButton.isElementsHidden) {
        for (NSString *className in targetClassNames) {
            if ([view isKindOfClass:NSClassFromString(className)]) {
                if ([view isKindOfClass:NSClassFromString(@"AWELeftSideBarEntranceView")]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                      UIViewController *controller = [hideButton findViewController:view];
                      if ([controller isKindOfClass:NSClassFromString(@"AWEFeedContainerViewController")]) {
                          view.alpha = 0.0;
                      }
                    });
                    break;
                }
                view.alpha = 0.0;
                break;
            }
        }
    }
    return view;
}

- (void)setBackgroundColor:(UIColor *)backgroundColor {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self setBackgroundColor:backgroundColor];
        });
        return;
    }

    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        UIViewController *vc = [DYYYUtils firstAvailableViewControllerFromView:self];
        if ([vc isKindOfClass:%c(AWEAwemeDetailTableViewController)] ||
            [vc isKindOfClass:%c(AWEAwemeDetailCellViewController)]) {
            %orig([UIColor clearColor]);
            return;
        }
    }

    %orig(backgroundColor);
}

- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        if (self.frame.size.height == originalTabBarHeight && originalTabBarHeight > 0) {
            UIViewController *vc = [DYYYUtils firstAvailableViewControllerFromView:self];
            if ([vc isKindOfClass:NSClassFromString(@"AWEMixVideoPanelDetailTableViewController")] || [vc isKindOfClass:NSClassFromString(@"AWECommentInputViewController")] ||
                [vc isKindOfClass:NSClassFromString(@"AWEAwemeDetailTableViewController")]) {
                self.backgroundColor = [UIColor clearColor];
            }
        }
    }

    if (DYYYGetBool(@"DYYYEnableFullScreen") || DYYYGetBool(@"DYYYEnableCommentBlur")) {
        UIViewController *vc = [DYYYUtils firstAvailableViewControllerFromView:self];
        if ([vc isKindOfClass:%c(AWEPlayInteractionViewController)]) {
            for (UIView *subview in self.subviews) {
                if ([subview isKindOfClass:[UIView class]] && subview.backgroundColor && CGColorEqualToColor(subview.backgroundColor.CGColor, [UIColor blackColor].CGColor)) {
                    subview.hidden = YES;
                }
            }
        }
    }
}

- (void)setFrame:(CGRect)frame {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self setFrame:frame];
        });
        return;
    }

    BOOL enableBlur = DYYYGetBool(@"DYYYEnableCommentBlur");
    BOOL enableFS = DYYYGetBool(@"DYYYEnableFullScreen");

    UIViewController *vc = [DYYYUtils firstAvailableViewControllerFromView:self];
    Class DetailVCClass = NSClassFromString(@"AWEMixVideoPanelDetailTableViewController");
    Class PlayVCClass1 = NSClassFromString(@"AWEAwemePlayVideoViewController");
    Class PlayVCClass2 = NSClassFromString(@"AWEDPlayerFeedPlayerViewController");
    Class PlayVCClass3 = NSClassFromString(@"AWEDPlayerViewController_Merge");

    BOOL isDetailVC = (DetailVCClass && [vc isKindOfClass:DetailVCClass]);
    BOOL isPlayVC = ((PlayVCClass1 && [vc isKindOfClass:PlayVCClass1]) ||
                     (PlayVCClass2 && [vc isKindOfClass:PlayVCClass2]) ||
                     (PlayVCClass3 && [vc isKindOfClass:PlayVCClass3]));

    // 2.2-9-31 回滚 -25 至 -30 的直播间进入跳过：连续 6 版跳过都没修好，反而把行高留成原生随比例变，分截一会多一会少；且博主在直播时，头像徽章已在上面被正确区分为非直播预览，普通视频应走正常全屏。直播间进入的详情页布局与普通详情页相同（顶搜索+底评论），正常钉位+拉高对普通详情有效，对它也应有效，不再按导航栈里有没有 Live 就跳过，避免把直播作者的普通视频误判成直播间。

    if (isPlayVC && enableBlur) {
        if (frame.origin.x != 0) {
            return;
        }
    }

    // 2.2-9-18 DYKiller 视频全屏核心移植（用户 2026-11-02 批准，替换 DYYY 首页全屏的视频容器部分）：
    // DYYY 老逻辑只在“ superview 高 - frame 高 == 底栏高（误差 1pt 内）”时才拉满，
    // 底栏高度量错一点（安全区、底栏间距改动、不同页）就拉不满，这就是首页全屏出 bug 的根源。
    // DYKiller 的做法不依赖底栏高度：只对 Merge 视频容器（AWEDPlayerViewController_Merge）
    // 直接钉到父视图满幅，比例达标（高/宽 >= 1.70 的竖屏）时再钉到 Cell 满高（盖满物理屏幕），
    // 图文（awemeType 68）、横屏、已点过全屏观看的横屏态、非主窗口（画中画等）一律放行。
    // 作用范围只限 Merge 容器，其他 PlayVC、详情页、评论模糊等老逻辑一律不动，
    // 开关仍复用“启用首页全屏”（DYYYEnableFullScreen），关掉即回到抖音默认。
    // 2.2-9-20 回归修复（用户 2026-11-02 17:16：-18/-19 后直播文字跑到中间，-8 时是正常的）：
    // 直播预览有自己一套 4 层容器 + IESLiveStackView 位移（-8 修过的 -20 逻辑），Merge 钉位会把它的
    // 容器高度改掉，导致底部文案的基准位置跟着错，文案就上移到中间。直播预览一律排除在新钉位之外，
    // 回落到下面的 DYYY 老逻辑（-8 确认正常的那套），普通视频仍走新钉位。
    BOOL isLivePreviewForFullscreen = NO;
    {
        // 2.2-9-21 修正 -20 的排除漏检：直播 HUD 与视频容器是同 Cell 内的同胞，不是祖先，
        // 只查响应链和祖先链查不到。改查同 Cell：先找到 UITableViewCellContentView 祖先，
        // 再遍历它的子树找直播标记，找到即本 Cell 是直播预览。-42 起不再缓存（见下），现算。
        UIView *cellContent = nil;
        UIView *anc0 = self.superview;
        Class contentCls0 = NSClassFromString(@"UITableViewCellContentView");
        Class contentCls1 = NSClassFromString(@"UICollectionViewCellContentView");
        for (NSInteger i = 0; anc0 && i < 12; i++, anc0 = anc0.superview) {
            if ((contentCls0 && [anc0 isKindOfClass:contentCls0]) || (contentCls1 && [anc0 isKindOfClass:contentCls1])) { cellContent = anc0; break; }
            NSString *cn = NSStringFromClass([anc0 class]);
            if ([cn containsString:@"Cell"] && [cn containsString:@"ContentView"]) { cellContent = anc0; break; }
        }
        if (cellContent) {
            // 2.2-9-42 直播缓存复用测试（用户 13:10 同意试）：-21 起给格子加的直播缓存，格子复用后旧记号
            // 还在，直播间格子复用到普通视频上就错误地跳过钉位，直播进主页就两节，普通从没直播格子就不受影响。
            // 现在删缓存，每次现算只认 4 层容器：真直播间仍排除、文案 -23 不受影响；复用格换了视频就重新算，
            // 不再带旧记号。普通格子现算也是否，和缓存否的结果一样，普通一字不动，只是每次多遍历一次子树。
            Class live4Cls = NSClassFromString(@"AWELivePreStream4LayerContainerView");
            NSMutableArray *queue = [NSMutableArray arrayWithObject:cellContent];
            NSInteger visited = 0;
            while (queue.count > 0 && visited < 1000 && !isLivePreviewForFullscreen) {
                UIView *node = queue[0];
                [queue removeObjectAtIndex:0];
                visited++;
                if (live4Cls && [node isKindOfClass:live4Cls]) {
                    isLivePreviewForFullscreen = YES;
                    break;
                }
                for (UIView *sub in node.subviews) {
                    [queue addObject:sub];
                }
            }
        }
        if (!isLivePreviewForFullscreen) {
            UIResponder *resp = self.nextResponder;
            Class livePreVCCls = NSClassFromString(@"AWELiveNewPreStreamViewController");
            for (NSInteger i = 0; resp && i < 20; i++, resp = resp.nextResponder) {
                if (livePreVCCls && [resp isKindOfClass:livePreVCCls]) { isLivePreviewForFullscreen = YES; break; }
            }
        }
    }
    if (isPlayVC && enableFS && PlayVCClass3 && [vc isKindOfClass:PlayVCClass3] && !isLivePreviewForFullscreen) {
        BOOL shouldPin = YES;
        // 非主窗口放行（画中画、横屏播放器等自带一整套层级，钉满会撑成全屏播放器）
        if (self.window && self.window.windowLevel != UIWindowLevelNormal) {
            shouldPin = NO;
        }
        // 比例与类型判据，全部用安全取值（huami 头文件里 Merge 没有 model 等声明，拿不到就按可拉满处理，
        // 与 DYKiller“宽高未知即达标”一致，避免因取不到属性就拉不满）
        if (shouldPin) {
            @try {
                id mergeModel = [vc valueForKey:@"model"];
                id mergeVideo = mergeModel ? [mergeModel valueForKey:@"video"] : nil;
                double vWidth = 0.0, vHeight = 0.0;
                if (mergeVideo) {
                    id wObj = [mergeVideo valueForKey:@"width"];
                    id hObj = [mergeVideo valueForKey:@"height"];
                    vWidth = [wObj doubleValue];
                    vHeight = [hObj doubleValue];
                }
                long long awemeType = -1;
                if (mergeModel) {
                    awemeType = [[mergeModel valueForKey:@"awemeType"] longLongValue];
                }
                BOOL isImage = (awemeType == 68);
                BOOL hasLandscape = NO;
                if ([vc respondsToSelector:@selector(hasInlandscape)]) {
                    hasLandscape = ((BOOL (*)(id, SEL))objc_msgSend)(vc, @selector(hasInlandscape));
                } else {
                    hasLandscape = [[vc valueForKey:@"hasInlandscape"] boolValue];
                }
                BOOL inLandscapeFeed = NO;
                if ([vc respondsToSelector:@selector(isInLandscapeFeedStatus)]) {
                    inLandscapeFeed = ((BOOL (*)(id, SEL))objc_msgSend)(vc, @selector(isInLandscapeFeedStatus));
                }
                if (isImage || hasLandscape || inLandscapeFeed) {
                    shouldPin = NO;
                } else if (vWidth > 0.0 && vHeight > 0.0 && (vHeight / vWidth) < 1.70) {
                    // 低比例竖屏与横屏不拉满，只钉父视图满幅（见下面 target 计算，不走 fullCell 分支）
                    // 这里不设 shouldPin=NO，而是用一个标记区分“只钉满幅”与“钉 Cell 满高”
                    // 为简单起见：低比例时仍钉父视图满幅，效果与 DYKiller 的“背景延伸到底栏”一致，
                    // 文案与进度条位置由 DYYY 老逻辑与其他钩子保持原位，不在此处动。
                    shouldPin = YES;
                }
            } @catch (__unused NSException *e) {
                shouldPin = YES;
            }
        }
        if (shouldPin && self.superview) {
            CGRect parentBounds = self.superview.bounds;
            CGFloat targetW = CGRectGetWidth(parentBounds);
            CGFloat targetH = CGRectGetHeight(parentBounds);
            // 2.2-9-34 过渡跳修复（用户 00:03：分截好多了，但过渡跳得难看）：推入/滑动动画中途，
            // 抖音正把容器从小缩略图/上一页帧动画到终态，之前 setFrame 一来就瞬间钉到终态，动画被打断成跳。
            // 现在帧还远没到终态（宽或高 < 终态 85%）时先原样放行，让抖音自己的动画滑过去；只有帧已接近
            // 终态时才小幅纠到终态，纠正量小，看起来就是自然落位，不是跳。
            if (targetW > 0.0 && targetH > 0.0 && (CGRectGetWidth(frame) < targetW * 0.85 || CGRectGetHeight(frame) < targetH * 0.85)) {
                %orig(frame);
                return;
            }
            if (targetW > 0.0 && targetH > 0.0) {
                // 比例达标时取 Cell 满高（沿 superview 往上找 UITableViewCellContentView，至多 12 层）
                BOOL aspectOK = YES;
                @try {
                    id mergeModel2 = [vc valueForKey:@"model"];
                    id mergeVideo2 = mergeModel2 ? [mergeModel2 valueForKey:@"video"] : nil;
                    double w2 = mergeVideo2 ? [[mergeVideo2 valueForKey:@"width"] doubleValue] : 0.0;
                    double h2 = mergeVideo2 ? [[mergeVideo2 valueForKey:@"height"] doubleValue] : 0.0;
                    if (w2 > 0.0 && h2 > 0.0 && (h2 / w2) < 1.70) {
                        aspectOK = NO;
                    }
                } @catch (__unused NSException *e) {
                    aspectOK = YES;
                }
                if (aspectOK) {
                    Class contentCls = NSClassFromString(@"UITableViewCellContentView");
                    UIView *ancestor = self.superview;
                    for (NSInteger i = 0; ancestor && i < 12; i++, ancestor = ancestor.superview) {
                        if (contentCls && [ancestor isKindOfClass:contentCls]) {
                            CGFloat fullH = CGRectGetHeight(ancestor.bounds);
                            if (fullH > targetH) {
                                targetH = fullH;
                            }
                            break;
                        }
                    }
                }
                CGRect target = CGRectMake(0.0, 0.0, targetW, targetH);
                // 已接近目标就放行，避免反复写入
                if (fabs(CGRectGetMinX(frame) - target.origin.x) <= 0.5 && fabs(CGRectGetMinY(frame) - target.origin.y) <= 0.5 &&
                    fabs(CGRectGetWidth(frame) - target.size.width) <= 0.5 && fabs(CGRectGetHeight(frame) - target.size.height) <= 0.5) {
                    %orig(frame);
                    return;
                }
                %orig(target);
                return;
            }
        }
        // 拿不到父视图或不应钉（图文/横屏/非主窗口）时，对 Merge 容器直接放行原帧，
        // 不再回落到 DYYY 老逻辑——老逻辑不看比例，图文/横屏也会被拉满，正是 bug 来源之一。
        // 非 Merge 的 PlayVC 仍走下面的老逻辑，保证之前正常的功能不受影响。
        if (PlayVCClass3 && [vc isKindOfClass:PlayVCClass3]) {
            %orig(frame);
            return;
        }
    }

    if (isPlayVC && enableFS) {
        if (frame.origin.x != 0 && frame.origin.y != 0) {
            %orig(frame);
            return;
        }
        CGRect superF = self.superview.frame;
        if (CGRectGetHeight(superF) > 0 && CGRectGetHeight(frame) > 0 && CGRectGetHeight(frame) < CGRectGetHeight(superF)) {
            CGFloat diff = CGRectGetHeight(superF) - CGRectGetHeight(frame);
            if (fabs(diff - gCurrentTabBarHeight) < 1.0) {
                frame.size.height = CGRectGetHeight(superF);
            }
        }

        %orig(frame);
        return;
    }
    %orig(frame);
}

%new
- (void)dyyy_applyGlobalTransparency {
    if ([NSThread isMainThread]) {
        if (self.window && self.tag != DYYY_IGNORE_GLOBAL_ALPHA_TAG) {
            NSNumber *stored = objc_getAssociatedObject(self, &kDYYYGlobalTransparencyBaseAlphaKey);
            CGFloat baseAlpha = stored ? stored.floatValue : self.alpha;
            if (!stored) {
                objc_setAssociatedObject(self, &kDYYYGlobalTransparencyBaseAlphaKey, @(baseAlpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            CGFloat finalAlpha = baseAlpha;
            if (gGlobalTransparency != kInvalidAlpha) {
                CGFloat clampedAlpha = MIN(MAX(baseAlpha, 0.0), 1.0);
                finalAlpha = clampedAlpha * gGlobalTransparency;
            }
            if (fabs(self.alpha - finalAlpha) >= 0.01) {
                [UIView animateWithDuration:0.2
                                 animations:^{
                                   dyyyGlobalTransparencyMutationDepth++;
                                   self.alpha = finalAlpha;
                                   if (dyyyGlobalTransparencyMutationDepth > 0) {
                                       dyyyGlobalTransparencyMutationDepth--;
                                   }
                                 }];
            }
        }
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self dyyy_applyGlobalTransparency];
        });
    }
}

// 2.2-9-24 黑线零闪现：-23 的进度更新藏线有效，但要等第一次进度 tick（约 1 秒），新视频头 1 秒黑线会闪一下。
// 状态机在视频加载 / 状态变化时创建或显示黑线视图，进度 tick 是在它之后才跑，所以必须在创建/显示时就拦：
// didMoveToWindow 在视图进窗口时跑，setHidden 在状态机试图显示它时跑，两处都按细黑满宽 + 靠近屏幕底部判断，
// 全屏开时直接藏，跑在显示之前，用户就看不到那 1 秒。判断先查开关、尺寸、颜色，都是廉价检查，
// 只有细黑满宽才再算窗口位置，不合的立刻放行，不影响其他视图；关全屏时原样放行，恢复由原逻辑负责。
- (void)didMoveToWindow {
    %orig;
    if (!DYYYGetBool(@"DYYYEnableFullScreen") || !self.window) return;
    CGFloat h = CGRectGetHeight(self.bounds);
    CGFloat w = CGRectGetWidth(self.bounds);
    if (h < 0.2 || h > 6.0 || w < 250.0) return;
    UIColor *bg = self.backgroundColor;
    BOOL isBlack = NO;
    if (bg) {
        CGFloat r = 0, g = 0, b = 0, a = 0;
        if ([bg getRed:&r green:&g blue:&b alpha:&a] && r < 0.5 && g < 0.5 && b < 0.5 && a > 0.2) isBlack = YES;
    }
    if (!isBlack) {
        NSString *cn = NSStringFromClass([self class]);
        if (!([cn containsString:@"Under"] || [cn containsString:@"Track"] || [cn containsString:@"Separator"] || [cn containsString:@"Line"])) return;
    }
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    if (screenH > 0) {
        CGRect winF = [self convertRect:self.bounds toView:self.window];
        if (CGRectGetMaxY(winF) < screenH - 200.0) return;
    }
    // 只在视频层级里藏：祖先里有 Progress/Feed/Player/Aweme/Video 才算，避免把设置页、评论区等同类细线误藏
    {
        BOOL inVideo = NO;
        UIView *anc = self.superview;
        for (NSInteger i = 0; anc && i < 12; i++, anc = anc.superview) {
            NSString *cn = NSStringFromClass([anc class]);
            if ([cn containsString:@"Progress"] || [cn containsString:@"Feed"] || [cn containsString:@"Player"] || [cn containsString:@"Aweme"] || [cn containsString:@"Video"]) { inVideo = YES; break; }
        }
        if (!inVideo) return;
    }
    self.hidden = YES;
}

- (void)setHidden:(BOOL)hidden {
    if (!hidden && DYYYGetBool(@"DYYYEnableFullScreen")) {
        CGFloat h = CGRectGetHeight(self.bounds);
        CGFloat w = CGRectGetWidth(self.bounds);
        if (h >= 0.2 && h <= 6.0 && w >= 250.0) {
            UIColor *bg = self.backgroundColor;
            BOOL isBlack = NO;
            if (bg) {
                CGFloat r = 0, g = 0, b = 0, a = 0;
                if ([bg getRed:&r green:&g blue:&b alpha:&a] && r < 0.5 && g < 0.5 && b < 0.5 && a > 0.2) isBlack = YES;
            }
            if (!isBlack) {
                NSString *cn = NSStringFromClass([self class]);
                if (!([cn containsString:@"Under"] || [cn containsString:@"Track"] || [cn containsString:@"Separator"] || [cn containsString:@"Line"])) {
                    %orig(hidden);
                    return;
                }
            }
            BOOL nearBottom = YES;
            CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
            if (screenH > 0 && self.window) {
                CGRect winF = [self convertRect:self.bounds toView:self.window];
                if (CGRectGetMaxY(winF) < screenH - 200.0) nearBottom = NO;
            }
            if (nearBottom) {
                BOOL inVideo = NO;
                UIView *anc = self.superview;
                for (NSInteger i = 0; anc && i < 12; i++, anc = anc.superview) {
                    NSString *cn = NSStringFromClass([anc class]);
                    if ([cn containsString:@"Progress"] || [cn containsString:@"Feed"] || [cn containsString:@"Player"] || [cn containsString:@"Aweme"] || [cn containsString:@"Video"]) { inVideo = YES; break; }
                }
                if (!inVideo) {
                    %orig(hidden);
                    return;
                }
                %orig(YES);
                return;
            }
        }
    }
    %orig(hidden);
}

%end

%hook AWEIMSkylightListView
- (void)setFrame:(CGRect)frame {
    if (DYYYGetBool(@"DYYYHideAvatarList")) {
        CGFloat scale = [UIScreen mainScreen].scale ?: 2.0;
        CGFloat minH = MAX(1.0 / scale, 0.5);
        frame.size.height = minH;
    }
    %orig(frame);
}
%end

%hook AFDPureModePageTapController

- (void)onVideoPlayerViewDoubleClicked:(id)arg1 {
    BOOL isSwitchOn = DYYYGetBool(@"DYYYDisableDoubleTapLike");
    if (!isSwitchOn) {
        %orig;
    }
}

%end

%hook AWEPlayInteractionViewController

- (void)onVideoPlayerViewDoubleClicked:(id)arg1 {
    BOOL isSwitchOn = DYYYGetBool(@"DYYYDisableDoubleTapLike");
    if (!isSwitchOn) {
        %orig;
    }
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    isInPlayInteractionVC = YES;
    dyyyInteractionViewVisible = YES;
    updateSpeedButtonVisibility();
    updateClearButtonVisibility();
}

- (void)viewDidLayoutSubviews {
    %orig;

    if (isFloatSpeedButtonEnabled) {
        BOOL hasRightStack = NO;
        Class stackClass = NSClassFromString(@"AWEElementStackView");
        for (UIView *sub in self.view.subviews) {
            if ([sub isKindOfClass:stackClass] && ([sub.accessibilityLabel isEqualToString:@"right"] || [DYYYUtils containsSubviewOfClass:NSClassFromString(@"AWEPlayInteractionUserAvatarView")
                                                                                                                              inContainer:self.view])) {
                hasRightStack = YES;
                break;
            }
        }
        if (hasRightStack) {
            if (speedButton == nil) {
                speedButtonSize = [[NSUserDefaults standardUserDefaults] floatForKey:@"DYYYSpeedButtonSize"] ?: 32.0;
                CGRect screenBounds = [UIScreen mainScreen].bounds;
                CGRect initialFrame = CGRectMake((screenBounds.size.width - speedButtonSize) / 2, (screenBounds.size.height - speedButtonSize) / 2, speedButtonSize, speedButtonSize);
                speedButton = [[FloatingSpeedButton alloc] initWithFrame:initialFrame];
                speedButton.interactionController = self;
                showSpeedX = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYSpeedButtonShowX"];
                updateSpeedButtonUI();
            } else {
                [speedButton resetButtonState];
                if (speedButton.interactionController == nil || speedButton.interactionController != self) {
                    speedButton.interactionController = self;
                }
                if (speedButton.frame.size.width != speedButtonSize) {
                    CGPoint center = speedButton.center;
                    CGRect newFrame = CGRectMake(0, 0, speedButtonSize, speedButtonSize);
                    speedButton.frame = newFrame;
                    speedButton.center = center;
                    speedButton.layer.cornerRadius = speedButtonSize / 2;
                }
            }
            dyyyInteractionViewVisible = YES;
            UIWindow *keyWindow = [DYYYUtils getActiveWindow];
            if (keyWindow && ![speedButton isDescendantOfView:keyWindow]) {
                [keyWindow addSubview:speedButton];
                [speedButton loadSavedPosition];
                [speedButton resetFadeTimer];
            }
        }
    }

    UIWindow *keyWindow = [DYYYUtils getActiveWindow];
    if (keyWindow && keyWindow.safeAreaInsets.bottom == 0) {
        return;
    }

    if (!DYYYGetBool(@"DYYYEnableFullScreen")) {
        return;
    }

    UIViewController *directParentVC = self.parentViewController;
    UIViewController *parentVC = directParentVC;
    int maxIterations = 3;
    int count = 0;

    while (parentVC && count < maxIterations) {
        if ([parentVC isKindOfClass:%c(AFDPlayRemoteFeedTableViewController)]) {
            return;
        }
        parentVC = parentVC.parentViewController;
        count++;
    }

    if (!self.view.superview) {
        return;
    }

    CGRect frame = self.view.frame;
    CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
    CGFloat superviewHeight = self.view.superview.frame.size.height;

    if (frame.size.width != screenWidth && frame.size.height < superviewHeight) {
        return;
    }

    NSString *currentReferString = self.referString;

    BOOL useFullHeight = [currentReferString isEqualToString:@"general_search"] || [currentReferString isEqualToString:@"search_result"] || [currentReferString isEqualToString:@"search_ecommerce"] ||
                         [currentReferString isEqualToString:@"close_friends_moment"] || [currentReferString isEqualToString:@"offline_mode"] || [currentReferString isEqualToString:@"challenge"] ||
                         [currentReferString isEqualToString:@"general_search_scan"] || currentReferString == nil;

    if (!useFullHeight && [currentReferString isEqualToString:@"co_play_watch"]) {
        Class richContentVCClass = NSClassFromString(@"AWEFriendsImpl.RichContentNewListViewController");
        if (richContentVCClass && [directParentVC isKindOfClass:richContentVCClass]) {
            useFullHeight = YES;
        }
    }

    if (!useFullHeight && [currentReferString isEqualToString:@"chat"]) {
        static NSNumber *shouldRestoreChat = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
          BOOL includeChat = NO;
          Class managerClass = %c(AWEVersionUpdateManager);
          if (managerClass && [managerClass respondsToSelector:@selector(sharedInstance)]) {
              AWEVersionUpdateManager *manager = [managerClass sharedInstance];
              if ([manager respondsToSelector:@selector(currentVersion)]) {
                  NSString *currentVersion = manager.currentVersion;
                  if (currentVersion.length > 0) {
                      includeChat = ([DYYYUtils compareVersion:currentVersion toVersion:@"35.5.0"] == NSOrderedAscending);
                  }
              }
          }
          shouldRestoreChat = @(includeChat);
        });

        if (shouldRestoreChat.boolValue) {
            useFullHeight = YES;
        }
    }

    if (useFullHeight) {
        frame.size.height = superviewHeight;
    } else {
        frame.size.height = superviewHeight - gCurrentTabBarHeight;
    }

    if (fabs(frame.size.height - self.view.frame.size.height) > 0.5) {
        self.view.frame = frame;
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    BOOL hasRightStack = NO;
    Class stackClass = NSClassFromString(@"AWEElementStackView");
    for (UIView *sub in self.view.subviews) {
        if ([sub isKindOfClass:stackClass] && ([sub.accessibilityLabel isEqualToString:@"right"] || [DYYYUtils containsSubviewOfClass:NSClassFromString(@"AWEPlayInteractionUserAvatarView")
                                                                                                                          inContainer:self.view])) {
            hasRightStack = YES;
            break;
        }
    }
    if (hasRightStack) {
        dyyyInteractionViewVisible = NO;
        dyyyCommentViewVisible = self.isCommentVCShowing;
        updateSpeedButtonVisibility();
        updateClearButtonVisibility();
    }
}

%new
- (void)speedButtonTapped:(UIButton *)sender {
    [(FloatingSpeedButton *)sender resetFadeTimer];
    NSArray *speeds = getSpeedOptions();
    if (speeds.count == 0)
        return;

    NSInteger currentIndex = getCurrentSpeedIndex();
    NSInteger newIndex = (currentIndex + 1) % speeds.count;

    setCurrentSpeedIndex(newIndex);

    float newSpeed = [speeds[newIndex] floatValue];

    NSString *formattedSpeed;
    if (fmodf(newSpeed, 1.0) == 0) {
        formattedSpeed = [NSString stringWithFormat:@"%.0f", newSpeed];
    } else if (fmodf(newSpeed * 10, 1.0) == 0) {
        formattedSpeed = [NSString stringWithFormat:@"%.1f", newSpeed];
    } else {
        formattedSpeed = [NSString stringWithFormat:@"%.2f", newSpeed];
    }

    if (showSpeedX) {
        formattedSpeed = [formattedSpeed stringByAppendingString:@"x"];
    }

    [sender setTitle:formattedSpeed forState:UIControlStateNormal];

    [UIView animateWithDuration:0.1
        delay:0
        options:UIViewAnimationOptionCurveEaseOut
        animations:^{
          sender.transform = CGAffineTransformMakeScale(1.1, 1.1);
        }
        completion:^(BOOL finished) {
          [UIView animateWithDuration:0.1
                                delay:0
                              options:UIViewAnimationOptionCurveEaseIn
                           animations:^{
                             sender.transform = CGAffineTransformIdentity;
                           }
                           completion:nil];
        }];

    BOOL speedApplied = NO;

    UIWindow *win = [DYYYUtils getActiveWindow];
    UIViewController *rootVC = win.rootViewController;
    while (rootVC && rootVC.presentedViewController) {
        rootVC = rootVC.presentedViewController;
    }

    NSArray *viewControllers = rootVC ? findViewControllersInHierarchy(rootVC) : @[];

    for (UIViewController *vc in viewControllers) {
        if ([vc isKindOfClass:%c(AWEAwemePlayVideoViewController)]) {
            [(AWEAwemePlayVideoViewController *)vc setVideoControllerPlaybackRate:newSpeed];
            speedApplied = YES;
        }
        if ([vc isKindOfClass:%c(AWEDPlayerFeedPlayerViewController)]) {
            [(AWEDPlayerFeedPlayerViewController *)vc setVideoControllerPlaybackRate:newSpeed];
            speedApplied = YES;
        }
        if ([vc isKindOfClass:objc_getClass("AWEDPlayerViewController_Merge")]) {
            [(AWEAwemePlayVideoViewController *)vc setVideoControllerPlaybackRate:newSpeed];
            speedApplied = YES;
        }
    }

    if (!speedApplied) {
        [DYYYUtils showToast:@"无法找到视频控制器"];
    }
}

%new
- (void)buttonTouchDown:(UIButton *)sender {
    [UIView animateWithDuration:0.1
                     animations:^{
                       sender.alpha = 0.7;
                       sender.transform = CGAffineTransformMakeScale(0.95, 0.95);
                     }];
}

%new
- (void)buttonTouchUp:(UIButton *)sender {
    [UIView animateWithDuration:0.1
                     animations:^{
                       sender.alpha = 1.0;
                       sender.transform = CGAffineTransformIdentity;
                     }];
}

%end

%hook AWEAwemePlayVideoViewController

- (void)setIsAutoPlay:(BOOL)arg0 {
    %orig(arg0);
    if (!DYYYShouldHandleSpeedFeatures()) {
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYUserAgreementAccepted"]) {
          float defaultSpeed = [[NSUserDefaults standardUserDefaults] floatForKey:@"DYYYDefaultSpeed"];
          if (defaultSpeed > 0 && defaultSpeed != 1) {
              dispatch_async(dispatch_get_main_queue(), ^{
                [self setVideoControllerPlaybackRate:defaultSpeed];
              });
          }
      }
      float speed = getCurrentSpeed();
      if (speed != 1.0) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [self adjustPlaybackSpeed:speed];
          });
      }
    });
}

- (void)prepareForDisplay {
    %orig;
    if (!DYYYShouldHandleSpeedFeatures()) {
        return;
    }

    BOOL autoRestoreSpeed = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYAutoRestoreSpeed"];
    if (autoRestoreSpeed) {
        setCurrentSpeedIndex(0);
    }
    float speed = getCurrentSpeed();
    if (speed != 1.0) {
        [self adjustPlaybackSpeed:speed];
    }
    updateSpeedButtonUI();
}

%new
- (void)adjustPlaybackSpeed:(float)speed {
    [self setVideoControllerPlaybackRate:speed];
}

%end

%hook AWEDPlayerFeedPlayerViewController

- (void)viewDidLayoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        UIView *contentView = self.contentView;
        if (contentView && contentView.superview) {
            CGRect frame = contentView.frame;
            CGFloat parentHeight = contentView.superview.frame.size.height;

            if (frame.size.height == parentHeight - gCurrentTabBarHeight) {
                frame.size.height = parentHeight;
                contentView.frame = frame;
            } else if (frame.size.height == parentHeight - (gCurrentTabBarHeight * 2)) {
                frame.size.height = parentHeight - gCurrentTabBarHeight;
                contentView.frame = frame;
            }
        }
    }
}

- (void)setIsAutoPlay:(BOOL)arg0 {
    %orig(arg0);
    if (!DYYYShouldHandleSpeedFeatures()) {
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYUserAgreementAccepted"]) {
          float defaultSpeed = [[NSUserDefaults standardUserDefaults] floatForKey:@"DYYYDefaultSpeed"];
          if (defaultSpeed > 0 && defaultSpeed != 1) {
              dispatch_async(dispatch_get_main_queue(), ^{
                [self setVideoControllerPlaybackRate:defaultSpeed];
              });
          }
      }
      float speed = getCurrentSpeed();
      if (speed != 1.0) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [self adjustPlaybackSpeed:speed];
          });
      }
    });
}

- (void)prepareForDisplay {
    %orig;
    if (!DYYYShouldHandleSpeedFeatures()) {
        return;
    }
    BOOL autoRestoreSpeed = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYAutoRestoreSpeed"];
    if (autoRestoreSpeed) {
        setCurrentSpeedIndex(0);
    }
    float speed = getCurrentSpeed();
    if (speed != 1.0) {
        [self adjustPlaybackSpeed:speed];
    }
    updateSpeedButtonUI();
}

%new
- (void)adjustPlaybackSpeed:(float)speed {
    [self setVideoControllerPlaybackRate:speed];
}

%end

%hook AWEDPlayerViewController_Merge

- (void)viewDidLayoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        UIView *contentView = self.contentView;
        if (contentView && contentView.superview) {
            CGRect frame = contentView.frame;
            CGFloat parentHeight = contentView.superview.frame.size.height;

            if (frame.size.height == parentHeight - gCurrentTabBarHeight) {
                frame.size.height = parentHeight;
                contentView.frame = frame;
            } else if (frame.size.height == parentHeight - (gCurrentTabBarHeight * 2)) {
                frame.size.height = parentHeight - gCurrentTabBarHeight;
                contentView.frame = frame;
            }
        }
    }
}

- (void)setIsAutoPlay:(BOOL)arg0 {
    %orig(arg0);
    if (!DYYYShouldHandleSpeedFeatures()) {
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYUserAgreementAccepted"]) {
          float defaultSpeed = [[NSUserDefaults standardUserDefaults] floatForKey:@"DYYYDefaultSpeed"];
          if (defaultSpeed > 0 && defaultSpeed != 1) {
              dispatch_async(dispatch_get_main_queue(), ^{
                [self setVideoControllerPlaybackRate:defaultSpeed];
              });
          }
      }
      float speed = getCurrentSpeed();
      if (speed != 1.0) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [self adjustPlaybackSpeed:speed];
          });
      }
    });
}

- (void)prepareForDisplay {
    %orig;
    if (!DYYYShouldHandleSpeedFeatures()) {
        return;
    }
    BOOL autoRestoreSpeed = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYAutoRestoreSpeed"];
    if (autoRestoreSpeed) {
        setCurrentSpeedIndex(0);
    }
    float speed = getCurrentSpeed();
    if (speed != 1.0) {
        [self adjustPlaybackSpeed:speed];
    }
    updateSpeedButtonUI();
}

%new
- (void)adjustPlaybackSpeed:(float)speed {
    [self setVideoControllerPlaybackRate:speed];
}

%end

%hook AWEFeedTableView
- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        CGRect frame = self.frame;
        frame.size.height = self.superview.frame.size.height;
        self.frame = frame;
    } else if (gCurrentTabBarHeight > 0) {
        UIWindow *keyWindow = [DYYYUtils getActiveWindow];
        if (keyWindow && keyWindow.safeAreaInsets.bottom == 0) {
            return;
        }

        CGRect frame = self.frame;
        frame.size.height = self.superview.frame.size.height - gCurrentTabBarHeight;
        self.frame = frame;
    }
}
%end

%hook AWEFeedTableViewCell
- (void)prepareForReuse {
    if (hideButton && hideButton.isElementsHidden) {
        [hideButton hideUIElements];
    }
    %orig;
}

- (void)layoutSubviews {
    %orig;
    if (hideButton && hideButton.isElementsHidden) {
        [hideButton hideUIElements];
    }
}
%end

%hook AWEFeedViewCell
- (void)layoutSubviews {
    if (hideButton && hideButton.isElementsHidden) {
        [hideButton hideUIElements];
    }
    %orig;
}

- (void)setModel:(id)model {
    if (hideButton && hideButton.isElementsHidden) {
        [hideButton hideUIElements];
    }
    %orig;
}
%end

%hook UIViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    isAppInTransition = YES;
    if (hideButton && hideButton.isElementsHidden) {
        [hideButton hideUIElements];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      isAppInTransition = NO;
    });
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    isAppInTransition = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      isAppInTransition = NO;
    });
}
%end

%hook AFDPureModePageContainerViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    isPureViewVisible = YES;
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    isPureViewVisible = NO;
}
%end

%hook AWEFeedContainerViewController
- (void)aweme:(id)arg1 currentIndexWillChange:(NSInteger)arg2 {
    if (hideButton && hideButton.isElementsHidden) {
        [hideButton hideUIElements];
    }
    %orig;
}

- (void)aweme:(id)arg1 currentIndexDidChange:(NSInteger)arg2 {
    if (hideButton && hideButton.isElementsHidden) {
        [hideButton hideUIElements];
    }
    %orig;
}

- (void)viewWillLayoutSubviews {
    %orig;
    if (hideButton && hideButton.isElementsHidden) {
        [hideButton hideUIElements];
    }
}
%end

static id dyyyWindowKeyObserverToken = nil;
static id dyyyDidBecomeActiveToken = nil;
static id dyyyWillResignActiveToken = nil;
static id dyyyKeyboardWillShowToken = nil;
static void *DYYYGlobalTransparencyContext = &DYYYGlobalTransparencyContext;

static void DYYYRemoveAppLifecycleObservers(void) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    if (dyyyWindowKeyObserverToken) {
        [center removeObserver:dyyyWindowKeyObserverToken];
        dyyyWindowKeyObserverToken = nil;
    }
    if (dyyyDidBecomeActiveToken) {
        [center removeObserver:dyyyDidBecomeActiveToken];
        dyyyDidBecomeActiveToken = nil;
    }
    if (dyyyWillResignActiveToken) {
        [center removeObserver:dyyyWillResignActiveToken];
        dyyyWillResignActiveToken = nil;
    }
}

static void DYYYRemoveKeyboardObserver(void) {
    if (dyyyKeyboardWillShowToken) {
        [[NSNotificationCenter defaultCenter] removeObserver:dyyyKeyboardWillShowToken];
        dyyyKeyboardWillShowToken = nil;
    }
}

%hook AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    BOOL result = %orig;
    initTargetClassNames();

    updateGlobalTransparencyCache();

    [[NSUserDefaults standardUserDefaults] addObserver:(NSObject *)self forKeyPath:kDYYYGlobalTransparencyKey options:NSKeyValueObservingOptionNew context:DYYYGlobalTransparencyContext];

    BOOL isEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYEnableFloatClearButton"];
    if (isEnabled) {
        if (hideButton) {
            [hideButton removeFromSuperview];
            hideButton = nil;
        }

        CGFloat buttonSize = [[NSUserDefaults standardUserDefaults] floatForKey:@"DYYYEnableFloatClearButtonSize"] ?: 40.0;
        hideButton = [[HideUIButton alloc] initWithFrame:CGRectMake(0, 0, buttonSize, buttonSize)];
        hideButton.alpha = 0.5;

        NSString *savedPositionString = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYHideUIButtonPosition"];
        if (savedPositionString) {
            hideButton.center = CGPointFromString(savedPositionString);
        } else {
            CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
            CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;
            hideButton.center = CGPointMake(screenWidth - buttonSize / 2 - 5, screenHeight / 2);
        }

        hideButton.hidden = NO;
        [getKeyWindow() addSubview:hideButton];
        updateClearButtonVisibility();

        DYYYRemoveAppLifecycleObservers();

        dyyyWindowKeyObserverToken = [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
                                                                                       object:nil
                                                                                        queue:[NSOperationQueue mainQueue]
                                                                                   usingBlock:^(NSNotification *_Nonnull notification) {
                                                                                     updateClearButtonVisibility();
                                                                                   }];

        dyyyDidBecomeActiveToken = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                                     object:nil
                                                                                      queue:[NSOperationQueue mainQueue]
                                                                                 usingBlock:^(NSNotification *_Nonnull notification) {
                                                                                   isAppActive = YES;
                                                                                   updateClearButtonVisibility();
                                                                                 }];

        dyyyWillResignActiveToken = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification
                                                                                      object:nil
                                                                                       queue:[NSOperationQueue mainQueue]
                                                                                  usingBlock:^(NSNotification *_Nonnull notification) {
                                                                                    isAppActive = NO;
                                                                                    updateClearButtonVisibility();
                                                                                  }];
    } else {
        DYYYRemoveAppLifecycleObservers();
    }

    return result;
}

- (void)applicationWillTerminate:(UIApplication *)application {
    DYYYRemoveAppLifecycleObservers();
    DYYYRemoveKeyboardObserver();
    %orig;
}

- (void)dealloc {
    DYYYRemoveAppLifecycleObservers();
    DYYYRemoveKeyboardObserver();
    @try {
        [[NSUserDefaults standardUserDefaults] removeObserver:(NSObject *)self forKeyPath:kDYYYGlobalTransparencyKey context:DYYYGlobalTransparencyContext];
    } @catch (NSException *exception) {
        NSLog(@"[DYYY] KVO removeObserver failed: %@", exception);
    } 
    %orig;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context {
    if (context == DYYYGlobalTransparencyContext) {
        dispatch_async(dispatch_get_main_queue(), ^{
          updateGlobalTransparencyCache();
          [[NSNotificationCenter defaultCenter] postNotificationName:kDYYYGlobalTransparencyDidChangeNotification object:nil];
        });
    } else {
        %orig(keyPath, object, change, context);
    }
}

%end

static Class GuideViewClass = nil;
static Class MuteViewClass = nil;
static Class TagViewClass = nil;

%hook AWEElementStackView

- (void)setAlpha:(CGFloat)alpha {
    BOOL isApplyingGlobal = (dyyyGlobalTransparencyMutationDepth > 0);
    if (!isApplyingGlobal) {
        objc_setAssociatedObject(self, &kDYYYGlobalTransparencyBaseAlphaKey, @(alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // 纯净模式功能
    static AWMSafeDispatchTimer *pureModeTimer = nil;
    static int attempts = 0;
    static BOOL pureModeSet = NO;
    if (DYYYGetBool(@"DYYYEnablePure")) {
        %orig(0.0);
        if (pureModeSet) {
            return;
        }
        if (!pureModeTimer) {
            pureModeTimer = [[AWMSafeDispatchTimer alloc] init];
        }
        if (!pureModeTimer.isRunning) {
            attempts = 0;
            __weak AWMSafeDispatchTimer *weakTimer = pureModeTimer;
            [pureModeTimer startWithInterval:0.5
                                      leeway:0.1
                                       queue:dispatch_get_main_queue()
                                     repeats:YES
                                     handler:^{
                                       AWMSafeDispatchTimer *strongTimer = weakTimer;
                                       UIWindow *keyWindow = [DYYYUtils getActiveWindow];
                                       if (keyWindow && keyWindow.rootViewController) {
                                           UIViewController *feedVC = [DYYYUtils findViewControllerOfClass:NSClassFromString(@"AWEFeedTableViewController")
                                                                                          inViewController:keyWindow.rootViewController];
                                           if (feedVC) {
                                               [feedVC setValue:@YES forKey:@"pureMode"];
                                               pureModeSet = YES;
                                               [strongTimer cancel];
                                               pureModeTimer = nil;
                                               attempts = 0;
                                               return;
                                           }
                                       }
                                       attempts++;
                                       if (attempts >= 10) {
                                           [strongTimer cancel];
                                           pureModeTimer = nil;
                                           attempts = 0;
                                       }
                                     }];
        }
        return;
    }

    // 清理纯净模式的残留状态
    if (pureModeTimer) {
        [pureModeTimer cancel];
        pureModeTimer = nil;
    }
    attempts = 0;
    pureModeSet = NO;

    // 倍速和清屏按钮的状态控制
    BOOL hasFloatingButtons = (speedButton && isFloatSpeedButtonEnabled) || hideButton;
    if (!isApplyingGlobal && hasFloatingButtons && !dyyyIsPerformingFloatClearOperation) {
        const CGFloat threshold = 0.01f;
        if (alpha <= threshold) {
            dyyyCommentViewVisible = YES;
        } else if (alpha >= (1.0f - threshold)) {
            dyyyCommentViewVisible = NO;
        }
        updateSpeedButtonVisibility();
        updateClearButtonVisibility();
    }

    // 值守全局透明度
    CGFloat finalAlpha = alpha;
    if (!isApplyingGlobal && self.tag != DYYY_IGNORE_GLOBAL_ALPHA_TAG && gGlobalTransparency != kInvalidAlpha) {
        CGFloat clampedAlpha = MIN(MAX(alpha, 0.0), 1.0);
        finalAlpha = clampedAlpha * gGlobalTransparency;
    }

    // 统一应用透明度
    if (fabs(self.alpha - finalAlpha) >= 0.01) {
        %orig(finalAlpha);
    }
}

+ (void)initialize {
    GuideViewClass = NSClassFromString(@"AWELivePrestreamGuideView");
    MuteViewClass = NSClassFromString(@"AFDCancelMuteAwemeView");
    TagViewClass = NSClassFromString(@"AWELiveFeedLabelTagView");
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    dyyyCommentViewVisible = NO;
    updateSpeedButtonVisibility();
    updateClearButtonVisibility();
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    dyyyCommentViewVisible = YES;
    updateSpeedButtonVisibility();
    updateClearButtonVisibility();
}

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        [self dyyy_applyGlobalTransparency];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(dyyy_applyGlobalTransparency) name:kDYYYGlobalTransparencyDidChangeNotification object:nil];
    } else {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:kDYYYGlobalTransparencyDidChangeNotification object:nil];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    %orig;
}

- (void)layoutSubviews {
    %orig;

    UIViewController *viewController = [DYYYUtils firstAvailableViewControllerFromView:self];

    if ([viewController isKindOfClass:%c(AWELiveNewPreStreamViewController)]) {
        // 2.2-9-23 直播嵌套栈防重复上移：直播 HUD 里 IESLiveStackView 和 AWEElementStackView 可能嵌套，
        // 原代码每层都上移一个底栏高，嵌套几层就上移几倍，文案就跑到中间。只让最外层那层上移，
        // 内层只做缩放、不再上移；单层时行为与原来完全一致（-8 确认正常的那套）。
        BOOL hasAncestorLiveStack = NO;
        {
            UIView *anc = self.superview;
            Class iesCls = NSClassFromString(@"IESLiveStackView");
            Class eleCls = NSClassFromString(@"AWEElementStackView");
            for (NSInteger i = 0; anc && i < 12; i++, anc = anc.superview) {
                if ((iesCls && [anc isKindOfClass:iesCls]) || (eleCls && [anc isKindOfClass:eleCls])) {
                    hasAncestorLiveStack = YES;
                    break;
                }
            }
        }
        const BOOL shouldShiftUp = DYYYGetBool(@"DYYYEnableFullScreen") && !hasAncestorLiveStack;
        const CGFloat labelScaleValue = DYYYGetFloat(@"DYYYNicknameScale");
        const CGFloat targetLabelScale = (labelScaleValue != 0.0) ? MAX(0.01, labelScaleValue) : 1.0;
        const CGFloat elementScaleValue = DYYYGetFloat(@"DYYYElementScale");
        const CGFloat targetElementScale = (elementScaleValue != 0.0) ? MAX(0.01, elementScaleValue) : 1.0;

        CGAffineTransform targetTransform = CGAffineTransformIdentity;
        CGFloat boundsWidth = self.bounds.size.width;
        CGFloat currentScale = 1.0;
        CGFloat targetHeight, tx, ty = 0;
        UIWindow *keyWindow = [DYYYUtils getActiveWindow];
        if (keyWindow && keyWindow.safeAreaInsets.bottom == 0) {
            targetHeight = gCurrentTabBarHeight - originalTabBarHeight;
        } else {
            targetHeight = gCurrentTabBarHeight;
        }

        if ([DYYYUtils containsSubviewOfClass:GuideViewClass inContainer:self]) {
            currentScale = targetLabelScale;
            tx = 0; // 中对齐
        } else if ([DYYYUtils containsSubviewOfClass:MuteViewClass inContainer:self]) {
            currentScale = targetElementScale;
            tx = (boundsWidth - boundsWidth * currentScale) / 2; // 右对齐
        } else if ([DYYYUtils containsSubviewOfClass:TagViewClass inContainer:self]) {
            currentScale = targetLabelScale;
            tx = (boundsWidth - boundsWidth * currentScale) / -2; // 左对齐
        }

        NSArray *subviews = [self.subviews copy];
        for (UIView *view in subviews) {
            CGFloat viewHeight = view.bounds.size.height;
            ty += (viewHeight - viewHeight * currentScale) / 2;
        }

        if (shouldShiftUp) {
            ty -= targetHeight;
        }

        targetTransform = CGAffineTransformMake(currentScale, 0, 0, currentScale, tx, ty);

        if (!CGAffineTransformEqualToTransform(self.transform, targetTransform)) {
            self.transform = targetTransform;
        }
    }

    if ([viewController isKindOfClass:%c(AWEPlayInteractionViewController)]) {
        NSString *label = self.accessibilityLabel ?: @"";
        BOOL hasAnchor = [DYYYUtils containsSubviewOfClass:NSClassFromString(@"AWEFeedAnchorContainerView") inContainer:self];
        BOOL hasAvatar = [DYYYUtils containsSubviewOfClass:NSClassFromString(@"AWEPlayInteractionUserAvatarView") inContainer:self];

        BOOL isRightStack = ([label isEqualToString:@"right"] || hasAvatar);
        if (!isRightStack) {
            NSArray *subviews = [self.subviews copy];
            for (NSInteger i = (NSInteger)subviews.count - 1; i >= 0; i--) {
                UIView *sub = subviews[i];
                if ([sub respondsToSelector:@selector(elementClassName)]) {
                    NSString *elementClassName = [sub performSelector:@selector(elementClassName)];
                    if ([elementClassName isEqualToString:@"AWEPlayInteractionUserAvatarOptElementElement"]) {
                        isRightStack = YES;
                        break;
                    }
                }
            }
        }

        BOOL isLeftStack = ([label isEqualToString:@"left"] || hasAnchor);
        if (!isLeftStack) {
            NSArray *subviews = [self.subviews copy];
            for (NSInteger i = (NSInteger)subviews.count - 1; i >= 0; i--) {
                UIView *sub = subviews[i];
                if ([sub respondsToSelector:@selector(elementClassName)]) {
                    NSString *elementClassName = [sub performSelector:@selector(elementClassName)];
                    if ([elementClassName isEqualToString:@"AWEPlayInteractionDescriptionElement"]) {
                        isLeftStack = YES;
                        break;
                    }
                }
            }
        }

        // 右侧元素的处理逻辑
        if (isRightStack) {
            NSString *scaleValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYElementScale"];
            self.transform = CGAffineTransformIdentity;
            if (scaleValue.length > 0) {
                CGFloat scale = [scaleValue floatValue];
                if (scale > 0 && scale != 1.0) {
                    NSArray *subviews = [self.subviews copy];
                    CGFloat ty = 0;
                    for (UIView *view in subviews) {
                        CGFloat viewHeight = view.frame.size.height;
                        ty += (viewHeight - viewHeight * scale) / 2;
                    }
                    CGFloat frameWidth = self.frame.size.width;
                    CGFloat right_tx = (frameWidth - frameWidth * scale) / 2;
                    self.transform = CGAffineTransformMake(scale, 0, 0, scale, right_tx, ty);
                } else {
                    self.transform = CGAffineTransformIdentity;
                }
            }
        }
        // 左侧元素的处理逻辑
        else if (isLeftStack) {
            NSString *scaleValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYNicknameScale"];
            if (scaleValue.length > 0) {
                CGFloat scale = [scaleValue floatValue];
                self.transform = CGAffineTransformIdentity;
                if (scale > 0 && scale != 1.0) {
                    NSArray *subviews = [self.subviews copy];
                    CGFloat ty = 0;
                    for (UIView *view in subviews) {
                        CGFloat viewHeight = view.frame.size.height;
                        ty += (viewHeight - viewHeight * scale) / 2;
                    }
                    CGFloat frameWidth = self.frame.size.width;
                    CGFloat left_tx = (frameWidth - frameWidth * scale) / 2 - frameWidth * (1 - scale);
                    CGAffineTransform newTransform = CGAffineTransformMakeScale(scale, scale);
                    newTransform = CGAffineTransformTranslate(newTransform, left_tx / scale, ty / scale);
                    self.transform = newTransform;
                }
            }
        }
    }
}

- (NSArray<__kindof UIView *> *)arrangedSubviews {

    UIViewController *viewController = [DYYYUtils firstAvailableViewControllerFromView:self];
    if ([viewController isKindOfClass:%c(AWEPlayInteractionViewController)]) {

        if ([self.accessibilityLabel isEqualToString:@"left"] || [DYYYUtils containsSubviewOfClass:NSClassFromString(@"AWEFeedAnchorContainerView") inContainer:self]) {
            NSString *scaleValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYNicknameScale"];
            if (scaleValue.length > 0) {
                CGFloat scale = [scaleValue floatValue];
                self.transform = CGAffineTransformIdentity;
                if (scale > 0 && scale != 1.0) {
                    NSArray *subviews = [self.subviews copy];
                    CGFloat ty = 0;
                    for (UIView *view in subviews) {
                        CGFloat viewHeight = view.frame.size.height;
                        ty += (viewHeight - viewHeight * scale) / 2;
                    }
                    CGFloat frameWidth = self.frame.size.width;
                    CGFloat left_tx = (frameWidth - frameWidth * scale) / 2 - frameWidth * (1 - scale);
                    CGAffineTransform newTransform = CGAffineTransformMakeScale(scale, scale);
                    newTransform = CGAffineTransformTranslate(newTransform, left_tx / scale, ty / scale);
                    self.transform = newTransform;
                }
            }
        }
    }

    NSArray *originalSubviews = %orig;
    return originalSubviews;
}

%end

%hook IESLiveStackView

+ (void)initialize {
    GuideViewClass = NSClassFromString(@"AWELivePrestreamGuideView");
    MuteViewClass = NSClassFromString(@"AFDCancelMuteAwemeView");
    TagViewClass = NSClassFromString(@"AWELiveFeedLabelTagView");
}

- (void)setAlpha:(CGFloat)alpha {
    BOOL isApplyingGlobal = (dyyyGlobalTransparencyMutationDepth > 0);
    if (!isApplyingGlobal) {
        objc_setAssociatedObject(self, &kDYYYGlobalTransparencyBaseAlphaKey, @(alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!isApplyingGlobal && speedButton && isFloatSpeedButtonEnabled) {
        if (alpha == 0) {
            dyyyCommentViewVisible = YES;
        } else if (alpha == 1) {
            dyyyCommentViewVisible = NO;
        }
        updateSpeedButtonVisibility();
        updateClearButtonVisibility();
    }

    CGFloat finalAlpha = alpha;
    if (!isApplyingGlobal && self.tag != DYYY_IGNORE_GLOBAL_ALPHA_TAG && gGlobalTransparency != kInvalidAlpha) {
        CGFloat clampedAlpha = MIN(MAX(alpha, 0.0), 1.0);
        finalAlpha = clampedAlpha * gGlobalTransparency;
    }

    if (fabs(self.alpha - finalAlpha) >= 0.01) {
        %orig(finalAlpha);
    }
}

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        [self dyyy_applyGlobalTransparency];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(dyyy_applyGlobalTransparency) name:kDYYYGlobalTransparencyDidChangeNotification object:nil];
    } else {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:kDYYYGlobalTransparencyDidChangeNotification object:nil];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    %orig;
}

- (void)layoutSubviews {
    %orig;

    UIViewController *viewController = [DYYYUtils firstAvailableViewControllerFromView:self];

    if ([viewController isKindOfClass:%c(AWELiveNewPreStreamViewController)]) {
        // 2.2-9-23 直播嵌套栈防重复上移：直播 HUD 里 IESLiveStackView 和 AWEElementStackView 可能嵌套，
        // 原代码每层都上移一个底栏高，嵌套几层就上移几倍，文案就跑到中间。只让最外层那层上移，
        // 内层只做缩放、不再上移；单层时行为与原来完全一致（-8 确认正常的那套）。
        BOOL hasAncestorLiveStack = NO;
        {
            UIView *anc = self.superview;
            Class iesCls = NSClassFromString(@"IESLiveStackView");
            Class eleCls = NSClassFromString(@"AWEElementStackView");
            for (NSInteger i = 0; anc && i < 12; i++, anc = anc.superview) {
                if ((iesCls && [anc isKindOfClass:iesCls]) || (eleCls && [anc isKindOfClass:eleCls])) {
                    hasAncestorLiveStack = YES;
                    break;
                }
            }
        }
        const BOOL shouldShiftUp = DYYYGetBool(@"DYYYEnableFullScreen") && !hasAncestorLiveStack;
        const CGFloat labelScaleValue = DYYYGetFloat(@"DYYYNicknameScale");
        const CGFloat targetLabelScale = (labelScaleValue != 0.0) ? MAX(0.01, labelScaleValue) : 1.0;
        const CGFloat elementScaleValue = DYYYGetFloat(@"DYYYElementScale");
        const CGFloat targetElementScale = (elementScaleValue != 0.0) ? MAX(0.01, elementScaleValue) : 1.0;

        CGAffineTransform targetTransform = CGAffineTransformIdentity;
        CGFloat boundsWidth = self.bounds.size.width;
        CGFloat currentScale = 1.0;
        CGFloat targetHeight, tx = 0, ty = 0;
        UIWindow *keyWindow = [DYYYUtils getActiveWindow];
        if (keyWindow && keyWindow.safeAreaInsets.bottom == 0) {
            targetHeight = gCurrentTabBarHeight - originalTabBarHeight;
        } else {
            targetHeight = gCurrentTabBarHeight;
        }

        if ([DYYYUtils containsSubviewOfClass:GuideViewClass inContainer:self]) {
            currentScale = targetLabelScale;
            tx = 0; // 中对齐
        } else if ([DYYYUtils containsSubviewOfClass:MuteViewClass inContainer:self]) {
            currentScale = targetElementScale;
            tx = (boundsWidth - boundsWidth * currentScale) / 2; // 右对齐
        } else if ([DYYYUtils containsSubviewOfClass:TagViewClass inContainer:self]) {
            currentScale = targetLabelScale;
            tx = (boundsWidth - boundsWidth * currentScale) / -2; // 左对齐
        }

        NSArray *subviews = [self.subviews copy];
        for (UIView *view in subviews) {
            CGFloat viewHeight = view.bounds.size.height;
            ty += (viewHeight - viewHeight * currentScale) / 2;
        }

        if (shouldShiftUp) {
            ty -= targetHeight;
        }
        // FIX 2026-11-02: 原代码算完缩放/全屏位移后又无条件覆盖成上移 20pt
        // (CGAffineTransformMakeTranslation(0, -20))，全屏关了也照样上移，
        // 且不同 stack 移的不一致时文案和观看人数之间就被撑出空档。
        // 改回用算出的位移（与 AWEElementStackView 同款逻辑）：
        // 默认缩放+全屏关 = 单位矩阵（即抖音原位），全屏开才按底栏高度上移。
        targetTransform = CGAffineTransformMake(currentScale, 0, 0, currentScale, tx, ty);

        if (!CGAffineTransformEqualToTransform(self.transform, targetTransform)) {
            self.transform = targetTransform;
        }
    }
}

%end

%hook AWEStoryContainerCollectionView
- (void)layoutSubviews {
    %orig;
    if ([self.subviews count] == 2)
        return;

    // 获取 enableEnterProfile 属性来判断是否是主页
    id enableEnterProfile = [self valueForKey:@"enableEnterProfile"];
    BOOL isHome = (enableEnterProfile != nil && [enableEnterProfile boolValue]);

    // 检查是否在作者主页
    BOOL isAuthorProfile = NO;
    UIResponder *responder = self;
    while ((responder = [responder nextResponder])) {
        if ([NSStringFromClass([responder class]) containsString:@"UserHomeViewController"] || [NSStringFromClass([responder class]) containsString:@"ProfileViewController"]) {
            isAuthorProfile = YES;
            break;
        }
    }

    // 如果不是主页也不是作者主页，直接返回
    if (!isHome && !isAuthorProfile)
        return;

    for (UIView *subview in self.subviews) {
        if ([subview isKindOfClass:[UIView class]]) {
            UIView *nextResponder = (UIView *)subview.nextResponder;

            // 处理主页的情况
            if (isHome && [nextResponder isKindOfClass:%c(AWEPlayInteractionViewController)]) {
                UIViewController *awemeBaseViewController = [nextResponder valueForKey:@"awemeBaseViewController"];
                if (![awemeBaseViewController isKindOfClass:%c(AWEFeedCellViewController)]) {
                    continue;
                }

                CGRect frame = subview.frame;
                if (DYYYGetBool(@"DYYYEnableFullScreen")) {
                    frame.size.height = subview.superview.frame.size.height - gCurrentTabBarHeight;
                    subview.frame = frame;
                }
            }
            // 处理作者主页的情况
            else if (isAuthorProfile) {
                // 检查是否是作品图片
                BOOL isWorkImage = NO;

                // 可以通过检查子视图、标签或其他特性来确定是否是作品图片
                for (UIView *childView in subview.subviews) {
                    if ([NSStringFromClass([childView class]) containsString:@"ImageView"] || [NSStringFromClass([childView class]) containsString:@"ThumbnailView"]) {
                        isWorkImage = YES;
                        break;
                    }
                }

                if (isWorkImage) {
                    // 修复作者主页作品图片上移问题
                    CGRect frame = subview.frame;
                    frame.origin.y += gCurrentTabBarHeight;
                    subview.frame = frame;
                }
            }
        }
    }
}
%end

%hook AFDFastSpeedView
- (void)layoutSubviews {
    %orig;

    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYEnableFullScreen"]) {
        return;
    }

    static char kDYFastSpeedBgKey;
    NSArray *bgViews = objc_getAssociatedObject(self, &kDYFastSpeedBgKey);
    if (!bgViews) {
        NSMutableArray *tmp = [NSMutableArray array];
        for (UIView *subview in self.subviews) {
            if ([subview class] == [UIView class]) {
                [tmp addObject:subview];
            }
        }
        bgViews = [tmp copy];
        objc_setAssociatedObject(self, &kDYFastSpeedBgKey, bgViews, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    for (UIView *view in bgViews) {
        view.backgroundColor = [UIColor clearColor];
    }
}
%end

%hook TTPlayerView

- (void)layoutSubviews {
    %orig;
    UIView *parent = self.superview;
    if (parent) {
        parent.backgroundColor = self.backgroundColor;
    }
}

%end

%hook TTMetalView
- (void)setCenter:(CGPoint)center {
    BOOL shouldAdjust = NO;
    UIView *view = (UIView *)self;
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        CGFloat viewWidth = CGRectGetWidth(view.bounds);
        CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
        if (viewWidth + 0.5f >= screenWidth) {
            UIViewController *vc = [DYYYUtils firstAvailableViewControllerFromView:view];
            Class playClass = %c(AWEPlayVideoViewController);
            if (playClass && [vc isKindOfClass:playClass]) {
                AWEPlayVideoViewController *playVC = (AWEPlayVideoViewController *)vc;
                AWEAwemeModel *model = playVC.model;
                if ([model respondsToSelector:@selector(isShowLandscapeEntryView)] && model.isShowLandscapeEntryView) {
                    shouldAdjust = YES;
                }
            }
        }
    }

    if (shouldAdjust) {
        CGFloat offset = gCurrentTabBarHeight > 0 ? gCurrentTabBarHeight : originalTabBarHeight;
        if (offset > 0) {
            center.y -= offset * 0.5;
        }
    }

    %orig(center);
}
%end

%hook TTMetalViewNew
- (void)setCenter:(CGPoint)center {
    BOOL shouldAdjust = NO;
    UIView *view = (UIView *)self;
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        CGFloat viewWidth = CGRectGetWidth(view.bounds);
        CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
        if (viewWidth + 0.5f >= screenWidth) {
            UIViewController *vc = [DYYYUtils firstAvailableViewControllerFromView:view];
            Class playClass = %c(AWEPlayVideoViewController);
            if (playClass && [vc isKindOfClass:playClass]) {
                AWEPlayVideoViewController *playVC = (AWEPlayVideoViewController *)vc;
                AWEAwemeModel *model = playVC.model;
                if ([model respondsToSelector:@selector(isShowLandscapeEntryView)] && model.isShowLandscapeEntryView) {
                    shouldAdjust = YES;
                }
            }
        }
    }

    if (shouldAdjust) {
        CGFloat offset = gCurrentTabBarHeight > 0 ? gCurrentTabBarHeight : originalTabBarHeight;
        if (offset > 0) {
            center.y -= offset * 0.5;
        }
    }

    %orig(center);
}
%end

// 隐藏图片滑条
%hook AWEStoryProgressContainerView
- (void)setCenter:(CGPoint)center {
    UIViewController *vc = [DYYYUtils firstAvailableViewControllerFromView:self];
    if ([vc isKindOfClass:NSClassFromString(@"AWEFeedPlayControlImpl.PureModePageCellViewController")] && DYYYGetBool(@"DYYYEnableFullScreen")) {
        center.y -= gCurrentTabBarHeight;
    }
    %orig(center);
}

- (BOOL)isHidden {
    BOOL originalValue = %orig;
    BOOL customHide = DYYYGetBool(@"DYYYHideDotsIndicator");
    return originalValue || customHide;
}

- (void)setHidden:(BOOL)hidden {
    BOOL forceHide = DYYYGetBool(@"DYYYHideDotsIndicator");
    %orig(forceHide ? YES : hidden);
}
%end

%hook AWELandscapeFeedEntryView

- (void)setAlpha:(CGFloat)alpha {
    BOOL isApplyingGlobal = (dyyyGlobalTransparencyMutationDepth > 0);
    if (!isApplyingGlobal) {
        objc_setAssociatedObject(self, &kDYYYGlobalTransparencyBaseAlphaKey, @(alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CGFloat finalAlpha = alpha;
    if (!isApplyingGlobal && self.tag != DYYY_IGNORE_GLOBAL_ALPHA_TAG && gGlobalTransparency != kInvalidAlpha) {
        CGFloat clampedAlpha = MIN(MAX(alpha, 0.0), 1.0);
        finalAlpha = clampedAlpha * gGlobalTransparency;
    }

    if (fabs(self.alpha - finalAlpha) >= 0.01) {
        %orig(finalAlpha);
    }
}

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        [self dyyy_applyGlobalTransparency];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(dyyy_applyGlobalTransparency) name:kDYYYGlobalTransparencyDidChangeNotification object:nil];
    } else {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:kDYYYGlobalTransparencyDidChangeNotification object:nil];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    %orig;
}

- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYRemoveEntry")) {
        [self removeFromSuperview];
        return;
    }
    if (DYYYGetBool(@"DYYYHideEntry")) {
        for (UIView *subview in self.subviews) {
            subview.hidden = YES;
        }
        return;
    }

    NSString *scaleValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYNicknameScale"];
    CGFloat scale = scaleValue.length > 0 ? [scaleValue floatValue] : 1.0;
    if (scale > 0 && scale != 1.0) {
        self.transform = CGAffineTransformMakeScale(scale, scale);
    } else {
        self.transform = CGAffineTransformIdentity;
    }
}

%end

%hook AWEAwemeDetailTableView

- (void)setFrame:(CGRect)frame {
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;

        CGFloat remainder = fmod(frame.size.height, screenHeight);
        if (remainder != 0) {
            frame.size.height += (screenHeight - remainder);
        }
    }
    %orig(frame);
}

%end

%hook AWEMixVideoPanelMoreView

- (void)setFrame:(CGRect)frame {
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        CGFloat targetY = frame.origin.y - gCurrentTabBarHeight;
        CGFloat screenHeightMinusGDiff = [UIScreen mainScreen].bounds.size.height - gCurrentTabBarHeight;

        CGFloat tolerance = 10.0;

        if (fabs(targetY - screenHeightMinusGDiff) <= tolerance) {
            frame.origin.y = targetY;
        }
    }
    %orig(frame);
}

- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        self.backgroundColor = [UIColor clearColor];
    }
}

%end

%hook CommentInputContainerView

- (void)layoutSubviews {
    %orig;
    UIViewController *parentVC = nil;
    if ([self respondsToSelector:@selector(viewController)]) {
        id viewController = [self performSelector:@selector(viewController)];
        if ([viewController respondsToSelector:@selector(parentViewController)]) {
            parentVC = [viewController parentViewController];
        }
    }

    if (parentVC && ([parentVC isKindOfClass:%c(AWEAwemeDetailTableViewController)] || [parentVC isKindOfClass:%c(AWEAwemeDetailCellViewController)])) {
        static char kDYCommentHideCacheKey;
        UIView *target = objc_getAssociatedObject(self, &kDYCommentHideCacheKey);
        if (!target) {
            for (UIView *subview in [self subviews]) {
                if ([subview class] == [UIView class]) {
                    target = subview;
                    objc_setAssociatedObject(self, &kDYCommentHideCacheKey, target, OBJC_ASSOCIATION_ASSIGN);
                    break;
                }
            }
        }
        if (target) {
            target.hidden = ([(UIView *)self frame].size.height == gCurrentTabBarHeight);
        }
    }
}

%end

// 聊天视频底部评论框背景透明
%hook AWEIMFeedBottomQuickEmojiInputBar

- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        UIView *parentView = self.superview;
        while (parentView) {
            if ([NSStringFromClass([parentView class]) isEqualToString:@"UIView"]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                  parentView.backgroundColor = [UIColor clearColor];
                  parentView.layer.backgroundColor = [UIColor clearColor].CGColor;
                  parentView.opaque = NO;
                });
                break;
            }
            parentView = parentView.superview;
        }
    }
}

%end

// 隐藏上次看到
%hook DUXPopover
- (void)layoutSubviews {
    %orig;

    if (!DYYYGetBool(@"DYYYHidePopover")) {
        return;
    }

    id rawContent = nil;
    @try {
        rawContent = [self valueForKey:@"content"];
    } @catch (__unused NSException *e) {
        return;
    }

    NSString *text = [rawContent isKindOfClass:NSString.class] ? (NSString *)rawContent : [rawContent description];

    if ([text containsString:@"上次看到"]) {
        self.hidden = YES;
        return;
    }
}
%end

%hook _TtC21AWEIncentiveSwiftImpl29IncentivePendantContainerView
- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHidePendantGroup")) {
        [self removeFromSuperview];
    }
}
%end

%hook UIImageView
- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHideCommentDiscover")) {
        if (!self.accessibilityLabel) {
            UIView *parentView = self.superview;

            if (parentView && [parentView class] == [UIView class] && [parentView.accessibilityLabel isEqualToString:@"搜索"]) {
                self.hidden = YES;
            }

            else if (parentView && [NSStringFromClass([parentView class]) isEqualToString:@"AWESearchEntryHalfScreenElement"] && [parentView.accessibilityLabel isEqualToString:@"搜索"]) {
                self.hidden = YES;
            }
        }
    }
    return;
}
%end

// 移除极速版我的片面红包横幅
%hook AWELuckyCatBannerView
- (id)initWithFrame:(CGRect)frame {
    return nil;
}

- (id)init {
    return nil;
}
%end

static NSString *const kHideRecentAppsKey = @"DYYYHideSidebarRecentApps";
static NSString *const kHideRecentUsersKey = @"DYYYHideSidebarRecentUsers";

%hook AWELeftSideBarModel

- (NSArray *)moduleModels {
    NSArray *originalModels = %orig;

    BOOL shouldHideRecentApps = DYYYGetBool(kHideRecentAppsKey);
    BOOL shouldHideRecentUsers = DYYYGetBool(kHideRecentUsersKey);

    if (!shouldHideRecentApps && !shouldHideRecentUsers) {
        return originalModels;
    }

    NSMutableArray *filteredModels = [NSMutableArray arrayWithCapacity:originalModels.count];

    for (id moduleModel in originalModels) {
        if ([moduleModel respondsToSelector:@selector(moduleID)]) {
            NSString *moduleID = [moduleModel moduleID];

            if (shouldHideRecentApps && [moduleID isEqualToString:@"recently_apps_module"]) {
                continue;
            }

            if (shouldHideRecentUsers && [moduleID isEqualToString:@"recently_users_module"]) {
                continue;
            }
        }

        id filteredModule = [self filterModuleItems:moduleModel];
        if (filteredModule) {
            [filteredModels addObject:filteredModule];
        }
    }

    return [filteredModels copy];
}

%new
- (id)filterModuleItems:(id)moduleModel {
    if (![moduleModel respondsToSelector:@selector(items)] || ![moduleModel respondsToSelector:@selector(moduleID)]) {
        return moduleModel;
    }

    NSString *moduleID = [moduleModel moduleID];
    NSArray *originalItems = [moduleModel items];

    if ([moduleID isEqualToString:@"top_area"]) {
        // 只保留天气、设置、扫一扫
        NSMutableArray *filteredItems = [NSMutableArray array];

        for (id item in originalItems) {
            if ([item respondsToSelector:@selector(businessType)]) {
                NSString *businessType = [item businessType];

                // 保留需要的组件
                if ([businessType isEqualToString:@"weather_time_tip_component"] || [businessType isEqualToString:@"setting_page_component"] ||
                    [businessType isEqualToString:@"top_area_vertical_cell"]) {
                    [filteredItems addObject:item];
                }
            }
        }

        // 创建新的模块对象，保持原有属性但更新items
        if ([moduleModel respondsToSelector:@selector(copy)]) {
            id newModule = [moduleModel copy];
            if ([newModule respondsToSelector:@selector(setItems:)]) {
                [newModule setItems:[filteredItems copy]];
            }
            return newModule;
        }
    }

    return moduleModel;
}

%end

@interface UIDropShadowView : UIView
@end

// 修复 ios26 模态透明效果
// %hook UIDropShadowView

// - (void)didMoveToSuperview {
//     %orig;

//     if (@available(iOS 26.0, *)) {
//         self.backgroundColor = UIColor.clearColor;
//         self.opaque = NO;
//     }
// }

// - (void)layoutSubviews {
//     %orig;

//     if (@available(iOS 26.0, *)) {
//         self.backgroundColor = UIColor.clearColor;
//         self.opaque = NO;
//     }
// }

// - (void)setBackgroundColor:(UIColor *)color {
//     if (@available(iOS 26.0, *)) {
//         %orig(UIColor.clearColor);
//         return;
//     }
//     %orig;
// }

// %end

%hook AFDViewedBottomView
- (void)layoutSubviews {
    %orig;

    if (DYYYGetBool(@"DYYYEnableFullScreen")) {

        self.backgroundColor = [UIColor clearColor];

        self.effectView.hidden = YES;
    }
}
%end

// 极速版红包激励挂件容器视图类组（移除逻辑）
%group IncentivePendantGroup
%hook AWEIncentiveSwiftImplDOUYINLite_IncentivePendantContainerView
- (void)layoutSubviews {
    %orig;
    if (DYYYGetBool(@"DYYYHidePendantGroup")) {
        [self removeFromSuperview];
    }
}
%end
%end

// View scaling fix when comment blur is enabled
%group BDMultiContentImageViewGroup
%hook BDMultiContentContainer_ImageContentView

- (void)setTransform:(CGAffineTransform)transform {
    if (DYYYGetBool(@"DYYYEnableCommentBlur")) {
        return;
    }
    %orig(transform);
}

%end
%end

%hook AWEStoryContainerCollectionView

- (void)setFrame:(CGRect)frame {
    if (DYYYGetBool(@"DYYYEnableCommentBlur")) {
        if (frame.origin.y != 0) {
            return;
        }
    }
    %orig(frame);
}

%end

%hook AWEDPlayerProgressContainerView

- (void)layoutSubviews {
    %orig;

    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYEnableFullScreen"]) {
        return;
    }

    for (UIView *subview in self.subviews) {
        if ([subview isMemberOfClass:[UIView class]]) {
            UIColor *bgColor = subview.backgroundColor;
            if (bgColor) {
                CGFloat h, s, v, a;
                if ([bgColor getHue:&h saturation:&s brightness:&v alpha:&a]) {
                    if (v < 0.2) {
                        subview.backgroundColor = [UIColor clearColor];
                    }
                }
            }
        }
    }
}

%end


// 隐藏键盘 AI
static __weak UIView *cachedHideView = nil;
static void hideParentViewsSubviews(UIView *view) {
    if (!view)
        return;
    UIView *parentView = [view superview];
    if (!parentView)
        return;
    UIView *grandParentView = [parentView superview];
    if (!grandParentView)
        return;
    UIView *greatGrandParentView = [grandParentView superview];
    if (!greatGrandParentView)
        return;
    cachedHideView = greatGrandParentView;
    for (UIView *subview in greatGrandParentView.subviews) {
        subview.hidden = YES;
    }
}

// 递归查找目标视图
static void findTargetViewInView(UIView *view) {
    if (cachedHideView)
        return;
    if ([view isKindOfClass:NSClassFromString(@"AWESearchKeyboardVoiceSearchEntranceView")]) {
        hideParentViewsSubviews(view);
        return;
    }
    for (UIView *subview in view.subviews) {
        findTargetViewInView(subview);
        if (cachedHideView)
            break;
    }
}


// ===== 直播开播时长（从 Wtrwx DYYY 移植，开关 DYYYShowLiveDuration） =====
// 样式：黑色半透明小条“已开播 HH:MM:SS”，可拖动、长按锁定/解锁位置，位置按中心百分比存 NSUserDefaults。
// 依赖仅 DYYYGetBool / DYYYUtils（showToast、firstAvailableViewControllerFromView），2.2-9 源码中均已存在。
static const void *kDYYYLiveDurationViewKey = &kDYYYLiveDurationViewKey;
static const void *kDYYYLiveDurationTimerKey = &kDYYYLiveDurationTimerKey;
static const void *kDYYYLiveDurationRoomKey = &kDYYYLiveDurationRoomKey;
static const void *kDYYYLiveDurationGestureClearKey = &kDYYYLiveDurationGestureClearKey;
static const void *kDYYYLiveDurationGestureHandlerKey = &kDYYYLiveDurationGestureHandlerKey;
static NSString *const kDYYYLiveDurationCenterXPercentKey = @"DYYYLiveDurationCenterXPercent";
static NSString *const kDYYYLiveDurationCenterYPercentKey = @"DYYYLiveDurationCenterYPercent";
// 2.2-9-57：DY778 LiveClock 横屏/竖屏分别记忆位置；DYYY 原来只存一对中心百分比，
// 横屏时会用竖屏存的位置。横屏另存一对键，竖屏继续用上面两个旧键（老用户已存的
// 位置不丢）；恢复默认位置时四个键一起清。
static NSString *const kDYYYLiveDurationLandscapeCenterXPercentKey = @"DYYYLiveDurationLandscapeCenterXPercent";
static NSString *const kDYYYLiveDurationLandscapeCenterYPercentKey = @"DYYYLiveDurationLandscapeCenterYPercent";
static NSString *const kDYYYLiveDurationPositionLockedKey = @"DYYYLiveDurationPositionLocked";

// 2.2-9-56 直播间浮层样式调节（DY778 直播信息移植，用户 2026-11-11 点名全套按截图做）：
// 只给现有 DYYYLiveDurationView 加字号/文字色/背景色/不透明度，不另做一套胶囊。
// 键：DYYYLiveDurationFontSize（11–19，默认 13，与 DY778 默认一致；-56 误写成 12，
// 2.2-9-57 改回）、DYYYLiveDurationTextColor（十六进制或中文名，
// 空 = 白色 FFFFFF）、DYYYLiveDurationBackgroundColor（空 = 黑色）、DYYYLiveDurationOpacity
// （0.15–1，默认 0.64，与 DY778 默认一致；旧代码写死 0.42，改后略深一点）。
static UIColor *DYYYLiveDurationColorFromHexString(NSString *raw, UIColor *fallback) {
    NSString *hex = raw ? [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
    if (hex.length == 0) {
        return fallback;
    }
    if ([hex hasPrefix:@"#"]) {
        hex = [hex substringFromIndex:1];
    }
    NSDictionary *names = @{@"白色":@"FFFFFF", @"黑色":@"000000", @"黄色":@"FFD84D", @"粉色":@"FF8FB3", @"浅蓝":@"8FD0FF", @"红色":@"FF3B30", @"绿色":@"34C759"};
    NSString *mapped = names[hex];
    if (mapped) {
        hex = mapped;
    }
    if (hex.length == 6) {
        unsigned int rgb = 0;
        NSScanner *scanner = [NSScanner scannerWithString:hex];
        if ([scanner scanHexInt:&rgb]) {
            return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0 green:((rgb >> 8) & 0xFF) / 255.0 blue:(rgb & 0xFF) / 255.0 alpha:1.0];
        }
    }
    return fallback;
}

static CGFloat DYYYLiveDurationStyleFontSize(void) {
    double value = [DYYYGetString(@"DYYYLiveDurationFontSize") doubleValue];
    if (value <= 0) {
        return 13.0;
    }
    return (CGFloat)fmin(19, fmax(11, value));
}

static CGFloat DYYYLiveDurationStyleOpacity(void) {
    double value = [DYYYGetString(@"DYYYLiveDurationOpacity") doubleValue];
    if (value <= 0) {
        return 0.64;
    }
    return (CGFloat)fmin(1, fmax(0.15, value));
}

static UIEdgeInsets DYYYLiveDurationSafeInsets(UIView *root) {
    return [root respondsToSelector:@selector(safeAreaInsets)] ? root.safeAreaInsets : UIEdgeInsetsZero;
}

static CGPoint DYYYLiveDurationClampedCenter(CGPoint center, CGSize viewSize, UIView *root) {
    if (!root) {
        return center;
    }

    UIEdgeInsets safeInsets = DYYYLiveDurationSafeInsets(root);
    CGFloat halfWidth = viewSize.width / 2.0;
    CGFloat halfHeight = viewSize.height / 2.0;
    CGFloat minX = safeInsets.left + halfWidth + 4.0;
    CGFloat maxX = fmax(minX, CGRectGetWidth(root.bounds) - safeInsets.right - halfWidth - 4.0);
    CGFloat minY = safeInsets.top + halfHeight + 4.0;
    CGFloat maxY = fmax(minY, CGRectGetHeight(root.bounds) - safeInsets.bottom - halfHeight - 4.0);
    return CGPointMake(fmin(fmax(center.x, minX), maxX), fmin(fmax(center.y, minY), maxY));
}

@interface DYYYLiveDurationWeakViewBox : NSObject
@property(nonatomic, weak) UIView *view;
@end

@implementation DYYYLiveDurationWeakViewBox
@end

@interface DYYYLiveDurationView : UIView
@property(nonatomic, strong) UILabel *durationLabel;
@property(nonatomic, assign, getter=isDragging) BOOL dragging;
@property(nonatomic, assign, getter=isMovementLocked) BOOL movementLocked;
- (CGRect)frameByApplyingSavedPositionToFrame:(CGRect)frame inRoot:(UIView *)root;
@end

@implementation DYYYLiveDurationView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = YES;
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.42];
        self.layer.cornerRadius = 7.0;
        self.layer.masksToBounds = YES;
        self.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12].CGColor;
        self.layer.borderWidth = 0.5;
        self.accessibilityIdentifier = @"dyyy_live_duration_view";

        _durationLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _durationLabel.textColor = [UIColor whiteColor];
        // 2.2-9-57：DY778 直播间浮层字号默认 13、字重 Medium；-56 沿用 DYYY 旧的 12/Semibold。
        _durationLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
        _durationLabel.textAlignment = NSTextAlignmentCenter;
        _durationLabel.adjustsFontSizeToFitWidth = YES;
        _durationLabel.minimumScaleFactor = 0.75;
        _durationLabel.shadowColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
        _durationLabel.shadowOffset = CGSizeMake(0.0, 1.0);
        [self addSubview:_durationLabel];

        _movementLocked = [[NSUserDefaults standardUserDefaults] boolForKey:kDYYYLiveDurationPositionLockedKey];

        UILongPressGestureRecognizer *longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        longPressGesture.minimumPressDuration = 0.5;
        [self addGestureRecognizer:longPressGesture];

        UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [panGesture requireGestureRecognizerToFail:longPressGesture];
        [self addGestureRecognizer:panGesture];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.durationLabel.frame = CGRectInset(self.bounds, 7.0, 2.0);
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    UIView *root = self.superview;
    if (self.isMovementLocked || !root) {
        return;
    }

    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.dragging = YES;
        self.alpha = 0.8;
    }

    if (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [gesture translationInView:root];
        CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
        self.center = DYYYLiveDurationClampedCenter(newCenter, self.bounds.size, root);
        [gesture setTranslation:CGPointZero inView:root];
    }

    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled || gesture.state == UIGestureRecognizerStateFailed) {
        self.dragging = NO;
        self.alpha = 1.0;
        [self savePosition];
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) {
        return;
    }

    self.movementLocked = !self.isMovementLocked;
    [[NSUserDefaults standardUserDefaults] setBool:self.isMovementLocked forKey:kDYYYLiveDurationPositionLockedKey];
    if (self.isMovementLocked) {
        [self savePosition];
    }

    [DYYYUtils showToast:self.isMovementLocked ? @"开播时长位置已锁定" : @"开播时长位置已解锁"];
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [generator prepare];
        [generator impactOccurred];
    }
}

// 2.2-9-57：横竖屏分别记位置（DY778 LiveClock 做法）。竖屏用旧的两个键，老用户
// 已存的位置不丢；横屏用新加的两个键。
- (NSString *)DYYYLiveDurationCenterXPercentKeyForRoot:(UIView *)root {
    return CGRectGetWidth(root.bounds) > CGRectGetHeight(root.bounds)
        ? kDYYYLiveDurationLandscapeCenterXPercentKey : kDYYYLiveDurationCenterXPercentKey;
}

- (NSString *)DYYYLiveDurationCenterYPercentKeyForRoot:(UIView *)root {
    return CGRectGetWidth(root.bounds) > CGRectGetHeight(root.bounds)
        ? kDYYYLiveDurationLandscapeCenterYPercentKey : kDYYYLiveDurationCenterYPercentKey;
}

- (void)savePosition {
    UIView *root = self.superview;
    if (!root) {
        return;
    }

    CGFloat rootWidth = CGRectGetWidth(root.bounds);
    CGFloat rootHeight = CGRectGetHeight(root.bounds);
    if (rootWidth <= 0.0 || rootHeight <= 0.0) {
        return;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setDouble:self.center.x / rootWidth forKey:[self DYYYLiveDurationCenterXPercentKeyForRoot:root]];
    [defaults setDouble:self.center.y / rootHeight forKey:[self DYYYLiveDurationCenterYPercentKeyForRoot:root]];
}

- (CGRect)frameByApplyingSavedPositionToFrame:(CGRect)frame inRoot:(UIView *)root {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *xKey = [self DYYYLiveDurationCenterXPercentKeyForRoot:root];
    NSString *yKey = [self DYYYLiveDurationCenterYPercentKeyForRoot:root];
    if (![defaults objectForKey:xKey] || ![defaults objectForKey:yKey]) {
        return frame;
    }

    CGFloat rootWidth = CGRectGetWidth(root.bounds);
    CGFloat rootHeight = CGRectGetHeight(root.bounds);
    if (rootWidth <= 0.0 || rootHeight <= 0.0) {
        return frame;
    }

    CGFloat centerXPercent = fmin(fmax([defaults doubleForKey:xKey], 0.0), 1.0);
    CGFloat centerYPercent = fmin(fmax([defaults doubleForKey:yKey], 0.0), 1.0);
    CGPoint center = CGPointMake(centerXPercent * rootWidth, centerYPercent * rootHeight);
    center = DYYYLiveDurationClampedCenter(center, frame.size, root);
    return CGRectIntegral(CGRectMake(center.x - frame.size.width / 2.0, center.y - frame.size.height / 2.0, frame.size.width, frame.size.height));
}

@end

// 2.2-9-56：把设置里的样式应用到现有时长小条上，每秒计时刷新时调用一次（1Hz，不在热路径）。
static void DYYYLiveDurationApplyStyle(DYYYLiveDurationView *durationView) {
    if (!durationView) {
        return;
    }
    durationView.durationLabel.font = [UIFont systemFontOfSize:DYYYLiveDurationStyleFontSize() weight:UIFontWeightMedium];
    durationView.durationLabel.textColor = DYYYLiveDurationColorFromHexString(DYYYGetString(@"DYYYLiveDurationTextColor"), [UIColor whiteColor]);
    UIColor *background = DYYYLiveDurationColorFromHexString(DYYYGetString(@"DYYYLiveDurationBackgroundColor"), [UIColor blackColor]);
    durationView.backgroundColor = [background colorWithAlphaComponent:DYYYLiveDurationStyleOpacity()];
}

static id DYYYLiveDurationSafeValue(id obj, NSString *key) {
    if (!obj || key.length == 0) {
        return nil;
    }

    @try {
        return [obj valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static long long DYYYLiveDurationLongValue(id obj, NSString *key) {
    id value = DYYYLiveDurationSafeValue(obj, key);
    return [value respondsToSelector:@selector(longLongValue)] ? [value longLongValue] : 0;
}

static BOOL DYYYLiveDurationBoolValue(id obj, NSString *key) {
    id value = DYYYLiveDurationSafeValue(obj, key);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

static NSTimeInterval DYYYLiveDurationNowSeconds(void) {
    return [[NSDate date] timeIntervalSince1970];
}

static NSTimeInterval DYYYLiveDurationNormalizeTimestamp(long long timestamp) {
    if (timestamp <= 0) {
        return 0.0;
    }
    return timestamp > 20000000000LL ? ((NSTimeInterval)timestamp / 1000.0) : (NSTimeInterval)timestamp;
}

static long long DYYYLiveDurationFirstPositiveValue(id obj, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        long long value = DYYYLiveDurationLongValue(obj, key);
        if (value > 0) {
            return value;
        }
    }
    return 0;
}

static BOOL DYYYLiveDurationLooksLikeRoomObject(id obj) {
    if (!obj) {
        return NO;
    }

    NSString *className = NSStringFromClass([obj class]);
    NSArray<NSString *> *excludedParts = @[ @"Cell", @"Item", @"Aisle", @"Context", @"Config", @"Controller", @"View", @"Factory" ];
    for (NSString *part in excludedParts) {
        if ([className rangeOfString:part options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return NO;
        }
    }

    if ([className rangeOfString:@"LiveRoom" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [className rangeOfString:@"RoomModel" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [className rangeOfString:@"WebcastRoom" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
    }

    return DYYYLiveDurationSafeValue(obj, @"roomID") || DYYYLiveDurationSafeValue(obj, @"idStr");
}

static NSTimeInterval DYYYLiveDurationElapsedSeconds(id roomModel) {
    if (!DYYYLiveDurationLooksLikeRoomObject(roomModel)) {
        return -1.0;
    }

    id rawRoom = DYYYLiveDurationSafeValue(roomModel, @"rawRoom") ?: roomModel;
    NSArray<NSString *> *startKeys = @[ @"startTime", @"createTime", @"liveStartTime", @"start_time", @"create_time" ];
    long long startTime = DYYYLiveDurationFirstPositiveValue(rawRoom, startKeys);
    if (startTime <= 0) {
        startTime = DYYYLiveDurationFirstPositiveValue(roomModel, startKeys);
    }

    NSTimeInterval timestamp = DYYYLiveDurationNormalizeTimestamp(startTime);
    NSTimeInterval now = DYYYLiveDurationNowSeconds();
    if (timestamp > 1000000000.0 && timestamp <= now + 3600.0) {
        return fmax(0.0, now - timestamp);
    }

    NSArray<NSString *> *durationKeys = @[ @"liveDuration", @"liveTime", @"duration", @"totalDuration" ];
    long long duration = DYYYLiveDurationFirstPositiveValue(rawRoom, durationKeys);
    if (duration <= 0) {
        duration = DYYYLiveDurationFirstPositiveValue(roomModel, durationKeys);
    }
    if (duration > 0 && duration < 365LL * 24LL * 3600LL) {
        return (NSTimeInterval)duration;
    }

    return -1.0;
}

static BOOL DYYYLiveDurationHasValidLiveTime(id obj) {
    return DYYYLiveDurationElapsedSeconds(obj) >= 0.0;
}

static id DYYYLiveDurationRoomFromCarrierDepth(id obj, NSUInteger depth);

static id DYYYLiveDurationRoomFromKnownKeys(id obj, NSUInteger depth) {
    if (!obj || depth > 3) {
        return nil;
    }

    NSArray<NSString *> *keys = @[
        @"rawHTSLiveRoomModel", @"rawDataRoomModel", @"roomModel", @"rawRoom", @"liveRoom", @"room", @"currentRoom",
        @"containerContext", @"roomDI", @"roomConfig", @"roomAisle"
    ];
    for (NSString *key in keys) {
        id value = DYYYLiveDurationSafeValue(obj, key);
        if (DYYYLiveDurationHasValidLiveTime(value)) {
            return value;
        }

        id nestedRawRoom = DYYYLiveDurationSafeValue(value, @"rawRoom");
        if (DYYYLiveDurationHasValidLiveTime(nestedRawRoom)) {
            return value;
        }

        id nestedRoom = DYYYLiveDurationRoomFromCarrierDepth(value, depth + 1);
        if (nestedRoom) {
            return nestedRoom;
        }
    }
    return nil;
}

static id DYYYLiveDurationRoomFromCarrierDepth(id obj, NSUInteger depth) {
    if (!obj || depth > 3) {
        return nil;
    }

    if (DYYYLiveDurationHasValidLiveTime(obj)) {
        return obj;
    }

    id room = DYYYLiveDurationRoomFromKnownKeys(obj, depth + 1);
    if (room) {
        return room;
    }

    if ([obj respondsToSelector:@selector(liveRoomModel)]) {
        @try {
            id value = ((id (*)(id, SEL))objc_msgSend)(obj, @selector(liveRoomModel));
            if (DYYYLiveDurationHasValidLiveTime(value)) {
                return value;
            }
        } @catch (__unused NSException *exception) {
        }
    }

    NSArray<NSString *> *carrierKeys = @[ @"itemModel", @"awemeModel", @"aweme", @"model", @"item" ];
    for (NSString *key in carrierKeys) {
        id carrier = DYYYLiveDurationSafeValue(obj, key);
        room = DYYYLiveDurationRoomFromCarrierDepth(carrier, depth + 1);
        if (room) {
            return room;
        }
    }

    return nil;
}

static id DYYYLiveDurationRoomFromCarrier(id obj) {
    return DYYYLiveDurationRoomFromCarrierDepth(obj, 0);
}

static NSString *DYYYLiveDurationFormatElapsed(NSTimeInterval seconds) {
    long long totalSeconds = (long long)fmax(0.0, floor(seconds));
    long long days = totalSeconds / 86400;
    long long hours = (totalSeconds % 86400) / 3600;
    long long minutes = (totalSeconds % 3600) / 60;
    long long secs = totalSeconds % 60;

    if (days > 0) {
        return [NSString stringWithFormat:@"已开播 %lld天%02lld:%02lld:%02lld", days, hours, minutes, secs];
    }
    return [NSString stringWithFormat:@"已开播 %02lld:%02lld:%02lld", hours, minutes, secs];
}

static DYYYLiveDurationView *DYYYLiveDurationEnsureView(UIView *root) {
    DYYYLiveDurationView *durationView = objc_getAssociatedObject(root, kDYYYLiveDurationViewKey);
    if (durationView && durationView.superview == root) {
        return durationView;
    }

    durationView = [[DYYYLiveDurationView alloc] initWithFrame:CGRectZero];
    objc_setAssociatedObject(root, kDYYYLiveDurationViewKey, durationView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [root addSubview:durationView];
    return durationView;
}

static CGRect DYYYLiveDurationFrameForRoot(UIView *root, id roomModel, NSString *text) {
    UIEdgeInsets safeInsets = DYYYLiveDurationSafeInsets(root);

    CGFloat rootWidth = CGRectGetWidth(root.bounds);
    CGFloat rootHeight = CGRectGetHeight(root.bounds);
    BOOL isLandscape = rootWidth > rootHeight || DYYYLiveDurationBoolValue(roomModel, @"isLandscape");
    if (!isLandscape) {
        long long orientation = DYYYLiveDurationLongValue(roomModel, @"orientation");
        isLandscape = orientation == 2 || orientation == 90 || orientation == 270;
    }

    UIFont *font = [UIFont systemFontOfSize:DYYYLiveDurationStyleFontSize() weight:UIFontWeightSemibold];
    CGSize textSize = [text ?: @"已开播 00:00:00" sizeWithAttributes:@{NSFontAttributeName : font}];
    CGFloat width = fmin(ceil(fmax(textSize.width + 18.0, 118.0)), isLandscape ? 190.0 : 170.0);
    CGFloat height = 26.0;

    CGFloat minX = safeInsets.left + 4.0;
    CGFloat maxX = fmax(minX, rootWidth - safeInsets.right - width - 4.0);
    CGFloat minY = safeInsets.top + 4.0;
    CGFloat maxY = fmax(minY, rootHeight - safeInsets.bottom - height - 4.0);

    CGFloat x = fmin(fmax(safeInsets.left + 12.0, minX), maxX);
    CGFloat y = fmin(fmax(safeInsets.top + (isLandscape ? 12.0 : 86.0), minY), maxY);
    return CGRectIntegral(CGRectMake(x, y, width, height));
}

static void DYYYLiveDurationRemoveFromView(UIView *root) {
    if (!root) {
        return;
    }

    NSTimer *timer = objc_getAssociatedObject(root, kDYYYLiveDurationTimerKey);
    [timer invalidate];
    objc_setAssociatedObject(root, kDYYYLiveDurationTimerKey, nil, OBJC_ASSOCIATION_ASSIGN);

    UIView *durationView = objc_getAssociatedObject(root, kDYYYLiveDurationViewKey);
    [durationView removeFromSuperview];
    objc_setAssociatedObject(root, kDYYYLiveDurationViewKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(root, kDYYYLiveDurationRoomKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(root, kDYYYLiveDurationGestureClearKey, @(NO), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// 2.2-9-108: 人气榜“房内主播”提示用——返回挂在该房间 root 上的房间 model
//（时长胶囊 InstallOnView 解析出来的同一个对象，起点与胶囊的“已开播”
// 数字同源；开关关着或房间已关时 RemoveFromView 已清掉，返回 nil）。
// 声明在 DYYYLiveBoardModel.h（extern "C"）；DYYY.xm 是 ObjC++，定义处
// 显式包 extern "C"，保证与 .m 调用方的 C 链接一致（-69 教训）。
extern "C" id DYYYLiveDurationRoomModelForRootView(UIView *root) {
    if (!root) return nil;
    return objc_getAssociatedObject(root, kDYYYLiveDurationRoomKey);
}

// 抖音原生直播清屏检测（2.2-9-10 新增）：直播间向右滑进入的原生清屏
// 不经过 DYYY 一键清屏按钮（hideButton），所以 2.2-9-9 的修复覆盖不到它。
// 检测分两步，任一步命中即判定为清屏，全部用 @try 兜底，绝不因检测本身闪退：
// 1) 向观众 VC 安全取清屏类 key（isClearScreen/clearMode/isInClearMode 等，取不到就跳过）；
// 2) 启发式：遍历 root 视图树（跳过时长小条自身、视频播放类视图、DYYY 悬浮按钮），
//    若一个可见的抖音 UI 视图都没有（hidden=NO 且 alpha>0.01 且尺寸>=40x20），即判定清屏。
//    正常直播间一定有顶部栏/底部输入栏等可见 UI，清屏时这些全被藏起，计数为 0。
//    正常模式下找到第一个可见 UI 就提前返回，遍历成本低；清屏时才全量遍历，1 秒一次可接受。
static BOOL DYYYLiveDurationViewIsVideoPlayerView(UIView *view) {
    NSString *cls = NSStringFromClass([view class]);
    return ([cls containsString:@"Player"] || [cls containsString:@"Metal"] ||
            [cls containsString:@"Render"] || [cls containsString:@"VideoView"] ||
            [cls containsString:@"Canvas"] || [cls containsString:@"Texture"]);
}

static BOOL DYYYLiveDurationViewIsDYYYFloatView(UIView *view) {
    NSString *cls = NSStringFromClass([view class]);
    return ([cls containsString:@"HideUI"] || [cls containsString:@"Floating"] ||
            [cls containsString:@"SpeedButton"] || [cls containsString:@"ClearButton"]);
}

static BOOL DYYYLiveDurationHasVisibleUI(UIView *view, NSInteger depth, UIView *durationView, UIView *root) {
    if (!view || depth > 6 || !root) {
        return NO;
    }
    CGFloat rootW = root.bounds.size.width;
    CGFloat rootH = root.bounds.size.height;
    if (rootW <= 0 || rootH <= 0) {
        return NO;
    }
    for (UIView *sub in view.subviews) {
        if (!sub || sub == durationView) {
            continue;
        }
        if (durationView && [sub isDescendantOfView:durationView]) {
            continue;
        }
        // 关键：父视图被藏起时整个子树都不可见，绝不能往里递归，否则清屏时
        // 容器 hidden=YES 但子视图 hidden=NO 会被误判为“有 UI”，时长就藏不住。
        if (sub.hidden || sub.alpha <= 0.01) {
            continue;
        }
        // 2.2-9-12 修正（用户实测 2.2-9-10/11 右滑清屏仍不藏时长，悬浮清屏却能藏）：
        // 上一版往视频层和 DYYY 悬浮按钮里递归，把悬浮按钮的图标、视频层的子视图
        // 也算成了“可见 UI”，清屏时悬浮按钮本身仍可见，于是永远误判为“未清屏”。
        // 现在视频层和 DYYY 悬浮按钮整个子树直接跳过，不计数也不递归——抖音 UI
        // 容器是它们的兄弟视图，不在它们里面，跳过是安全的。
        if (DYYYLiveDurationViewIsVideoPlayerView(sub) || DYYYLiveDurationViewIsDYYYFloatView(sub)) {
            continue;
        }
        // 只把顶部/底部/右侧的非全宽元素算作抖音 UI：
        // 2.2-9-13 修正（用户实测 2.2-9-12 右滑清屏仍不藏）：上一版把全宽条
        // （顶部/底部渐变罩、顶栏容器等）本身也算作 UI，而渐变罩在清屏时仍可见，
        // 于是永远误判为“未清屏”。现在全宽条本身不算，只往里递归看子视图
        // （顶栏的子视图头像/名字在清屏时会被藏，渐变罩本身是叶子、递归无结果）；
        // 同时要求换算后的框必须与屏幕相交，否则被移出屏幕的 UI 也不算 UI；
        // 中央区域的视频/点赞动画等不算，避免清屏时残留的中央视图误判。
        if (sub.frame.size.width >= 40 && sub.frame.size.height >= 20) {
            CGRect converted = [sub convertRect:sub.bounds toView:root];
            BOOL intersectsRoot = (converted.origin.x + converted.size.width > 20 && converted.origin.x < rootW - 20 &&
                                   converted.origin.y + converted.size.height > 20 && converted.origin.y < rootH - 20);
            BOOL isFullWidthContainer = (converted.size.width >= rootW * 0.95);
            if (intersectsRoot && !isFullWidthContainer) {
                CGFloat cx = converted.origin.x + converted.size.width * 0.5;
                CGFloat cy = converted.origin.y + converted.size.height * 0.5;
                BOOL inTop = (cy >= 0 && cy < rootH * 0.30);
                BOOL inBottom = (cy <= rootH && cy > rootH * 0.65);
                BOOL inRight = (cx >= 0 && cx <= rootW && cx > rootW * 0.75 && cy > rootH * 0.2 && cy < rootH * 0.85);
                if (inTop || inBottom || inRight) {
                    return YES;
                }
            }
        }
        if (DYYYLiveDurationHasVisibleUI(sub, depth + 1, durationView, root)) {
            return YES;
        }
    }
    return NO;
}

static BOOL DYYYLiveDurationIsNativeClear(UIView *root) {
    if (!root || !root.window) {
        return NO;
    }
    // 1) 安全取 key
    UIViewController *vc = [DYYYUtils firstAvailableViewControllerFromView:root];
    NSArray *keys = @[@"isClearScreen", @"clearScreen", @"isInClearMode", @"clearMode", @"isClearMode", @"isUIHidden", @"uiHidden"];
    for (NSString *key in keys) {
        @try {
            id v = vc ? [vc valueForKey:key] : nil;
            if ([v isKindOfClass:[NSNumber class]] && [v boolValue]) {
                return YES;
            }
        } @catch (__unused NSException *e) {
        }
    }
    @try {
        id v = [DYYYUtils firstAvailableViewControllerFromView:root];
        // isUIVisible 为 NO 时也视为清屏（取不到则跳过）
        id visible = v ? [v valueForKey:@"isUIVisible"] : nil;
        if ([visible isKindOfClass:[NSNumber class]] && ![visible boolValue]) {
            // 仅当 root 已有一定加载时间才采信，避免开播瞬间 UI 未加载就误判；
            // 此处不单独返回，交给下面的启发式兜底，避免误杀。
            (void)visible;
        }
    } @catch (__unused NSException *e) {
    }
    // 2) 启发式：无可见抖音 UI 即清屏
    UIView *durationView = objc_getAssociatedObject(root, kDYYYLiveDurationViewKey);
    return !DYYYLiveDurationHasVisibleUI(root, 0, durationView, root);
}

static void DYYYLiveDurationUpdateView(UIView *root) {
    if (!root) {
        return;
    }

    if (!DYYYGetBool(@"DYYYShowLiveDuration")) {
        DYYYLiveDurationRemoveFromView(root);
        return;
    }

    // 清屏隐藏时长小条（2.2-9-9 新增 DYYY 一键清屏；2.2-9-10 补抖音原生清屏）：
    // 复用 DYYY 一键清屏状态 hideButton.isElementsHidden；计时器每秒跑 UpdateView，
    // 清屏时隐藏、退出清屏时恢复，不移除视图、不停计时器，不动拖动/锁定/位置存档。
    if (hideButton && hideButton.isElementsHidden) {
        DYYYLiveDurationView *clearHiddenView = objc_getAssociatedObject(root, kDYYYLiveDurationViewKey);
        if (clearHiddenView) {
            clearHiddenView.hidden = YES;
        }
        return;
    }

    // 手势清屏（2.2-9-14）：向右滑进清屏时手势已把标志置 YES，此处直接藏，
    // 不依赖启发式；向左滑/点屏幕退出时手势会把标志清掉，下一秒自动恢复。
    {
        NSNumber *gestureClear = objc_getAssociatedObject(root, kDYYYLiveDurationGestureClearKey);
        if (gestureClear && gestureClear.boolValue) {
            UIView *gestureHiddenView = objc_getAssociatedObject(root, kDYYYLiveDurationViewKey);
            if (gestureHiddenView) {
                gestureHiddenView.hidden = YES;
            }
            return;
        }
    }

    // 抖音原生直播清屏（向右滑）：不经过 hideButton，上面那段覆盖不到，单独检测。
    if (DYYYLiveDurationIsNativeClear(root)) {
        DYYYLiveDurationView *nativeClearView = objc_getAssociatedObject(root, kDYYYLiveDurationViewKey);
        if (nativeClearView) {
            nativeClearView.hidden = YES;
        }
        return;
    }

    id roomModel = objc_getAssociatedObject(root, kDYYYLiveDurationRoomKey);
    NSTimeInterval elapsed = DYYYLiveDurationElapsedSeconds(roomModel);
    DYYYLiveDurationView *durationView = objc_getAssociatedObject(root, kDYYYLiveDurationViewKey);
    if (elapsed < 0.0) {
        durationView.hidden = YES;
        return;
    }

    NSString *text = DYYYLiveDurationFormatElapsed(elapsed);
    durationView = DYYYLiveDurationEnsureView(root);
    DYYYLiveDurationApplyStyle(durationView);
    durationView.durationLabel.text = text;
    if (!durationView.isDragging) {
        CGRect defaultFrame = DYYYLiveDurationFrameForRoot(root, roomModel, text);
        durationView.frame = [durationView frameByApplyingSavedPositionToFrame:defaultFrame inRoot:root];
        durationView.alpha = 1.0;
    }
    durationView.hidden = NO;
    [root bringSubviewToFront:durationView];
}

@interface DYYYLiveDurationTicker : NSObject
+ (instancetype)sharedTicker;
- (void)tick:(NSTimer *)timer;
@end

@implementation DYYYLiveDurationTicker

+ (instancetype)sharedTicker {
    static DYYYLiveDurationTicker *ticker = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      ticker = [DYYYLiveDurationTicker new];
    });
    return ticker;
}

- (void)tick:(NSTimer *)timer {
    DYYYLiveDurationWeakViewBox *box = (DYYYLiveDurationWeakViewBox *)timer.userInfo;
    UIView *root = box.view;
    if (![root isKindOfClass:[UIView class]]) {
        [timer invalidate];
        return;
    }
    if (!root.window) {
        DYYYLiveDurationRemoveFromView(root);
        return;
    }
    DYYYLiveDurationUpdateView(root);
}

@end

static void DYYYLiveDurationEnsureTimer(UIView *root) {
    NSTimer *timer = objc_getAssociatedObject(root, kDYYYLiveDurationTimerKey);
    if (timer && timer.isValid) {
        return;
    }

    DYYYLiveDurationWeakViewBox *box = [DYYYLiveDurationWeakViewBox new];
    box.view = root;
    timer = [NSTimer timerWithTimeInterval:1.0 target:[DYYYLiveDurationTicker sharedTicker] selector:@selector(tick:) userInfo:box repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    objc_setAssociatedObject(root, kDYYYLiveDurationTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// 2.2-9-14 手势清屏（用户实测 2.2-9-13 右滑仍不藏，启发式已用尽）：
// 不再猜 UI 可见性，直接跟用户动作走——向右滑进清屏就藏时长，
// 向左滑或点屏幕退出清屏就恢复。手势只改时长小条显隐，不拦截触摸，
// 不影响抖音自己的清屏/点赞/评论手势（cancelsTouchesInView=NO、允许同时识别），
// 拖时长小条本身的手势会被忽略（触点在时长框内不触发）。
@interface DYYYLiveDurationGestureHandler : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *root;
- (void)handlePan:(UIPanGestureRecognizer *)pan;
- (void)handleTap:(UITapGestureRecognizer *)tap;
@end

@implementation DYYYLiveDurationGestureHandler

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (BOOL)_touchInsideDurationView:(UIGestureRecognizer *)gesture {
    UIView *root = self.root;
    UIView *durationView = root ? objc_getAssociatedObject(root, kDYYYLiveDurationViewKey) : nil;
    if (!root || !durationView || !durationView.superview) {
        return NO;
    }
    CGPoint p = [gesture locationInView:root];
    CGRect f = [durationView.superview convertRect:durationView.frame toView:root];
    return CGRectContainsPoint(CGRectInset(f, -10, -10), p);
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    // 2.2-9-16 修正时好时坏：上一版只在 Ended 且同时满足速度>400、位移>60 才触发，
    // 慢滑、拖到一半停住再松手时 Ended 瞬时速度很低，就漏掉，抖音清屏却已触发，
    // 所以有时行有时不行。现在改为拖动过程中（Changed）位移过阈值就触发，
    // 且位移 alone 或速度+位移任一达标都触发，阈值放宽到慢滑也能进。
    // 只在直播间主视图触发（见 Hook 的范围收窄），其他组件的右滑不进这里。
    if (pan.state != UIGestureRecognizerStateChanged && pan.state != UIGestureRecognizerStateEnded) {
        return;
    }
    if ([self _touchInsideDurationView:pan]) {
        return;
    }
    UIView *root = self.root;
    if (!root) {
        return;
    }
    CGPoint velocity = [pan velocityInView:root];
    CGPoint translation = [pan translationInView:root];
    BOOL swipeRight = (translation.x > 80 || (velocity.x > 300 && translation.x > 30));
    BOOL swipeLeft = (translation.x < -80 || (velocity.x < -300 && translation.x < -30));
    if (swipeRight) {
        // 向右滑：进清屏，立即藏时长，计时不停
        objc_setAssociatedObject(root, kDYYYLiveDurationGestureClearKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIView *durationView = objc_getAssociatedObject(root, kDYYYLiveDurationViewKey);
        if (durationView) {
            durationView.hidden = YES;
        }
    } else if (swipeLeft) {
        // 向左滑：退出清屏，恢复时长（下一秒计时器也会恢复，此处立即恢复更跟手）
        objc_setAssociatedObject(root, kDYYYLiveDurationGestureClearKey, @(NO), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIView *durationView = objc_getAssociatedObject(root, kDYYYLiveDurationViewKey);
        if (durationView && !(hideButton && hideButton.isElementsHidden)) {
            durationView.hidden = NO;
        }
    }
}

- (void)handleTap:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateEnded) {
        return;
    }
    if ([self _touchInsideDurationView:tap]) {
        return;
    }
    UIView *root = self.root;
    if (!root) {
        return;
    }
    NSNumber *gestureClear = objc_getAssociatedObject(root, kDYYYLiveDurationGestureClearKey);
    if (gestureClear && gestureClear.boolValue) {
        // 点屏幕退出清屏：恢复时长
        objc_setAssociatedObject(root, kDYYYLiveDurationGestureClearKey, @(NO), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIView *durationView = objc_getAssociatedObject(root, kDYYYLiveDurationViewKey);
        if (durationView && !(hideButton && hideButton.isElementsHidden)) {
            durationView.hidden = NO;
        }
    }
}

@end

static const void *kDYYYLiveDurationGestureHookedKey = &kDYYYLiveDurationGestureHookedKey;

static void DYYYLiveDurationHookGesturesInView(UIView *view, NSInteger depth, DYYYLiveDurationGestureHandler *handler, UIView *durationView) {
    if (!view || depth > 5 || !handler) {
        return;
    }
    if (durationView && (view == durationView || [view isDescendantOfView:durationView])) {
        return;
    }
    // 2.2-9-16 范围收窄（用户：只在直播间右滑，其他不需要）：
    // 只搭直播间主视图本身和全屏主视图 / 视频层的手势，不搭评论框、礼物面板、
    // 弹窗等小组件的手势——那些右滑不是直播间清屏，不应藏时长。
    if (depth > 0 && handler.root) {
        UIView *rootView = handler.root;
        CGRect converted = [view convertRect:view.bounds toView:rootView];
        BOOL isFullScreen = (converted.size.width >= rootView.bounds.size.width * 0.9 && converted.size.height >= rootView.bounds.size.height * 0.9);
        if (!isFullScreen && !DYYYLiveDurationViewIsVideoPlayerView(view)) {
            return;
        }
    }
    for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
        if (!gesture || objc_getAssociatedObject(gesture, kDYYYLiveDurationGestureHookedKey)) {
            continue;
        }
        // 2.2-9-15 关键：不要只加自己的手势跟抖音抢——抖音视频区自己的右滑手势
        // 会拦截并取消我方手势，所以视频区右滑时我方手势根本触发不了，
        // 只有在时长小条上滑（抖音手势覆盖不到小条）时才生效。
        // 改为直接搭在抖音已有的手势上：同一个手势触发时，我方处理也一起触发，
        // 不存在抢占问题，直播界面任何地方右滑都能藏，左滑/点按都能恢复。
        // 排除时长小条自身的拖动手势（触点在小条内时 handlePan/handleTap 已忽略）。
        if ([gesture isKindOfClass:[UIPanGestureRecognizer class]]) {
            [gesture addTarget:handler action:@selector(handlePan:)];
            objc_setAssociatedObject(gesture, kDYYYLiveDurationGestureHookedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if ([gesture isKindOfClass:[UITapGestureRecognizer class]]) {
            [gesture addTarget:handler action:@selector(handleTap:)];
            objc_setAssociatedObject(gesture, kDYYYLiveDurationGestureHookedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    for (UIView *sub in view.subviews) {
        DYYYLiveDurationHookGesturesInView(sub, depth + 1, handler, durationView);
    }
}

static void DYYYLiveDurationEnsureGestures(UIView *root) {
    if (!root) {
        return;
    }
    DYYYLiveDurationGestureHandler *handler = objc_getAssociatedObject(root, kDYYYLiveDurationGestureHandlerKey);
    if (!handler) {
        handler = [DYYYLiveDurationGestureHandler new];
        handler.root = root;
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:handler action:@selector(handlePan:)];
        pan.delegate = handler;
        pan.cancelsTouchesInView = NO;
        [root addGestureRecognizer:pan];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:handler action:@selector(handleTap:)];
        tap.delegate = handler;
        tap.cancelsTouchesInView = NO;
        [root addGestureRecognizer:tap];
        objc_setAssociatedObject(root, kDYYYLiveDurationGestureHandlerKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // 每次安装都重新扫一遍，抖音后续新加的手势也能搭上，已搭过的用标记跳过不重复加。
    UIView *durationView = objc_getAssociatedObject(root, kDYYYLiveDurationViewKey);
    DYYYLiveDurationHookGesturesInView(root, 0, handler, durationView);
}

static void DYYYLiveDurationInstallOnView(UIView *root, id carrier) {
    if (!root) {
        return;
    }

    void (^installBlock)(void) = ^{
      if (!DYYYGetBool(@"DYYYShowLiveDuration")) {
          DYYYLiveDurationRemoveFromView(root);
          return;
      }

      id room = DYYYLiveDurationRoomFromCarrier(carrier);
      if (!DYYYLiveDurationHasValidLiveTime(room)) {
          UIViewController *viewController = [DYYYUtils firstAvailableViewControllerFromView:root];
          room = DYYYLiveDurationRoomFromCarrier(viewController);
      }

      if (DYYYLiveDurationHasValidLiveTime(room)) {
          objc_setAssociatedObject(root, kDYYYLiveDurationRoomKey, room, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      }

      DYYYLiveDurationEnsureGestures(root);
      DYYYLiveDurationUpdateView(root);
      if (DYYYLiveDurationHasValidLiveTime(objc_getAssociatedObject(root, kDYYYLiveDurationRoomKey))) {
          DYYYLiveDurationEnsureTimer(root);
      }
    };

    if ([NSThread isMainThread]) {
        installBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), installBlock);
    }
}

static UIViewController *DYYYLiveDurationContainerAudienceVC(id container) {
    UIViewController *viewController = DYYYLiveDurationSafeValue(container, @"audienceVC");
    if (![viewController isKindOfClass:[UIViewController class]] && [container respondsToSelector:@selector(audienceViewController)]) {
        @try {
            viewController = ((id (*)(id, SEL))objc_msgSend)(container, @selector(audienceViewController));
        } @catch (__unused NSException *exception) {
            viewController = nil;
        }
    }
    return [viewController isKindOfClass:[UIViewController class]] ? viewController : nil;
}

static void DYYYLiveDurationInstallFromContainer(id container) {
    UIViewController *viewController = DYYYLiveDurationContainerAudienceVC(container);
    if ([viewController isKindOfClass:[UIViewController class]]) {
        DYYYLiveDurationInstallOnView(viewController.view, DYYYLiveDurationSafeValue(container, @"roomModel") ?: container);
    }
}

static void DYYYLiveDurationInstallFromAudienceWrapper(id wrapper) {
    UIViewController *viewController = DYYYLiveDurationSafeValue(wrapper, @"audienceViewController");
    if ([viewController isKindOfClass:[UIViewController class]]) {
        DYYYLiveDurationInstallOnView(viewController.view, DYYYLiveDurationSafeValue(wrapper, @"roomModel") ?: wrapper);
    }
}

static void DYYYLiveDurationInstallFromInnerFeedCell(id cell) {
    UIViewController *viewController = DYYYLiveDurationSafeValue(cell, @"audienceVC");
    if ([viewController isKindOfClass:[UIViewController class]]) {
        DYYYLiveDurationInstallOnView(viewController.view, cell);
    }
}


%hook AWELiveAudienceContainerController

- (id)initWithRoomModel:(id)roomModel {
    id result = %orig;
    __weak id weakResult = result;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      DYYYLiveDurationInstallFromContainer(weakResult);
    });
    return result;
}

- (id)initWithRoomModel:(id)roomModel config:(id)config {
    id result = %orig;
    __weak id weakResult = result;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      DYYYLiveDurationInstallFromContainer(weakResult);
    });
    return result;
}

- (id)initWithRoomModel:(id)roomModel context:(id)context {
    id result = %orig;
    __weak id weakResult = result;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      DYYYLiveDurationInstallFromContainer(weakResult);
    });
    return result;
}

- (id)initWithRoomModel:(id)roomModel context:(id)context player:(id)player {
    id result = %orig;
    __weak id weakResult = result;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      DYYYLiveDurationInstallFromContainer(weakResult);
    });
    return result;
}

- (void)setAudienceVC:(UIViewController *)audienceVC {
    %orig;
    DYYYLiveDurationInstallFromContainer(self);
}

- (void)setRoomModel:(id)roomModel {
    %orig;
    DYYYLiveDurationInstallFromContainer(self);
}

- (void)createAudienceViewController:(id)arg beginTime:(double)beginTime {
    %orig;
    __weak id weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      DYYYLiveDurationInstallFromContainer(weakSelf);
    });
}

- (id)audienceControllerWithRoom:(id)room beginTime:(double)beginTime {
    id result = %orig;
    __weak id weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      DYYYLiveDurationInstallFromContainer(weakSelf);
    });
    return result;
}

- (void)updateWithRoomModel:(id)roomModel config:(id)config {
    %orig;
    DYYYLiveDurationInstallFromContainer(self);
}

- (void)updateWithRoomModel:(id)roomModel context:(id)context {
    %orig;
    DYYYLiveDurationInstallFromContainer(self);
}

- (void)updateWithRoomModel:(id)roomModel context:(id)context player:(id)player {
    %orig;
    DYYYLiveDurationInstallFromContainer(self);
}

- (void)clearAudience {
    UIViewController *viewController = DYYYLiveDurationContainerAudienceVC(self);
    if ([viewController isKindOfClass:[UIViewController class]]) {
        DYYYLiveDurationRemoveFromView(viewController.view);
    }
    %orig;
}

- (void)prepareForReuse {
    UIViewController *viewController = DYYYLiveDurationContainerAudienceVC(self);
    if ([viewController isKindOfClass:[UIViewController class]]) {
        DYYYLiveDurationRemoveFromView(viewController.view);
    }
    %orig;
}

- (void)dealloc {
    UIViewController *viewController = DYYYLiveDurationContainerAudienceVC(self);
    if ([viewController isKindOfClass:[UIViewController class]]) {
        DYYYLiveDurationRemoveFromView(viewController.view);
    }
    %orig;
}

%end

%hook AWELiveAudienceViewController

- (id)initWithRoomModel:(id)roomModel {
    id result = %orig;
    __weak id weakResult = result;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      DYYYLiveDurationInstallFromAudienceWrapper(weakResult);
    });
    return result;
}

- (void)setRoomModel:(id)roomModel {
    %orig;
    DYYYLiveDurationInstallFromAudienceWrapper(self);
}

- (void)setAudienceViewController:(UIViewController *)audienceViewController {
    %orig;
    DYYYLiveDurationInstallFromAudienceWrapper(self);
}

- (void)attachAudienceViewControllerDelegate:(id)delegate {
    %orig;
    DYYYLiveDurationInstallFromAudienceWrapper(self);
}

- (void)exitLiveRoomWithType:(unsigned long long)type {
    UIViewController *viewController = DYYYLiveDurationSafeValue(self, @"audienceViewController");
    if ([viewController isKindOfClass:[UIViewController class]]) {
        DYYYLiveDurationRemoveFromView(viewController.view);
    }
    %orig;
}

- (void)dealloc {
    UIViewController *viewController = DYYYLiveDurationSafeValue(self, @"audienceViewController");
    if ([viewController isKindOfClass:[UIViewController class]]) {
        DYYYLiveDurationRemoveFromView(viewController.view);
    }
    %orig;
}

%end

%hook IESLiveInnerFeedLiveRoomCell

- (void)setItemModel:(id)itemModel {
    %orig;
    DYYYLiveDurationInstallFromInnerFeedCell(self);
}

- (void)setRoomAisle:(id)roomAisle {
    %orig;
    DYYYLiveDurationInstallFromInnerFeedCell(self);
}

- (void)setAudienceVC:(UIViewController *)audienceVC {
    %orig;
    DYYYLiveDurationInstallFromInnerFeedCell(self);
}

- (void)updateWithItemModel:(id)itemModel {
    %orig;
    DYYYLiveDurationInstallFromInnerFeedCell(self);
}

- (void)prepareForReuse {
    UIViewController *viewController = DYYYLiveDurationSafeValue(self, @"audienceVC");
    if ([viewController isKindOfClass:[UIViewController class]]) {
        DYYYLiveDurationRemoveFromView(viewController.view);
    }
    %orig;
}

%end

%hook IESLiveAudienceViewController
// NOTE: prefersStatusBarHidden is intentionally NOT duplicated here - huami's own hook keeps it.
// Only the live-duration lifecycle methods are ported from Wtrwx.
- (void)viewDidLoad {
    %orig;
    DYYYLiveDurationInstallOnView(self.view, self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    DYYYLiveDurationInstallOnView(self.view, self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    DYYYLiveDurationInstallOnView(self.view, self);
    DYYYLiveDurationUpdateView(self.view);
}

- (void)didEnterRoom:(id)room {
    %orig;
    DYYYLiveDurationInstallOnView(self.view, room ?: self);
}

- (void)didPreloadRoom:(id)room {
    %orig;
    DYYYLiveDurationInstallOnView(self.view, room ?: self);
}

- (void)didCloseRoom:(id)room closeType:(unsigned long long)type {
    DYYYLiveDurationRemoveFromView(self.view);
    %orig;
}

- (void)dealloc {
    if (self.isViewLoaded) {
        DYYYLiveDurationRemoveFromView(self.view);
    }
    %orig;
}
%end


// ===== 2.2-9-9 新增：全局 HDR 设置（从 Wtrwx 移植的安全子集） =====
// 开关：DYYYHDRMode（关闭 / 全局屏蔽HDR效果 / 全局过滤HDR作品），默认关闭。
// 子集说明：只含播放器/解码器/CAMetalLayer 的纯 HDR 门控 Hook；
// 刻意跳过：AWEVideoModel（与 huami 已有最高画质 Hook 冲突）、CALayer/CAShapeLayer
// （Wtrwx 版混有头像加号图层压制逻辑，不在本任务范围）。过滤模式走 huami 已有
// contentFilter 的 HDR 检测（filterHDR 增加了 ShouldFilterGlobalHDR）。
static NSString *const kDYYYHDRModeKey = @"DYYYHDRMode";
static NSString *const kDYYYHDRModeOff = @"关闭";
static NSString *const kDYYYHDRModeDisable = @"全局屏蔽HDR效果";
static NSString *const kDYYYHDRModeFilter = @"全局过滤HDR作品";
static char kDYYYHDRStrippedAwemeModelKey;
static char kDYYYHDRStrippedVideoModelKey;
static char kDYYYHDROnlyAwemeModelKey;
static char kDYYYHDROnlyVideoModelKey;

static void DYYYMigrateCombinedHDRModeIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if ([defaults boolForKey:@"DYYYHDRModeMigratedV1"]) {
            return;
        }

        NSString *mode = [defaults stringForKey:kDYYYHDRModeKey];
        BOOL hasValidMode = [mode isEqualToString:kDYYYHDRModeOff] ||
                            [mode isEqualToString:kDYYYHDRModeDisable] ||
                            [mode isEqualToString:kDYYYHDRModeFilter];
        if (!hasValidMode) {
            if ([defaults boolForKey:@"DYYYDisableAllHDR"]) {
                mode = kDYYYHDRModeDisable;
            } else if ([defaults boolForKey:@"DYYYFilterFeedHDR"]) {
                mode = kDYYYHDRModeFilter;
            } else {
                mode = kDYYYHDRModeOff;
            }
        }

        [defaults setObject:mode forKey:kDYYYHDRModeKey];
        [defaults removeObjectForKey:@"DYYYDisableAllHDR"];
        [defaults setBool:YES forKey:@"DYYYHDRModeMigratedV1"];
    });
}

static BOOL DYYYShouldDisableAllHDR(void) {
    DYYYMigrateCombinedHDRModeIfNeeded();
    return [[[NSUserDefaults standardUserDefaults] stringForKey:kDYYYHDRModeKey] isEqualToString:kDYYYHDRModeDisable];
}

static BOOL DYYYShouldFilterGlobalHDR(void) {
    DYYYMigrateCombinedHDRModeIfNeeded();
    return [[[NSUserDefaults standardUserDefaults] stringForKey:kDYYYHDRModeKey] isEqualToString:kDYYYHDRModeFilter];
}

static id DYYYStandardCADynamicRange(void) {
    static id standardDynamicRange = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *symbol = dlsym(RTLD_DEFAULT, "CADynamicRangeStandard");
        if (symbol) {
            id __unsafe_unretained *value = (id __unsafe_unretained *)symbol;
            standardDynamicRange = *value;
        }
    });
    return standardDynamicRange;
}

static id DYYYToneMapModeIfSupported(void) {
    static id toneMapMode = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *symbol = dlsym(RTLD_DEFAULT, "CAToneMapModeIfSupported");
        if (symbol) {
            id __unsafe_unretained *value = (id __unsafe_unretained *)symbol;
            toneMapMode = *value;
        }
    });
    return toneMapMode;
}

static void DYYYApplySDRDynamicRangeToImageView(UIImageView *imageView) {
    if (!DYYYShouldDisableAllHDR() || !imageView) {
        return;
    }

    // SDK 16.5 没有 UIImageDynamicRange / preferredImageDynamicRange，用运行时消息发送；
    // UIImageDynamicRangeStandard = 0，运行设备 iOS 17+ 上该属性存在，respondsToSelector 兜底。
    SEL sel = NSSelectorFromString(@"setPreferredImageDynamicRange:");
    if ([imageView respondsToSelector:sel]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(imageView, sel, 0);
    }
}

// 头像加号可能由异步动画重建图层，需要在 CALayer 写入点继续压制。
static BOOL DYYYShouldForceHideAvatarActionLayer(CALayer *layer);
static BOOL DYYYShouldClearAvatarActionLayer(CALayer *layer);
static void DYYYPrepareAvatarActionSublayer(CALayer *parentLayer, CALayer *sublayer);

static void DYYYDisableExtendedRangeForLayer(CALayer *layer) {
    if (!DYYYShouldDisableAllHDR() || !layer) {
        return;
    }

    SEL setWantsEDRSelector = @selector(setWantsExtendedDynamicRangeContent:);
    if ([layer respondsToSelector:setWantsEDRSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(layer, setWantsEDRSelector, NO);
    }

    id toneMapMode = DYYYToneMapModeIfSupported();
    SEL setToneMapModeSelector = @selector(setToneMapMode:);
    if (toneMapMode && [layer respondsToSelector:setToneMapModeSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(layer, setToneMapModeSelector, toneMapMode);
    }

    id standardDynamicRange = DYYYStandardCADynamicRange();
    SEL setPreferredDynamicRangeSelector = @selector(setPreferredDynamicRange:);
    if (standardDynamicRange && [layer respondsToSelector:setPreferredDynamicRangeSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(layer, setPreferredDynamicRangeSelector, standardDynamicRange);
    }

    if (@available(iOS 16.0, *)) {
        if ([layer isKindOfClass:[CAMetalLayer class]]) {
            ((CAMetalLayer *)layer).EDRMetadata = nil;
        }
    }
}

static void DYYYDisableExtendedRangeForMetalLayer(CAMetalLayer *metalLayer) {
    if (!DYYYShouldDisableAllHDR() || !metalLayer) {
        return;
    }

    DYYYDisableExtendedRangeForLayer(metalLayer);
}

static void DYYYDisableAVPlayerItemHDRMetadata(AVPlayerItem *item) {
    if (!DYYYShouldDisableAllHDR() || !item) {
        return;
    }

    if (@available(iOS 14.0, *)) {
        item.appliesPerFrameHDRDisplayMetadata = NO;
    }
}

%hook AVPlayer

+ (AVPlayerHDRMode)availableHDRModes {
    if (DYYYShouldDisableAllHDR()) {
        return 0;
    }
    return %orig;
}

+ (BOOL)eligibleForHDRPlayback {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

+ (instancetype)playerWithURL:(NSURL *)URL {
    AVPlayer *player = %orig;
    DYYYDisableAVPlayerItemHDRMetadata(player.currentItem);
    return player;
}

+ (instancetype)playerWithPlayerItem:(AVPlayerItem *)item {
    DYYYDisableAVPlayerItemHDRMetadata(item);
    return %orig;
}

- (instancetype)initWithURL:(NSURL *)URL {
    self = %orig;
    DYYYDisableAVPlayerItemHDRMetadata(self.currentItem);
    return self;
}

- (instancetype)initWithPlayerItem:(AVPlayerItem *)item {
    DYYYDisableAVPlayerItemHDRMetadata(item);
    return %orig;
}

- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    DYYYDisableAVPlayerItemHDRMetadata(item);
    %orig;
}

%end

%hook AVPlayerItem

+ (instancetype)playerItemWithURL:(NSURL *)URL {
    AVPlayerItem *item = %orig;
    DYYYDisableAVPlayerItemHDRMetadata(item);
    return item;
}

+ (instancetype)playerItemWithAsset:(AVAsset *)asset {
    AVPlayerItem *item = %orig;
    DYYYDisableAVPlayerItemHDRMetadata(item);
    return item;
}

+ (instancetype)playerItemWithAsset:(AVAsset *)asset automaticallyLoadedAssetKeys:(NSArray<NSString *> *)automaticallyLoadedAssetKeys {
    AVPlayerItem *item = %orig;
    DYYYDisableAVPlayerItemHDRMetadata(item);
    return item;
}

- (instancetype)initWithURL:(NSURL *)URL {
    self = %orig;
    DYYYDisableAVPlayerItemHDRMetadata(self);
    return self;
}

- (instancetype)initWithAsset:(AVAsset *)asset {
    self = %orig;
    DYYYDisableAVPlayerItemHDRMetadata(self);
    return self;
}

- (instancetype)initWithAsset:(AVAsset *)asset automaticallyLoadedAssetKeys:(NSArray<NSString *> *)automaticallyLoadedAssetKeys {
    self = %orig;
    DYYYDisableAVPlayerItemHDRMetadata(self);
    return self;
}

- (void)setAppliesPerFrameHDRDisplayMetadata:(BOOL)appliesPerFrameHDRDisplayMetadata {
    %orig(DYYYShouldDisableAllHDR() ? NO : appliesPerFrameHDRDisplayMetadata);
}

- (BOOL)appliesPerFrameHDRDisplayMetadata {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

%end

%hook AVPlayerLayer

- (void)setPlayer:(AVPlayer *)player {
    DYYYDisableAVPlayerItemHDRMetadata(player.currentItem);
    %orig;
    DYYYDisableExtendedRangeForLayer(self);
}

- (void)layoutSublayers {
    %orig;
    DYYYDisableAVPlayerItemHDRMetadata(self.player.currentItem);
    DYYYDisableExtendedRangeForLayer(self);
}

%end

%hook AWEKnowledgeABTestSettings

+ (BOOL)enableHDRAutomaticIdentification {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

%end

%hook AWEFeedABSettings

+ (BOOL)enableHDRBrightnessOpt {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

+ (BOOL)enableProfilePreloadHDRBrightnessFilter {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

+ (BOOL)enableDynamicGaussianBlurHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

+ (BOOL)enableHDRFullModelAdaptation {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

+ (BOOL)hdrAutomaticIdentification {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

%end

%hook AWEFeedABTestServiceObjc

+ (BOOL)enableProfilePreloadHDRBrightnessFilter {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

%end

%hook BDSimPlayerBizConfig

- (BOOL)enableHDRBrightnessOpt {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (BOOL)enableHDRFullModelAdaptation {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (BOOL)hdrAutomaticIdentification {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

%end

%hook AWEBDSimPlayerBizConfig

- (BOOL)enableHDRBrightnessOpt {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (BOOL)enableHDRFullModelAdaptation {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (BOOL)hdrAutomaticIdentification {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

%end

%hook AWEVideoPlayerConfiguration

+ (void)setHDRBrightnessStrategy:(id)strategy {
    if (!DYYYShouldDisableAllHDR()) {
        %orig;
    }
}

+ (double)getHDRBrightnessOffset:(id)configuration brightness:(double)brightness {
    if (DYYYShouldDisableAllHDR()) {
        return 0.0;
    }
    return %orig;
}

%end

%hook AWEDPlayerVideoDisplayOptState

- (BOOL)enableHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setEnableHDR:(BOOL)enableHDR {
    %orig(DYYYShouldDisableAllHDR() ? NO : enableHDR);
}

%end

%hook AWEPlayVideoPlayerContext

- (BOOL)enableHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setEnableHDR:(BOOL)enableHDR {
    %orig(DYYYShouldDisableAllHDR() ? NO : enableHDR);
}

%end

%hook AWEDPlayerVideoModel

- (BOOL)awe_isHDRVideo {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setAwe_isHDRVideo:(BOOL)awe_isHDRVideo {
    %orig(DYYYShouldDisableAllHDR() ? NO : awe_isHDRVideo);
}

%end

%hook AWEPlayVideoViewController

- (BOOL)enableHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setEnableHDR:(BOOL)enableHDR {
    %orig(DYYYShouldDisableAllHDR() ? NO : enableHDR);
}

- (BOOL)awe_isCurrentVideoHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setPlayerLutFilter:(id)lutFilter HDRLutImage:(id)HDRLutImage {
    %orig(lutFilter, DYYYShouldDisableAllHDR() ? nil : HDRLutImage);
}

%end

%hook AWEDPlayerBrightnessContainer

- (BOOL)awe_isCurrentVideoHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

%end

%hook AWEVideoPlayerScreenBrightnessManager

- (BOOL)isHDRVideo {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setIsHDRVideo:(BOOL)isHDRVideo {
    // 播放器复用时会重新写入当前作品的 HDR 状态，需同时清除写入值和读取结果。
    %orig(DYYYShouldDisableAllHDR() ? NO : isHDRVideo);
}

%end

%hook ALMOwnPlayerWrapper

- (void)setLutFilter:(id)lutFilter HDRLutImage:(id)HDRLutImage {
    %orig(lutFilter, DYYYShouldDisableAllHDR() ? nil : HDRLutImage);
}

%end

%hook ALMSysPlayerWrapper

- (void)setLutFilter:(id)lutFilter HDRLutImage:(id)HDRLutImage {
    %orig(lutFilter, DYYYShouldDisableAllHDR() ? nil : HDRLutImage);
}

%end

%hook ALMVideoPlayerConfig

+ (void)setPlayerEffectHDRLutImageEnable:(BOOL)enable {
    %orig(DYYYShouldDisableAllHDR() ? NO : enable);
}

%end

%hook IESVideoPlayerConfig

+ (void)setPlayerEffectHDRLutImageEnable:(BOOL)enable {
    %orig(DYYYShouldDisableAllHDR() ? NO : enable);
}

%end

%hook AWEIMModuleService

- (BOOL)im_forceHDRToSDR {
    if (DYYYShouldDisableAllHDR()) {
        return YES;
    }
    return %orig;
}

%end

%hook IESIMVideoPlayerWrapper

- (void)setupHDREnable:(BOOL)enable {
    %orig(DYYYShouldDisableAllHDR() ? NO : enable);
}

%end

%hook AWEIMVideoBrowserCollectionViewCell

- (void)setEnablePlayHDR:(BOOL)enable {
    %orig(DYYYShouldDisableAllHDR() ? NO : enable);
}

%end

%hook AWEECOMIMAppSettingsService

+ (BOOL)enableVideoPreviewSupportHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

%end

%hook IESLiveAudienceHDRController

+ (BOOL)currentHDRStatusForRoomID:(id)roomID {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

+ (BOOL)isCurrentRoomSupportHDR:(id)roomID roomModel:(id)roomModel {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

+ (BOOL)isFeedCanEnableHDRFeature {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

+ (BOOL)isInnerFeedCanEnableHDRFeature {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

+ (BOOL)isUserEnableHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

+ (BOOL)p_isHDRFeatureEnable {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

+ (void)setUserEnableHDR:(BOOL)enableHDR {
    %orig(DYYYShouldDisableAllHDR() ? NO : enableHDR);
}

+ (BOOL)shouldShowHDRSwitchForRoom:(id)room {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

%end

%hook IESLivePlayerController

- (BOOL)isVideoSDR2HDRSupport {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setEnableVideoSDR2HDR:(BOOL)enable callTrace:(id)callTrace {
    %orig(DYYYShouldDisableAllHDR() ? NO : enable, callTrace);
}

- (BOOL)enableCloseSDR2HDR {
    if (DYYYShouldDisableAllHDR()) {
        return YES;
    }
    return %orig;
}

%end

%hook AWELivePreStreamPlayer

- (void)changeSDR2HDRWithStrategy {
    if (!DYYYShouldDisableAllHDR()) {
        %orig;
    }
}

%end

%hook HTSLiveStreamPlayer

- (void)setEnableVideoSDR2HDR:(BOOL)enable callTrace:(id)callTrace {
    %orig(DYYYShouldDisableAllHDR() ? NO : enable, callTrace);
}

- (void)changeSDR2HDRWithStrategy {
    if (!DYYYShouldDisableAllHDR()) {
        %orig;
    }
}

%end

%hook IESLiveStreamPlayerVideoAudioEffectPlugin

- (void)setEnableVideoSDR2HDR:(BOOL)enable callTrace:(id)callTrace {
    %orig(DYYYShouldDisableAllHDR() ? NO : enable, callTrace);
}

- (void)changeSDR2HDRWithStrategy {
    if (!DYYYShouldDisableAllHDR()) {
        %orig;
    }
}

%end

%hook TVLManager

- (BOOL)shouldForbidHDR10Render {
    if (DYYYShouldDisableAllHDR()) {
        return YES;
    }
    return %orig;
}

- (void)setShouldForbidHDR10Render:(BOOL)shouldForbid {
    %orig(DYYYShouldDisableAllHDR() ? YES : shouldForbid);
}

- (void)setupVideoSDR2HDR:(id)config {
    if (!DYYYShouldDisableAllHDR()) {
        %orig;
    }
}

%end

%hook TVLPlayerItemPreferences

- (BOOL)forbidSDR2HDRInPreview {
    if (DYYYShouldDisableAllHDR()) {
        return YES;
    }
    return %orig;
}

- (void)setForbidSDR2HDRInPreview:(BOOL)forbid {
    %orig(DYYYShouldDisableAllHDR() ? YES : forbid);
}

- (BOOL)enableUseSDR2HDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setEnableUseSDR2HDR:(BOOL)enable {
    %orig(DYYYShouldDisableAllHDR() ? NO : enable);
}

%end

%hook TVLSettingsManager

- (BOOL)enableMetalRenderHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

%end

%hook BDImageDecoderFactory

+ (BOOL)isHDRImageData:(id)data withHeifDecoderClass:(Class)decoderClass {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

%end

%hook BDImageDecoderImageIO

- (BOOL)isHDRCGImage:(CGImageRef)image decodedToHDR:(BOOL)decodedToHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (id)hdrOptionsFor:(id)image decodedToHDR:(BOOL *)decodedToHDR {
    if (DYYYShouldDisableAllHDR()) {
        if (decodedToHDR) {
            *decodedToHDR = NO;
        }
        return nil;
    }
    return %orig;
}

%end

%hook BDImageDecoderHeic

+ (BOOL)isHDRData:(id)data {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (BOOL)isHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setIsHDR:(BOOL)isHDR {
    %orig(DYYYShouldDisableAllHDR() ? NO : isHDR);
}

%end

%hook BDImageDecoderBVC2

- (BOOL)isHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setIsHDR:(BOOL)isHDR {
    %orig(DYYYShouldDisableAllHDR() ? NO : isHDR);
}

%end

%hook BDImageDecoderWebP

- (BOOL)isHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setIsHDR:(BOOL)isHDR {
    %orig(DYYYShouldDisableAllHDR() ? NO : isHDR);
}

%end

%hook BDImage

- (BOOL)isHDR {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setIsHDR:(BOOL)isHDR {
    %orig(DYYYShouldDisableAllHDR() ? NO : isHDR);
}

%end

// Wtrwx AwemeHeaders.h 里的三类接口（huami 头文件里没有，Logos 只给前向声明，补齐才能访问属性）
@class CAMetalLayer;
@interface HDRMTImageView : UIView
@property(nonatomic, strong) CAMetalLayer *metalLayer;
@end
@interface HDRMTUIImageView : UIImageView
@property(nonatomic, assign) BOOL hdrEnabled;
@property(nonatomic, strong) HDRMTImageView *innerHDRImageView;
- (instancetype)initWithFrame:(CGRect)frame hdrEnabled:(BOOL)hdrEnabled;
@end
@interface HDRMTButton : UIButton
@property(nonatomic, strong) HDRMTUIImageView *hdrmtImageView;
- (void)configHDRContent;
@end

%hook HDRMTUIImageView

- (instancetype)initWithFrame:(CGRect)frame hdrEnabled:(BOOL)hdrEnabled {
    return %orig(frame, DYYYShouldDisableAllHDR() ? NO : hdrEnabled);
}

- (BOOL)hdrEnabled {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setHdrEnabled:(BOOL)hdrEnabled {
    %orig(DYYYShouldDisableAllHDR() ? NO : hdrEnabled);
}

- (void)setImage:(UIImage *)image {
    if (DYYYShouldDisableAllHDR()) {
        self.hdrEnabled = NO;
    }
    DYYYApplySDRDynamicRangeToImageView(self);
    %orig;
    DYYYApplySDRDynamicRangeToImageView(self);
}

%end

%hook HDRMTImageView

- (void)setMetalLayer:(CAMetalLayer *)metalLayer {
    %orig;
    DYYYDisableExtendedRangeForMetalLayer(metalLayer);
}

- (void)setUpEnv {
    %orig;
    DYYYDisableExtendedRangeForMetalLayer(self.metalLayer);
}

- (void)layoutSubviews {
    %orig;
    DYYYDisableExtendedRangeForMetalLayer(self.metalLayer);
}

%end

%hook HDRMTButton

- (void)configHDRContent {
    %orig;
    DYYYApplySDRDynamicRangeToImageView(self.hdrmtImageView);
}

%end

%hook CAMetalLayer

- (void)setWantsExtendedDynamicRangeContent:(BOOL)wantsExtendedDynamicRangeContent {
    %orig(DYYYShouldDisableAllHDR() ? NO : wantsExtendedDynamicRangeContent);
}

- (BOOL)wantsExtendedDynamicRangeContent {
    if (DYYYShouldDisableAllHDR()) {
        return NO;
    }
    return %orig;
}

- (void)setEDRMetadata:(CAEDRMetadata *)EDRMetadata {
    %orig(DYYYShouldDisableAllHDR() ? nil : EDRMetadata);
}

- (CAEDRMetadata *)EDRMetadata {
    if (DYYYShouldDisableAllHDR()) {
        return nil;
    }
    return %orig;
}

%end

// 2.2-9-19 DYKiller 视频全屏补齐（用户 2026-11-02 17:08 反馈 -18 仍有黑线和主页半屏）：
// (1) 黑线 = 进度条底边背景 progressSliderUnderView，DYYY 原来完全没藏它，全屏时它仍在视频底部、底栏上方
//     露出一条细黑线。DYKiller 的 DKProgressUnderline 就是在全屏时藏掉它，关时由原生状态机恢复。
//     这里只在全屏开时、updateProgressSliderUnderView 跑完原生逻辑后再藏，关时不动手（%orig 已按原生状态恢复），
//     不动进度条本身、不动进度时间标签。
// (2) 主页半屏 = 博主主页点进的详情表（AWEAwemeDetailTableViewController）行高与表高不一致：
//     DYYY 老全屏只拉高了内容视图，没拉表、没改行高，分页仍按原行高算，滑完就停在两行中间，
//     上一个视频露下半截、下一个视频露上半截。DYKiller 的 DKVideoDetailTable 是表和行高同步拉到同一满高，
//     这里只对整页行（原生行高 ≈ 表原高）改，特殊行（头、评论等不同高度）一律原样放行；首页信息流表不动，
//     因为首页目前分页是正常的，动它反而可能把首页搞坏。
static char kDYYYDetailTableOriginalHeightKey;
static char kDYYYDetailTableLiveKey;
static BOOL DYYYIsLiveEnteredVC(UIViewController *vc);
static BOOL DYYYDetailTablePrepare(id controller, id tableView) {
    if (![tableView isKindOfClass:[UITableView class]]) return NO;
    UITableView *table = (UITableView *)tableView;
    if (!DYYYGetBool(@"DYYYEnableFullScreen")) {
        NSNumber *orig = objc_getAssociatedObject(table, &kDYYYDetailTableOriginalHeightKey);
        if (orig) {
            objc_setAssociatedObject(table, &kDYYYDetailTableOriginalHeightKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            CGRect f = table.frame;
            f.size.height = orig.doubleValue;
            table.frame = f;
        }
        return NO;
    }
    if (![NSThread isMainThread]) return NO;
    UIViewController *vc = (UIViewController *)controller;
    UIView *root = vc.viewIfLoaded;
    if (!root) return NO;
    UIWindow *window = table.window ?: root.window;
    if (window && window.windowLevel != UIWindowLevelNormal) return NO;
    if (table.superview && ![table isDescendantOfView:root]) return NO;
    if (!CGAffineTransformIsIdentity(table.transform)) return NO;
    CGFloat target = table.superview ? CGRectGetHeight(table.superview.bounds) : CGRectGetHeight(root.bounds);
    CGFloat current = CGRectGetHeight(table.frame);
    // 2.2-9-41 直播 rowHeight 属性前置：表帧已是终态时下面早返回，rowHeight 永远设不上，分页代码若走
    // rowHeight 属性就拿到原生值。直播栈且表高 956 时，不管帧是不是已拉满，先把 rowHeight 置 911，
    // 再走后面的早返回/拉伸逻辑；普通表不改 rowHeight。
    @try {
        if (vc && DYYYIsLiveEnteredVC(vc) && fabs(target - 956.0) <= 0.5) {
            table.rowHeight = 911.0;
        }
    } @catch (__unused NSException *e) {}
    // 2.2-9-34 过渡跳同理：表帧还远没到终态（推入动画中途，< 终态 85%）时先不拉伸，让动画滑过去，
    // 接近终态时再拉满，纠正量小，不会中途跳一下。
    if (isfinite(target) && isfinite(current) && target > 0 && current > 0 && current < target * 0.85) {
        return NO;
    }
    if (!isfinite(target) || !isfinite(current) || target <= 0.0 || current >= target - 0.5 || current < target * 0.5) {
        return NO;
    }
    if (!objc_getAssociatedObject(table, &kDYYYDetailTableOriginalHeightKey)) {
        objc_setAssociatedObject(table, &kDYYYDetailTableOriginalHeightKey, @(current), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGRect f = table.frame;
    f.size.height = target;
    table.frame = f;
    // 2.2-9-41 直播专用：表 rowHeight 属性也同步到实测分页步长 911，仅直播栈且表高 956 时，
    // 避免分页代码走 rowHeight 属性而不是代理行高时又拿到原生值。普通表不改 rowHeight。
    @try {
        if (vc && DYYYIsLiveEnteredVC(vc) && fabs(target - 956.0) <= 0.5) {
            table.rowHeight = 911.0;
        }
    } @catch (__unused NSException *e) {}
    return YES;
}
static double DYYYDetailRowHeight(id tableView, double nativeHeight) {
    if (!DYYYGetBool(@"DYYYEnableFullScreen") || ![tableView isKindOfClass:[UITableView class]]) return nativeHeight;
    UITableView *table = (UITableView *)tableView;
    CGFloat target = CGRectGetHeight(table.bounds);
    // 2.2-9-41 直播行高前置：表帧已是终态 956 时 Prepare 早返回、原高没存，之前原高检查会直接回原生，
    // 直播行高就永远到不了 911 分支。直播分支提到原高检查之前：只要是直播栈、表高 956、视频行，
    // 直接返回实测分页步长 911，不管原高有没有存、表帧是不是已拉满；普通仍走后面的原高逻辑，一字不动。
    if (isfinite(target) && isfinite(nativeHeight) && nativeHeight >= target * 0.5 && fabs(target - 956.0) <= 0.5) {
        @try {
            UIViewController *vc41 = [DYYYUtils firstAvailableViewControllerFromView:table];
            if (vc41 && DYYYIsLiveEnteredVC(vc41)) {
                return 911.0;
            }
        } @catch (__unused NSException *e) {}
    }
    NSNumber *orig = objc_getAssociatedObject(table, &kDYYYDetailTableOriginalHeightKey);
    if (!orig || !isfinite(nativeHeight) || !isfinite(target) || nativeHeight <= 0.0 || target <= orig.doubleValue + 0.5) {
        return nativeHeight;
    }
    // 2.2-9-40 诊断定根（用户 12:49 诊断截图：表H=956、行=956，但偏移=911，差 45，不是行高的倍数）：
    // 分页步长不是表高，而是可见高 = 表高 - 内边距（956-45=911），行高拉到 956 就每页差 45、越滑越错。
    // 仅直播栈时，视频行高改成可见高（表高 - 上下内边距），偏移和（contentOffsetY 经 cellHeightAtIndex
    // 调这里，也会跟着变成可见高累加）就和分页步长对齐，一屏一个。普通进入不进这个分支，行高仍是表高，
    // 一字不动。集合那路的 diag（collH=3、itemH=50）是侧边小集合，不是详情流，忽略。
    if (nativeHeight >= target * 0.5) {
        @try {
            UIViewController *vc40 = [DYYYUtils firstAvailableViewControllerFromView:table];
            if (vc40 && DYYYIsLiveEnteredVC(vc40)) {
                // 2.2-9-41 -40 未中修正（用户 12:55：第二个开始就慢慢两节）：-40 用内边距推可见高，
                // 若内边距是 83（底栏）就推成 873、若是 0 就推不成，行高都不是实测分页步长 911，
                // 每页差 38 或 45，慢慢两节。不再推内边距：仅当表高就是这台机的 956 时，直播行高
                // 直接定实测分页步长 911，和偏移 911、1822……对齐；其他表高仍走原逻辑，不硬套。
                // 普通进入不进这个分支，行高仍是表高，一字不动。
                if (fabs(target - 956.0) <= 0.5) {
                    return 911.0;
                }
            }
        } @catch (__unused NSException *e) {}
    }
    // 2.2-9-32 递增错位修复（用户视频 23:44：同博主按顺序开 1 个正常、2 个小错位、3 个明显、4 个严重）：
    // 之前行高只在原生高与原高/目标高差 0.5 内才拉满，其余回原生。视频比例、文案长度稍有不同，
    // 原生高就不是恰好原高/目标高，行高回原生后每页差 = 框高-原生高，页数一多就累积：
    // 第 2 页差 1 份（小）、第 3 页差 2 份（明显）、第 4 页差 3 份（严重），和视频完全对上。
    // 现在放宽：只要是视频行（原生高 >= 框高一半），一律拉满到框高，不再要求恰好等于原高/目标高；
    // 矮行（头、评论等，原生高 < 框高一半）仍原样放行，避免把头/评论也拉满。
    if (nativeHeight >= target * 0.5) {
        return target;
    }
    if (fabs(nativeHeight - orig.doubleValue) > 0.5 && fabs(nativeHeight - target) > 0.5) {
        return nativeHeight;
    }
    return target;
}
static id DYYYDetailTableViewForController(id controller) {
    @try {
        id t = [controller valueForKey:@"tableView"];
        if ([t isKindOfClass:[UITableView class]]) return t;
    } @catch (__unused NSException *e) {
    }
    return nil;
}
%group DYYYFullscreenProgressGroup
%hook AWEDProgressFeedContainer
- (UIView *)progressSliderUnderView {
    UIView *view = %orig;
    if (view && DYYYGetBool(@"DYYYEnableFullScreen")) {
        view.hidden = YES;
    }
    return view;
}
%end
%hook AWEDProgressStateChangeContainer
- (void)updateProgressSliderUnderView {
    %orig;
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        @try {
            id selfObj = (id)self;
            id under = [selfObj valueForKey:@"progressSliderUnderView"];
            if ([under isKindOfClass:[UIView class]]) {
                ((UIView *)under).hidden = YES;
            } else if ([selfObj respondsToSelector:@selector(progressSliderUnderView)]) {
                UIView *u = ((UIView *(*)(id, SEL))objc_msgSend)(selfObj, @selector(progressSliderUnderView));
                if (u) u.hidden = YES;
            }
        } @catch (__unused NSException *e) {
        }
    }
}
%end
%end
%group DYYYFullscreenDetailTableGroup
%hook AWEAwemeDetailTableViewController
- (void)setupDetailTableView {
    %orig;
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        DYYYDetailTablePrepare(self, DYYYDetailTableViewForController(self));
    }
}
- (void)viewWillAppear:(BOOL)animated {
    // 2.2-9-37 回退 -35/-36 的推入延期（用户 11:49：普通视频进主页还是两节）：延期导致原高没存、
    // 表帧与行高脱节，普通视频也两节。恢复 -34 的分截好的状态：推入前（viewWillAppear，动画还没开始，
    // 视图 bounds 已是终态）就先拉满并存原高，第一次布局已是强制帧，推入动画的终态本身就是强制帧，
    // 中途不再需要纠正，也就不再跳一下然后居中。viewDidAppear 的直接改帧动画已删，不再绕过存原高。
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        DYYYDetailTablePrepare(self, DYYYDetailTableViewForController(self));
    }
    %orig;
}
- (void)viewWillLayoutSubviews {
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        DYYYDetailTablePrepare(self, DYYYDetailTableViewForController(self));
    } else {
        DYYYDetailTablePrepare(self, DYYYDetailTableViewForController(self));
    }
    %orig;
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        DYYYDetailTablePrepare(self, DYYYDetailTableViewForController(self));
    }
}
- (double)fixedCellHeight {
    if (!DYYYGetBool(@"DYYYEnableFullScreen")) return %orig;
    DYYYDetailTablePrepare(self, DYYYDetailTableViewForController(self));
    double nativeHeight = %orig;
    return DYYYDetailRowHeight(DYYYDetailTableViewForController(self), nativeHeight);
}
- (double)cellHeightAtIndex:(long long)index {
    if (!DYYYGetBool(@"DYYYEnableFullScreen")) return %orig;
    DYYYDetailTablePrepare(self, DYYYDetailTableViewForController(self));
    double nativeHeight = %orig;
    return DYYYDetailRowHeight(DYYYDetailTableViewForController(self), nativeHeight);
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!DYYYGetBool(@"DYYYEnableFullScreen")) return %orig;
    DYYYDetailTablePrepare(self, tableView);
    CGFloat nativeHeight = %orig;
    return DYYYDetailRowHeight(tableView, nativeHeight);
}
- (double)contentOffsetYForCellAtIndex:(long long)index {
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        // 2.2-9-46 基底回退到 -44（用户 2026-11-04：以 -44 包为基底加玻璃）：
        // -45 的累加到 index-1 把正常滑动分页也带偏了（用户 13:38：都不正常了，不修了），已作废。
        // -44 状态：逐行累加到 index 为止，某行回 0 按 0 继续加，不整段回原生；普通正常，直播点第 9 出第 10，
        // 该问题已随 -45 关闭，不再单独修，只保留 -44 的普通正常状态作为玻璃基底。
        if (index <= 0) return 0;
        if (index < 1000) {
            double sum = 0;
            for (long long i = 0; i < index; i++) {
                double h = 0;
                @try { h = ((double (*)(id, SEL, long long))objc_msgSend)(self, @selector(cellHeightAtIndex:), i); } @catch (__unused NSException *e) { h = 0; }
                if (!isfinite(h) || h < 0) h = 0;
                sum += h;
            }
            return sum;
        }
    }
    return %orig;
}
- (void)adjustTableViewHeightForTargetIndex:(long long)index {
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        DYYYDetailTablePrepare(self, DYYYDetailTableViewForController(self));
    }
    %orig;
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        DYYYDetailTablePrepare(self, DYYYDetailTableViewForController(self));
    }
}
%end
%end

// 2.2-9-21 黑线通用修复（用户 2026-11-02 17:24 补充关键线索：黑线跟进度条在一起，按住进度条能看到两条线；
// 且黑线只在视频里有，直播和图片没有——直播/图片没有进度条，正好对上，说明黑线就是进度条的底边背景，
// 不是底栏分隔线也不是 Cell 分隔线。-19 按 40.8 的 AWEDProgress 容器类名去藏，在 40.9.0 里没跑起来，
// 所以这次不依赖那个类名：直接从 40.9.0 里肯定存在的 AWEFeedProgressSlider 出发，遍历它自己和上两级容器，
// 找细（0.5~4.5pt）、满宽（>=300pt 且 >= 滑块宽 80%）、纯黑（RGB 均 <0.3）的视图，全屏开时藏、关时按标记恢复。
// 进度条已播部分是白色/彩色，不会误藏；标签、滑块本身高度和颜色都不符合，不会误藏。只在全屏开时跑，关时恢复，
// 直播/图片没有进度滑块，本来就不会跑到这里。
static char kDYYYProgressBlackLineKey;
static void DYYYFullscreenProgressSyncBlackLines(UIView *slider) {
    if (!slider) return;
    BOOL enableFS = DYYYGetBool(@"DYYYEnableFullScreen");
    NSMutableArray *containers = [NSMutableArray array];
    [containers addObject:slider];
    UIView *up = slider.superview;
    for (NSInteger i = 0; up && i < 4; i++, up = up.superview) {
        [containers addObject:up];
    }
    CGFloat sliderW = CGRectGetWidth(slider.bounds);
    if (sliderW <= 0) sliderW = CGRectGetWidth(slider.frame);
    for (UIView *container in containers) {
        for (UIView *v in [container.subviews copy]) {
            if (v == slider) continue;
            CGFloat h = CGRectGetHeight(v.bounds);
            CGFloat w = CGRectGetWidth(v.bounds);
            // 2.2-9-22 放宽：@3x 下 1px 只有 0.33pt，之前 0.5 下限会漏；深灰也算，之前 <0.3 太严；
            // 类名含 Under/Track/Separator/Line/Border 的细满宽视图，即使颜色取不到也算（进度底边常是图层色而非 backgroundColor）
            NSString *vcn = NSStringFromClass([v class]);
            BOOL nameHit = ([vcn containsString:@"Under"] || [vcn containsString:@"Track"] || [vcn containsString:@"Separator"] || [vcn containsString:@"Line"] || [vcn containsString:@"Border"]);
            if (h < 0.2 || h > 6.0 || w < 250.0 || w < sliderW * 0.7) continue;
            if (v.hidden && !objc_getAssociatedObject(v, &kDYYYProgressBlackLineKey)) continue;
            UIColor *bg = v.backgroundColor;
            BOOL isBlack = NO;
            if (bg) {
                CGFloat r = 0, g = 0, b = 0, a = 0;
                if ([bg getRed:&r green:&g blue:&b alpha:&a] && r < 0.5 && g < 0.5 && b < 0.5 && a > 0.2) {
                    isBlack = YES;
                }
            }
            if (!isBlack && !nameHit) continue;
            if (enableFS) {
                if (!v.hidden) {
                    v.hidden = YES;
                    objc_setAssociatedObject(v, &kDYYYProgressBlackLineKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            } else {
                if (objc_getAssociatedObject(v, &kDYYYProgressBlackLineKey)) {
                    v.hidden = NO;
                    objc_setAssociatedObject(v, &kDYYYProgressBlackLineKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            }
        }
    }
}
%group DYYYFullscreenProgressGenericGroup
%hook AWEFeedProgressSlider
- (void)layoutSubviews {
    %orig;
    DYYYFullscreenProgressSyncBlackLines(self);
}
%end
%end

// 2.2-9-25 博主主页详情半屏复发补齐（用户 2026-11-02 22:33，冯黛儿页顶搜索+底评论栏，上下两个视频各一半；
// 用户 22:36 关键判据：只从直播间进入才出现，直接进博主主页点视频是正常的）：
// -19 只覆盖了 AWEAwemeDetailTableViewController（表），但 40.9.0 里博主主页点进的详情页很可能走
// UICollectionView（首页信息流本身就是 Collection），表行高那套对它完全不起作用，表/集合高被全屏拉高后
// item 尺寸还停在原高，分页就按原高算，滑完停在两行中间，就是各一半。补一块：只对控制器类名含 Detail 的
// CollectionView（主页详情、搜索详情、合集详情等），全屏开时把集合高拉到父视图满高并使布局失效一次，
// 让代理按新高重算整页 item；原高不到父高一半（网格缩略图等）或控制器不含 Detail（首页信息流等）一律不动，
// 关全屏时按存档恢复并再失效一次。表详情（-19）不动，黑线（-24）、直播（-23）不动。
// 直播间进入排除（22:36 判据）：从直播间进入的详情页，其父控制器链里有 Live 房间控制器，层级与直接进主页不同，
// 全屏钉位/表高/集合高都会按错的父高算，分页直接断在两行中间。对这类页一律不拉全屏、原样放行原生布局：
// 宁可这条路径不是全屏，也不要各一半看不了；直接进主页的路径仍走全屏，不受影响。
static BOOL DYYYIsLiveOriginatedView(UIView *view) {
    @try {
        UIViewController *vc = [DYYYUtils firstAvailableViewControllerFromView:view];
        for (NSInteger i = 0; vc && i < 20; i++, vc = vc.parentViewController) {
            if ([NSStringFromClass([vc class]) containsString:@"Live"]) return YES;
            if (vc.presentingViewController && [NSStringFromClass([vc.presentingViewController class]) containsString:@"Live"]) return YES;
            if (vc.navigationController) {
                for (UIViewController *navVC in vc.navigationController.viewControllers) {
                    if ([NSStringFromClass([navVC class]) containsString:@"Live"]) return YES;
                }
                if (vc.navigationController.presentingViewController && [NSStringFromClass([vc.navigationController.presentingViewController class]) containsString:@"Live"]) return YES;
            }
            for (UIViewController *child in vc.childViewControllers) {
                if ([NSStringFromClass([child class]) containsString:@"Live"]) return YES;
            }
        }
        UIResponder *resp = view.nextResponder;
        for (NSInteger i = 0; resp && i < 20; i++, resp = resp.nextResponder) {
            if ([NSStringFromClass([resp class]) containsString:@"Live"]) return YES;
        }
        UIView *anc = view.superview;
        for (NSInteger i = 0; anc && i < 12; i++, anc = anc.superview) {
            if ([NSStringFromClass([anc class]) containsString:@"Live"]) return YES;
        }
    } @catch (__unused NSException *e) {}
    return NO;
}
static char kDYYYDetailCollectionOriginalHeightKey;
// 2.2-9-38 直播进主页专用判定（用户 11:55：普通已正常，只修直播进主页，不动普通）：导航栈/父/呈现/子链里
// 有 Live 房间控制器才算直播进主页。普通进入的栈是 首页->主页->详情，里面没有 Live，判定为否，
// 下面所有直播分支都不跑，普通路径一字不动。只认导航栈里的真直播间，不认头像直播徽章，避免把直播作者的
// 普通视频误判成直播进主页（那类视频 -37 已正常，绝不能再动）。
static BOOL DYYYIsLiveEnteredVC(UIViewController *vc) {
    if (!vc) return NO;
    @try {
        UIViewController *cur = vc;
        for (NSInteger i = 0; cur && i < 20; i++, cur = cur.parentViewController) {
            if ([NSStringFromClass([cur class]) containsString:@"Live"]) return YES;
            if (cur.presentingViewController && [NSStringFromClass([cur.presentingViewController class]) containsString:@"Live"]) return YES;
            if (cur.navigationController) {
                for (UIViewController *navVC in cur.navigationController.viewControllers) {
                    if ([NSStringFromClass([navVC class]) containsString:@"Live"]) return YES;
                }
                if (cur.navigationController.presentingViewController && [NSStringFromClass([cur.navigationController.presentingViewController class]) containsString:@"Live"]) return YES;
            }
            for (UIViewController *child in cur.childViewControllers) {
                if ([NSStringFromClass([child class]) containsString:@"Live"]) return YES;
            }
        }
    } @catch (__unused NSException *e) {}
    return NO;
}
static BOOL DYYYDetailCollectionPrepare(UICollectionView *collectionView);
static BOOL DYYYDetailCollectionPrepare(UICollectionView *collectionView) {
    if (![collectionView isKindOfClass:[UICollectionView class]]) return NO;
    if (!DYYYGetBool(@"DYYYEnableFullScreen")) {
        NSNumber *orig = objc_getAssociatedObject(collectionView, &kDYYYDetailCollectionOriginalHeightKey);
        if (orig) {
            objc_setAssociatedObject(collectionView, &kDYYYDetailCollectionOriginalHeightKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            CGRect f = collectionView.frame;
            f.size.height = orig.doubleValue;
            collectionView.frame = f;
            @try { [collectionView.collectionViewLayout invalidateLayout]; } @catch (__unused NSException *e) {}
        }
        return NO;
    }
    if (![NSThread isMainThread] || !collectionView.superview) return NO;
    UIViewController *vc = [DYYYUtils firstAvailableViewControllerFromView:collectionView];
    NSString *vcName = vc ? NSStringFromClass([vc class]) : @"";
    // 2.2-9-38 直播进主页集合专用放宽：直播间进主页的详情集合，第一控制器可能是直播相关控制器
    // （名字含 Live、不含 Detail），之前 Detail 检查直接返回 NO，框和 item 全没拉满，分截就来了；
    // 普通详情的控制器名字含 Detail，原检查已过，不受影响。放宽只在直播栈判定为真且控制器名字含 Live
    // 时才生效，普通集合（首页、主页网格、聊天等）既不含 Detail、栈里也没有 Live，仍原样返回 NO。
    // 后面的框高/item 高守卫（框高 >= 父高一半、item 高 >= 目标高一半）仍在，小 item 的网格/聊天集合进不来。
    if (![vcName containsString:@"Detail"] && !(DYYYIsLiveEnteredVC(vc) && [vcName containsString:@"Live"])) return NO;
    UIWindow *window = collectionView.window ?: vc.view.window;
    if (window && window.windowLevel != UIWindowLevelNormal) return NO;
    if (!CGAffineTransformIsIdentity(collectionView.transform)) return NO;
    CGFloat target = CGRectGetHeight(collectionView.superview.bounds);
    CGFloat current = CGRectGetHeight(collectionView.frame);
    // 2.2-9-32 集合版递增错位同理：框拉满了还不够，item 高若还留原生随比例变，分页每页差就累积。
    // 只要原 item 高 >= 目标高一半（视频项），一律把 item 高改成目标高并失效布局，矮项不动；框已拉满时也照做，
    // 否则只靠代理重算，代理缓存了旧 item 高就永远对不上。
    if (isfinite(target) && target > 0) {
        @try {
            id layout0 = collectionView.collectionViewLayout;
            if ([layout0 isKindOfClass:[UICollectionViewFlowLayout class]]) {
                UICollectionViewFlowLayout *flow0 = (UICollectionViewFlowLayout *)layout0;
                CGSize item0 = flow0.itemSize;
                if (item0.height >= target * 0.5 && fabs(item0.height - target) > 0.5) {
                    flow0.itemSize = CGSizeMake(item0.width, target);
                    // 2.2-9-38 直播进主页集合专用：只在直播栈时把行间距和区边距清零。item 高拉满了还不够，
                    // 行间距/边距若留着，分页偏移 = item 高 + 间距，每页差一份，越滑越错位、两节。
                    // 普通集合不进这个分支，间距/边距原样不动。
                    if (DYYYIsLiveEnteredVC(vc)) {
                        flow0.minimumLineSpacing = 0;
                        flow0.sectionInset = UIEdgeInsetsZero;
                    }
                    [collectionView.collectionViewLayout invalidateLayout];
                }
            }
        } @catch (__unused NSException *e) {}
    }
    if (!isfinite(target) || !isfinite(current) || target <= 0.0 || current >= target - 0.5 || current < target * 0.5) return NO;
    if (!objc_getAssociatedObject(collectionView, &kDYYYDetailCollectionOriginalHeightKey)) {
        objc_setAssociatedObject(collectionView, &kDYYYDetailCollectionOriginalHeightKey, @(current), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGRect f = collectionView.frame;
    f.size.height = target;
    collectionView.frame = f;
    @try { [collectionView.collectionViewLayout invalidateLayout]; } @catch (__unused NSException *e) {}
    return YES;
}
%group DYYYFullscreenDetailCollectionGroup
%hook UICollectionView
- (void)layoutSubviews {
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        DYYYDetailCollectionPrepare(self);
    } else {
        DYYYDetailCollectionPrepare(self);
    }
    %orig;
    if (DYYYGetBool(@"DYYYEnableFullScreen")) {
        DYYYDetailCollectionPrepare(self);
    }
}
%end
%end

%ctor {
    // 2.2-9-84 视频画质默认最高：只注册默认值，不写显式值。
    // registerDefaults 只在键未设置过时生效——用户以前亲手关过“提高视频画质”，
    // 他的关保留，不会被新包翻回开；从没动过开关的，装 -84 后默认就是开。
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"DYYYEnableVideoHighestQuality": @YES}];
    // 2.2-9-19 全屏补齐组的按需安装：类或方法在 40.9.0 里不存在就跳过，不装、不崩，其他功能不受影响
    {
        Class feedCls = NSClassFromString(@"AWEDProgressFeedContainer");
        Class stateCls = NSClassFromString(@"AWEDProgressStateChangeContainer");
        if ((feedCls && [feedCls instancesRespondToSelector:@selector(progressSliderUnderView)]) ||
            (stateCls && [stateCls instancesRespondToSelector:@selector(updateProgressSliderUnderView)])) {
            %init(DYYYFullscreenProgressGroup);
        }
        Class detailCls = NSClassFromString(@"AWEAwemeDetailTableViewController");
        if (detailCls && ([detailCls instancesRespondToSelector:@selector(fixedCellHeight)] ||
                          [detailCls instancesRespondToSelector:@selector(cellHeightAtIndex:)])) {
            %init(DYYYFullscreenDetailTableGroup);
        }
        // 2.2-9-21 通用进度黑线组：AWEFeedProgressSlider 在 40.9.0 里肯定存在（DYYY 本来就 hook 它），直接装
        if (NSClassFromString(@"AWEFeedProgressSlider")) {
            %init(DYYYFullscreenProgressGenericGroup);
        }
        // 2.2-9-25 详情 Collection 组：UICollectionView 是系统类，肯定存在，直接装，组内按 Detail 控制器过滤
        %init(DYYYFullscreenDetailCollectionGroup);
    }
    Class interactionBaseLabelClass = objc_getClass("AWECommentSwiftBizUI.CommentInteractionBaseLabel");
    if (interactionBaseLabelClass) {
        %init(DYYYCommentExactTimeGroup, AWECommentSwiftBizUI_CommentInteractionBaseLabel = interactionBaseLabelClass);
    }
    
    Class imMenuComponentClass = objc_getClass("AWEIMCustomMenuComponent");
    if (imMenuComponentClass) {
        SEL legacySelector = NSSelectorFromString(@"msg_showMenuForBubbleFrameInScreen:tapLocationInScreen:menuItemList:moreEmoticon:onCell:extra:");
        SEL tapLocationSelector = NSSelectorFromString(@"msg_showMenuForBubbleFrameInScreen:tapLocationInScreen:menuItemList:menuPanelOptions:moreEmoticon:onCell:extra:");
        SEL highLowSelector = NSSelectorFromString(@"msg_showMenuForBubbleFrameInScreen:highLocationInScreen:lowLocationInScreen:tryHighLocationFirst:menuItemList:menuPanelOptions:onCell:extra:");
        if (legacySelector && class_getInstanceMethod(imMenuComponentClass, legacySelector)) {
            %init(DYYYIMMenuLegacyGroup);
        }
        if (tapLocationSelector && class_getInstanceMethod(imMenuComponentClass, tapLocationSelector)) {
            %init(DYYYIMMenuTapLocationGroup);
        }
        if (highLowSelector && class_getInstanceMethod(imMenuComponentClass, highLowSelector)) {
            %init(DYYYIMMenuHighLowGroup);
        }
    }

    if (!DYYYGetBool(@"DYYYDisableSettingsGesture")) {
        %init(DYYYSettingsGesture);
    }
    if (DYYYGetBool(@"DYYYUserAgreementAccepted")) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
          Class wSwiftImpl = objc_getClass("AWECommentInputViewSwiftImpl.CommentInputContainerView");
          %init(CommentInputContainerView = wSwiftImpl);
        });
        BOOL isAutoPlayEnabled = DYYYGetBool(@"DYYYEnableAutoPlay");
        if (isAutoPlayEnabled) {
            %init(AutoPlay);
        }
        if (DYYYGetBool(@"DYYYForceDownloadEmotion") ||
            DYYYGetBool(@"DYYYForceDownloadCommentAudio") ||
            DYYYGetBool(@"DYYYForceDownloadCommentImage")) {
            %init(EnableStickerSaveMenu);
        }
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        isFloatSpeedButtonEnabled = [defaults boolForKey:@"DYYYEnableFloatSpeedButton"];

        // 初始化红包激励挂件容器视图类组
        Class incentivePendantClass = objc_getClass("AWEIncentiveSwiftImplDOUYINLite.IncentivePendantContainerView");
        if (incentivePendantClass) {
            %init(IncentivePendantGroup, AWEIncentiveSwiftImplDOUYINLite_IncentivePendantContainerView = incentivePendantClass);
        }
        Class imageContentClass = objc_getClass("BDMultiContentContainer.ImageContentView");
        if (imageContentClass) {
            %init(BDMultiContentImageViewGroup, BDMultiContentContainer_ImageContentView = imageContentClass);
        }

        // 动态获取 Swift 类并初始化对应的组
        Class commentHeaderGeneralClass = objc_getClass("AWECommentPanelHeaderSwiftImpl.CommentHeaderGeneralView");
        if (commentHeaderGeneralClass) {
            %init(CommentHeaderGeneralGroup, AWECommentPanelHeaderSwiftImpl_CommentHeaderGeneralView = commentHeaderGeneralClass);
        }

        Class commentHeaderGoodsClass = objc_getClass("AWECommentPanelHeaderSwiftImpl.CommentHeaderGoodsView");
        if (commentHeaderGoodsClass) {
            %init(CommentHeaderGoodsGroup, AWECommentPanelHeaderSwiftImpl_CommentHeaderGoodsView = commentHeaderGoodsClass);
        }
        Class commentHeaderTemplateClass = objc_getClass("AWECommentPanelHeaderSwiftImpl.CommentHeaderTemplateAnchorView");
        if (commentHeaderTemplateClass) {
            %init(CommentHeaderTemplateGroup, AWECommentPanelHeaderSwiftImpl_CommentHeaderTemplateAnchorView = commentHeaderTemplateClass);
        }

        Class tipsVCClass = objc_getClass("AWECommentPanelListSwiftImpl.CommentBottomTipsContainerViewController");
        if (tipsVCClass) {
            %init(CommentBottomTipsVCGroup, AWECommentPanelListSwiftImpl_CommentBottomTipsContainerViewController = tipsVCClass);
        }

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        DYYYRemoveKeyboardObserver();
        dyyyKeyboardWillShowToken = [center addObserverForName:UIKeyboardWillShowNotification
                                                        object:nil
                                                         queue:[NSOperationQueue mainQueue]
                                                    usingBlock:^(NSNotification *notification) {
                                                      if (DYYYGetBool(@"DYYYHideKeyboardAI")) {
                                                          if (cachedHideView) {
                                                              for (UIView *subview in cachedHideView.subviews) {
                                                                  subview.hidden = YES;
                                                              }
                                                          } else {
                                                              for (UIWindow *window in [UIApplication sharedApplication].windows) {
                                                                  findTargetViewInView(window);
                                                                  if (cachedHideView)
                                                                      break;
                                                              }
                                                          }
                                                      }
                                                    }];
    }
}
