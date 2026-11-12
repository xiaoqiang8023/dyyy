// DYYYViewAdjust.h
// 消息页精简共用的可复位视图调整（DYKiller DKViewAdjust 移植，2.2-9-99）。
// 只移植本功能用到的部分：透明度乘系数、transform 叠加、mask 淡出、底色清除。
// DKAdjustStackRows（元素栈逐行缩放）本功能不用，未移植。
// “隐藏”用挂半透明 mask 实现，不改 alpha / hidden，隐藏的项仍可点击。
#import <UIKit/UIKit.h>

#ifndef DYYYViewAdjust_h
#define DYYYViewAdjust_h

#ifdef __cplusplus
extern "C" {
#endif

/// 两个 transform 在显示精度内是否相同。
BOOL DYYYAdjustTransformEqual(CGAffineTransform lhs, CGAffineTransform rhs);

/// 透明度乘系数（0–1），乘在宿主当前 alpha 上；系数为 1 时还原宿主值。
void DYYYAdjustAlpha(UIView *view, CGFloat factor);

/// delta 叠加在宿主当前 transform 之后；delta 为单位矩阵时还原宿主值。
void DYYYAdjustTransform(UIView *view, CGAffineTransform delta);

/// 整个视图按系数（0–1）淡出：挂半透明 mask，不改 alpha / hidden，命中不受影响。
/// mask 向四周外扩 outset，覆盖超出 bounds 的子视图；系数为 1 时摘掉自己的 mask；宿主自带 mask 时不覆盖。
void DYYYAdjustFade(UIView *view, CGFloat factor, CGSize outset);

/// 视图上本模块 mask 的系数；没挂或已被宿主替换时返回 1。
CGFloat DYYYAdjustFadeFactor(UIView *view);

/// 清除或还原底色：宿主再次落色时更新还原基线；还原时若宿主已换成其他颜色，保留宿主的值。
void DYYYAdjustClearBackground(UIView *view, BOOL clear);

/// 底色当前是否由 DYYYAdjustClearBackground 接管。
BOOL DYYYAdjustBackgroundCleared(UIView *view);

#ifdef __cplusplus
}
#endif

#endif /* DYYYViewAdjust_h */
