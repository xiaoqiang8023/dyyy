# DYYY AI Agent 提示文档

本项目是基于 Theos/Logos 的抖音 UI 调整 Tweak。当前仓库 README 标注仅在 **抖音 36.5.0** 版本测试；回答需求时请以仓库现状为准，不要沿用旧版本描述。

## 工程关键点
- **Hook 入口**：`DYYY.xm` 负责 Feed、浮窗、全局透明度与 Tab Bar 高度等通用 Hook；`DYYYSettings.xm` 负责抖音设置页相关 Hook（`AWESettingBaseViewController`、`AWELeftSideBarWeatherLabel` 等）并构造 DYYY 自定义设置。
- **业务核心**：`DYYYManager` 统一处理媒体下载、批量任务、Live Photo/GIF/WebP 转换及保存流程，内部维护 `NSOperationQueue` 与下载任务/回调映射；`DYYYSettingsHelper` 管理设置依赖、入口查找、用户协议弹窗；`DYYYUtils` 处理 IP 属地、颜色、窗口查找、缓存路径等可复用逻辑。
- **UI 组件**：所有自定义视图/弹窗（如 `DYYYBottomAlertView`、`DYYYFloatSpeedButton`、`DYYYAboutDialogView` 等）都有 `.h/.m` 配对文件，并在设置控制器中组合使用。
- **模型/数据**：`CityManager` 负责本地城市映射与 GeoNames 查询；GeoNames 结果缓存逻辑在 `DYYYUtils`；`DYYYConstants.h`、`DYYYSettingsHelper` 中定义的 Key 控制远程 ABTest、依赖关系与通知。
- **AwemeHeaders**：项目依赖的抖音私有类、Category 声明、宏定义都集中在 `AwemeHeaders.h` 中，供整个 tweak 引入。

## 类路径速查（按 UI/功能分组）
- **入口 Hook / 控制器**
  - `DYYY.xm`、`DYYYSettings.xm`：全局 Hook、设置页 Hook。
  - `DYYYSettingViewController.(h/m)`：自定义设置主界面。
  - `DYYYSettingsHelper.(h/m)`：设置项依赖、入口、协议弹窗。
  - `DYYYLivePreview.xm`（2.2-9-56 新增）：推荐页直播卡片在线人数 + 开播时长（DY778 直播信息移植），钩 `AWELiveNewPreStreamViewController` 生命周期，卡片胶囊对齐/顺序/大小与拖动位置是自己重做的。2.2-9-68：直播信息设置页照抄 DY778 作者原版——基本设置里原先的两组删掉，改成“直播信息”独立设置页（`DYYYLiveInfoSettingsViewController.h/.m`，从基本设置一行入口推入；两组：推荐页直播卡片 / 直播间浮层 + 显示说明；青色开关/图标 `[DYYYLiveInfoSettingsViewController accentColor]` 照抄 DY778Accent #55CDB9 浅色 ×0.58；三个滑杆行照抄 DY778SliderCell：人数刷新间隔 2–10 秒、文字大小 11–19 pt、背景不透明度 15–100%；人数格式行副标题带示例“简洁 · 1.2万 / 完整 · 12345”，沿用 DYYYOptionsSelectionView；卡片胶囊样式合并成一行，点进 `DYYYLiveInfoCapsuleEditorViewController.h/.m` 子页：对齐/上下顺序/大小三项 + 实时预览胶囊（尺寸与真实胶囊一致），点“保存”才写三键；颜色行沿用 DYYYCustomInputView 文本输入，右侧加 28pt 圆点色板；页脚说明照抄原版；作者 1.0-3 源码里没有“卡片胶囊样式”和“恢复直播卡片位置”这两行，是按作者新版截图补的。设置键、默认值、胶囊功能逻辑全部保持 -56/-62 原样，只改设置页。2.2-9-59 安全版：为查冻屏一次性摘了 -57 加的 NSUserDefaultsDidChangeNotification 订阅、状态标签钩整段、重试多给的两轮（回到 -56 的 15 次），触发只剩生命周期钩 + 定时器。2.2-9-60（胶囊出得慢约 2 秒）：activate 时预取一次（网络请求提前到卡片出现时发）+ 数据缺失时最多两发单次延时补刷（0.35/0.90 秒，代际守卫、有上限）；不加回状态标签钩、defaults 订阅、layoutRetryRearms。
  - `DYYYFans*.h/.m`（2.2-9-57 新增，Hooks/Model/Policy/Runtime/Service/UI/Web/Signer/Private）：星牌查询（DY778 移植），用户主页注入“星牌”按钮，查询消费等级与粉丝灯牌；安装原用 `__attribute__((constructor))`（`.m` 不能用 Logos 的 `%ctor`），设置键 `DYYYFansEnabled` 默认关闭，设置页接入见 `DYYYFans-SETTINGS-SNIPPET.md`。2.2-9-59：constructor 安装已删（查冻屏，星牌暂不装）。2.2-9-60：constructor 单独加回（单变量测试，-57 原样，含其 defaults 订阅），其他三样 -59 摘掉的东西不加回；用户确认 -60 会冻住，星牌安装定罪。2.2-9-61：constructor 保留，删掉 `DYYYInstallFansHooks` 里的全局 `NSUserDefaultsDidChangeNotification` 订阅——移植 bug：上游订的是只在 DY778 自己改设置时才发的自定义通知 `DY778PreferencesChangedNotification`，移植时被换成全局通知，任何一次写 defaults 都触发主队列更新；个人主页更新只靠生命周期钩。2.2-9-62：修星牌两个 bug——①闪退：查询页 preferencesChanged/pause 回主线程（通知可由后台线程投递）、Service stage 全程主线程、finish 回调回主线程、progress/partialResult 主线程安全、灯牌行下标越界守卫、枚举块 key 参数 int32_t→id（无闪退日志，未定罪到单点）；②无返回：移植 DY778NavigationController 为 DYYYFansNavigationController（常显导航栏、每页左上角“‹ 返回”、右滑返回手势）+ DYYYFansReturnTransition，PresentController 只在宿主已是星牌导航栈时 push，否则自建全屏导航 modal。2.2-9-63：没选主播时显示全部能查到的灯牌——nativeUser 回调里没选主播不再只凭等级提前结束（走完 web user / nativeCard 再汇总，prefer_data 里的多个灯牌才能拿到），completeBadge 没选主播不过滤并按等级降序排序，页脚/完成状态文案改成“本次可查询到的灯牌”（非完整清单）；选了主播保持只显示该主播。补：-62 真机截图灯牌组为空，头号原因是主播默认成了被查者本人——本人灯牌归属别的直播间主播，anchorUID 永远对不上本人 uid，全被过滤掉；修法是主播是本人时按没选主播处理（queryInput 归一化 + completeBadge 再防一层 + useAnchor 选本人时弹提示重查 + 查询完成无条件同步 result.anchor 清掉旧值），shareText 末尾加上“诊断：”一行供用户贴回定位。2.2-9-64：星牌查询改成“输入谁就查谁”——“查询主播”第二角色整段去掉，查询页只剩三组（当前用户/粉丝灯牌/本次结果），当前用户组新增“切换查询对象”行（输抖音号、UID 或分享链接，用已有 resolveInput Automatic 解析，可多候选核对，近期查过的人存 8 个）；Service 里 queryInput 不再解析主播、恒按没选主播查全部灯牌，completeBadge 的按主播过滤分支整段删掉，finishLiveResult 无灯牌文案改成“暂未取得可确认的灯牌，不代表未加入。”；merge: 里把 extra.diagnostic 也拼进 result.diagnostic（同一段只拼一次），复制结果的诊断里终于能看到模型层 pay_grade/fans_club/current_badge/preferred_map/records/recognized，分清“本来就没有灯牌”还是“接口没返回灯牌数据”。2.2-9-65：消费等级后加人民币约算——Model 新增 rmbStringForDiamonds:/rmbRangeFromMinimum:maximum:（10 钻=1 元，整数十分位算；<¥10000 去末尾 0，≥¥10000 用“万”最多 1 位小数，maximum 为空写“¥X 以上”）；UI 第 2 行副标题后加“（约 ¥X–Y）”，第 0 组页脚说明 iOS 充值 1 元=7 钻，复制结果加“约合人民币”一行；没有钻石区间时不显示人民币。
- 2.2-9-66：DY778 1.0-3 三项移植（特别关注 DYYYRadar* 13 个 .m、消息留存 DYYYRecall*/DYYYMessageUI 6 个 .m、缓存管理 DYYYCache* 2 个 .m）+ 统一安装 `DYYYPortsInstall.m`（constructor，主队列调 5 个 install 函数；三功能默认全关）。设置页“基本设置”里“消息与关注”一组三个入口行（cellType 26 + cellTappedBlock 推各自设置页）。硬约束守住了：无全局 defaults 订阅、无 layoutSubviews 改帧、雷达定时器只在前台、缓存只删 5 个白名单目录（fd + O_NOFOLLOW 校验）、消息钩子异步落盘。移植时修了 3 处编译错：Radar 两个 .m 补 import DYYYRadarNetwork.h；Recall 加 DYYYRecallChatItem 协议声明；RecallMediaView 用局部变量接 task 再存 ivar。没移植：Recall 的 VM 层二次渲染修复、UNUserNotificationCenter delegate 抢占、编辑历史（属另一功能）、上游 sqlite 存档（改 JSON 文件）、媒体落盘（改远程播放）；雷达上游 viewDidLayoutSubviews 改表头帧已删、聊天开关只留了帮助函数未接线。
- 2.2-9-69：本机伪装别人主页（只在本机把“我”页显示成目标，别人手机上看到的还是你）。新文件 `DYYYDisguise.h/.m`（状态/缓存/取数/假 model/水印/进度条）+ `DYYYDisguiseHooks.m`（装钩，constructor 排在 Makefile 末尾、星牌之后）。别人主页导航栏加“伪装此人”按钮（星牌同款注入点 `AWEProfileNavigationBaseComponent`，放空隙最右端，放不下会盖住星牌时隐藏）；点一下走 `DYYYRadarNetwork` 调 `/aweme/v1/user/profile/other/` 取目标资料 + `/aweme/v1/aweme/post/` 取目标和自己的前 20 条作品，逐条确认播放量并刷进度，缓存写 `Application Support/DYYYDisguise/<本机UID>.json`，开关 `DYYYDisguiseActive`；“我”页读到自己时 `userModel` getter 返回假 `AWEUserModel`（头像/昵称/抖音号/简介/计数，uid 故意保持自己的），作品播放量在 `AWEAwemeModel -statistics` 上按 itemID 对位替换（只换数字）；“我”页全屏斜水印（本机昵称+UID、“仅本地伪装，请勿用于违法行为”）；“我”页“取消伪装”按钮 + 设置页“伪装主页”入口行可一键恢复。没做成：作品墙只换左下角播放量数字，封面和点开后的视频仍是自己的（完整替换要拦截主页作品列表接口，现有代码里找不到那个类/方法，不能编）。教训：`.xm` 调 C 函数必须给头文件加 `extern "C"` 包裹（`DYYYUtils.h` 同款），否则链接报未定义符号——`DYYYSettings.xm` 是唯一从 `.xm` 调 Fans C 函数的地方，之前没暴露。
- 2.2-9-70：修 -69 伪装成功但“我”页无变化（用户真机反馈：伪装索图 Lj435413 后提示成功，“我”页头像/昵称/数字/作品、水印、取消按钮全没变）。定罪两条都是代码级证据：① -69 只钩了 `AWEProfileNavigationBaseComponent` 的 userModel getter，但主页头部根本不走这个 getter——获赞/关注/粉丝数由 `AWEProfileHeaderSocialStatisticSectionControllerV2`（新版）和 `AWEProfileSocialStatisticView`（旧版）各自从自己的 context 读数渲染，头像/昵称/简介由 `AWEProfileBaseHeaderSectionController` 配 cell，作品格由 `AWEUserWorkCellContext` 配内容；且导航组件的 reloadData 不重配这些。② 假 model 没设 uid/secUID，`DYYYFansPerson(假 model)` 直接返回 nil，UpdateProfile 的 isMine 恒为 NO，取消按钮和水印全被 early-return 藏掉。修法：假 model 补 uid/userID=我自己的 uid；UpdateProfile 的 isMine 改按 `_userModel` ivar 读原始 model 判断；新增钩点照抄 DY778 1.0-3 主页数字自定义（`DY778DisplayStats.m`）同款类名/方法/签名判定，只在 context.isCurrentUser 且 userID 是我时才替换计数（获赞/粉丝/关注，互关无缓存不替换），并用弱引用表跟踪计数区/作品格/基础头部，伪装开/关后重刷（新版计数按 DY778 刷新套路重 apply、旧版重调 `p_updateSocialStatisticContent:`、基础头部重配当前 cell、作品格重调内容更新）；基础头部 `configCell:index:model:` 只在 model 本来就是我自己的 AWEUserModel 时才换成假 model（类型守卫）；设置页“伪装主页”组副标题/页脚现算诊断（开/关、目标昵称、缓存有无、最近保存时间）；完成提示加“已刷新，仍看不到请重启抖音”。仍未验证：头像/昵称/简介的替换走基础头部 configCell 的 model 替换，未真机测，不知道这条路在当前抖音版上到底配不配得上；作品封面和点开后的视频仍是自己的（-69 已知未做成）。编译教训：ARC 不允许把全局变量地址传给 `__autoreleasing` 出参（-66 同款），跟踪表改返回值再赋回。
- 2.2-9-71：新增“直播间人气榜”（只做这一件，其他功能不动）。新文件 `DYYYLiveBoardModel.h/.m`（键/通知/万规则/时长/room_data 解析/HTSLiveRoomAPI 取数/AWERouter 跳转）、`DYYYLiveBoardStore.h/.m`（主播按账号存 Application Support/DYYYLiveBoard/account-\<uid\>.json，选项存 defaults）、`DYYYLiveBoardApi.h/.m`（在播判定 + 人数/开播时间）、`DYYYLiveBoardMonitor.h/.m`（前台轮询）、`DYYYLiveBoardUI.h/.m`（榜单页）。设置页“直播信息”组加一行入口（副标题现算开关状态与主播数）；安装走 `DYYYPortsInstall.m` 的 `DYYYInstallLiveBoard()`。在播判定：A 路主用原生资料接口 `/aweme/v1/user/profile/other/` 的 room_data（status==2 是在播，room_id 长号优先、取不到用 web_rid），响应里没有 room_data 字段时才走 B 路 web 端 `webcast.amemv.com/douyin/webcast/reflow/room_id?sec_user_id=…`（有 room_id 即在播）；在播后调 HTSLiveRoomAPI fetchRoomInfoWithRoomID 拿人数和开播时间（取数/解析复用 DYYYLivePreview.xm -56/-60 的逻辑，.xm 的 static 函数无法跨文件链接故复制改名前缀；人数先严格按 roomID 对号，对不上再放宽取一次）。点行进直播间：AWERouter.transferToURLString: 依次试 `aweme://webcast_room?id=` → `aweme://live?room_id=&user_id=` → `snssdk1128://live?room_id=&user_id=`，全失败回退主页 `aweme://user/profile/<uid>` → `snssdk1128://user/profile/<uid>`；未开播点行直接进主页。轮询只在前台、串行（DYYYRadarNetwork，一次一个、间隔 >=2 秒、15 秒看门狗）、失败按 DYYYRadarRetryInterval 退避、退后台即停不补发；开播时长每秒跳一次，只改可见行副标题文字，不 reloadData、不动布局。键：`DYYYLiveBoardEnabled`（默认关）、`DYYYLiveBoardInterval`（默认 30 秒、10–300）；主播上限 20，按账号存 JSON，**没有 `DYYYLiveBoardAnchors` 这个 defaults 键**（照抄特别关注按账号存的做法）。编译教训：`DYYYRadarNetwork.h` 原来没给 C 函数加 extern "C"，.xm（DYYYSettings.xm）调 `DYYYRadarCurrentAccount()` 链接报未定义符号，已补（-69 同款）。只编译通过、未真机测；榜单页脚会显示本次取数走的是资料接口还是 reflow 兜底，供真机回报时对照。
- 2.2-9-75：给直播间人气榜悬浮面板加两件事（只做这两件，其他不动；基底 -74，用户已确认 -74 取数通了：小哭包 8539 在线、安顺 4952 在线）。①榜单设置页第 0 组加“悬浮榜透明度”滑杆行（照抄 -68 的 DY778SliderCell：标题 + 数值一行、滑杆在下、纯 Auto Layout、标准 UISlider；20%–100%，默认 64%；键 `DYYYLiveBoardOverlayOpacity` 存 0.2–1.0 的 double；只改面板黑底的 alpha，文字保持全不透明；滑杆实时写 store 发 StoreChanged，面板 `refresh` 里 `applyOpacity` 立即改，不用等下次进房间；拖滑杆时设置页 `reload` 跳过重建 cell——否则拖动会被打断，松手后 onDragEnd 再 reload）。②悬浮面板主体右滑隐藏（`UISwipeGestureRecognizer` 方向右，挂在 tableView 上，不跟标题栏 pan 拖动和行点按冲突；收起时 tableView 藏着，滑不了）：滑出屏幕左侧，只在左边缘留竖排“人气榜”小 pill（26×68、半透明黑底白字、同款透明度、与面板当时同一高度，按百分比记、横竖屏重算），点小标签滑回来（回藏前位置）；隐藏状态只在当前房间内有效（存在 view 实例上，不落盘，进新房间是新的 view 实例，重新显示）；清屏时小标签跟面板一起藏、退出清屏一起恢复（`DYYYFloatClearButton.xm` 按 `dyyy_live_board_overlay_tab` identifier 处理，面板没藏着时小标签不在界面上，是 no-op）。只编译通过、未真机测；未验证：拖滑杆面板底实时变透明、文字清不清晰、右滑后小标签在不在、点小标签回不回来、进新房间面板重新显示、清屏联动。
- 2.2-9-77：悬浮榜左滑显示（只改手势，其他不动；基底 -76）。右滑隐藏保持 -75 不变（面板主体右滑 → 滑出左侧，左边缘留竖排“人气榜”小标签）。显示改成左滑：小标签上加左滑手势 + 左边缘 20pt 宽隐形条（跟小标签同一高度，只在面板藏着时存在，面板显示时不装、不挡直播间其他手势），从任一处起手左滑都把面板滑回藏前位置；点小标签/点隐形条同样恢复，作备用（隐形条盖住了小标签左半边，所以它上面也接点按）。小标签触摸区加宽到 40pt（视觉 pill 仍 26pt 宽、左贴边，多出的 14pt 透明只接手势），左滑行程才够；视觉 pill 改成小标签按钮里的子视图（pillVisual），透明度仍跟面板同款黑底。恢复只走唯一的 restorePanel（点按/左滑/隐形条共用，面板拆除时小标签和隐形条一起走）。清屏联动：隐形条按 `dyyy_live_board_overlay_edge` 跟小标签同款处理（`DYYYFloatClearButton.xm`）。只改 `DYYYLiveBoardOverlay.m` + 清屏联动一处；无全局 defaults 订阅、无 layoutSubviews 改帧。只编译通过、未真机测。
- 2.2-9-79：修直播间右滑不能隐藏（只修手势，其他不动；基底 -78）。断因三条全占：①右滑手势只挂在 tableView 上，划标题栏（“人气榜 2人在播”那行）时根本没有手势、只会拖动；②划主播行时常被表格/直播间容器的 pan 抢走，手势没设 delegate 不允许并行；③ handleSwipeRight: 里 isCollapsed 时直接 return，收起的面板右滑没反应。修法只改 DYYYLiveBoardOverlay.m 五处：手势移到面板容器自身（标题栏/主播行/空白处起手都行，tableView 上的旧手势删掉不并存）+ delegate 设为 self 实现 shouldRecognizeSimultaneouslyWithGestureRecognizer:（只对 UIPanGestureRecognizer 返回 YES，不改任何 pan 本身的行为）+ handleSwipeRight: 去掉 isCollapsed 拦截 + handleHeaderPan: 里 hiddenBySwipe 时直接 return 并清掉拖动残留的 0.85 alpha（也不保存藏起时的位置）。左滑恢复（小标签/隐形条左滑、点按）、透明度滑杆、取数三路、清屏联动一律未动。799,930 字节，只编译通过、未真机测。
- 2.2-9-80：清屏跟藏 + 长按主播菜单（只做这两件，其他不动；基底 -79）。视频断定是抖音原生点按切换清屏（路线①）：视频约第 4 秒房间 UI 全清、约 6.5 秒回来，清屏帧里没有任何“退出清屏”按钮、也没有 DYYY 圆形按钮；DYYY 按钮只在推荐页可见（dyyyInteractionViewVisible 只在 AWEPlayInteractionViewController 里置 YES），targetClassNames 也全是推荐页的类，清不掉直播间 UI——原生清屏根本不走 DYYYRefreshViewsAfterClearToggle。修法：面板每秒 tick 里跟住房间 UI 的实际可见状态——扫当前房间这一个子树找第一个有效可见的原生 UILabel（带非空文字、frame 非空、祖先链都不 hidden、alpha 都 >0.01），一个都没有就是原生清屏，面板+小标签+隐形条跟着藏、UI 回来跟着恢复（只认 UILabel，不用猜直播间类名，不全量遍历 window；跳过 DYYY 自己的子树；装上后 1 跳宽限，宽限过后第一跳没标签就藏；收起/拖动时也跑）。DYYY 清屏补一洞：新增 DYYYClearButtonIsHiding()（.h 里 extern "C" 声明 + .xm 定义），面板在 DYYY 清屏已激活时才装上也要跟着藏，tick 里原生跟随在 DYYY 清屏激活时让位。长按主播菜单：榜单页 viewDidLoad 给 tableView 加 UILongPressGestureRecognizer（Began 触发一次，只认 section 1），弹现成的 DYYYRadarSheet（改名字 / 移除），与左滑菜单同一套流程；左滑菜单保留不动；页脚加“也可以长按一行改名字或移除主播”。开播时长胶囊没动（用户自己关了开关，不是 bug）。801,108 字节，只编译通过、未真机测。
- 2.2-9-81：人气榜加场观（累计进场人数）显示（只做这一件，带货不做；基底 -80）。解析照抄在线人数写法：DYYYLiveBoardModel.m 新增 DYYYLiveBoardParseCountValue（NSNumber 直接用；纯数字串走 OnlineCount；“12.5万”/“1.2亿”按后缀换算回数字）+ DYYYLiveBoardTotalViewersInRooms（键表 total_user/totalUser/total_user_count/totalUserCount/total_user_str/totalUserStr，数字键优先）+ 同款嵌套遍历（严格匹配 + 放宽版）；DYYYLiveBoardParseRoomData 里 room_data 带 total_user 时顺手读出。Api.m：fetchRoom 里 strict→relaxed 读场观，>0 才进 result[@"totalViewers"]，读不到不加键；room_data 在播无房间号那支也透传场观。存：随 result 进 Monitor 状态字典同一处，Monitor.m 不用动。显示：榜单副标题“在播 · 1.02万在线 · 场观 12.5万 · 已播 00:47:19”；悬浮行“在线数 · 场观 X · 时长”，详情 label 抗压缩 required、名字先截断。排序仍按在线人数，未开播仍只显示“未开播”。802,606 字节，只编译通过、未真机测；未验证：这版抖音 fetchRoomInfo 响应里到底有没有 total_user 字段。

- 2.2-9-78：删除主播做实、做可见（只做这一件，其他不动；基底 -77）。按环查断点：榜单页是 UITableViewController（delegate 就是自身；`DYYY.xm:4319` 的 setDataSource 钩是 `AWELiveSkylightViewModel` 的，与表无关）；section 1 在行数/cell/canEdit/左滑菜单/每秒 tick 里一致是主播组；`trailingSwipeActionsForRowAtIndexPath` 对 section 1 返回 [移除(Destructive), 改名字]；行 cell 是普通 `DYYYRadarAvatarCell`，无手势拦截；确认框 `DYYYRadarConfirm` 是正常 UIAlertController；`removeAnchor:` 里 uid 两边都是 NSString（`addAnchor:` 时 `DYYYRadarString` 归一化过），`isEqual:` 能对上，删后立即写 JSON、发 StoreChanged；Monitor 的 `invalidateTarget:` 只清状态/退避、不加人，轮询只遍历 Store.anchors，删了不会被加回来；榜单页和悬浮榜都订阅 StoreChanged，删完两边都刷。结论：代码链一环都没断，断点在“看不见”——页脚只写“榜单里左滑一行可以改名字”，没提移除。修法只改一处：`DYYYLiveBoardUI.m:238` 页脚改成“榜单里左滑一行可以改名字或移除主播。”，没加第二种删除入口（左滑菜单已够用，不并存）。799,820 字节，只编译通过、未真机测。
- 2.2-9-76：四组搬家（只做这个搬家，其他不动；基底 -75）。直播信息 / 星牌查询 / 伪装主页 / 消息与关注四组整组从“基本设置”二级页面搬到插件设置主界面：`DYYYSettings.xm` 里四组构造代码原样从基本设置 `cellTappedBlock` 内移到 `showDYYYSettingsVC` 函数体（`mainSection.itemArray` 之前），四个 `[sections addObject:]` 改成 section 变量（liveInfoSection/fansSection/disguiseSection/portsSection），`viewModel.sectionDataArray` 改成 `@[ mainSection, liveInfoSection, fansSection, disguiseSection, portsSection, cleanupSection, backupSection, aboutSection ]`——四组在“功能”分组之后、清理分组之前，顺序跟原来一样；四组里每一行、图标、开关、副标题、页脚、点按行为全部原样不动（直播信息/直播间人气榜进各自独立页、星牌开关、伪装主页入口、消息留存/特别关注/缓存管理三行），副标题/页脚仍每次打开设置页时现算；基本设置二级页面只剩五组（外观设置、视频播放、杂项设置、过滤与屏蔽、二次确认），不要两处并存。只编译通过、未真机测。
- 2.2-9-74：修直播间人气榜取数全失败（只做这一件，其他不动；基底 -73）。用户真机：-73 已装，悬浮榜每个房间都能出来了，但安顺和小哭包都在开播，四位全显示“读取失败”，榜单页副标题是同一句“读取失败：Covert from NSData to NSDictionary failed.(com.aweme.network.error / -11001)”——抖音网络层自己的报错：A 路宿主 GET 回来的不是 JSON 字典。核对结果：URL 与星牌完全一致（同 apiDomain/apiHost 解析、同 fallback 主机 https://aweme.snssdk.com、同路径 /aweme/v1/user/profile/other/；-74 把 DYYYLiveBoardProfileOtherURL() 里多余的收藏接口中转也去掉了，与星牌 DYYYFansAPIOrigin() 逐字一致）；唯一请求差异是参数：星牌 service 的原生资料请求只带 user_id/sec_user_id，榜单 A 路多带了一个 source=other_profile——这是 -11001 的头号嫌疑。修法：主路照抄星牌 service 的取数链（原生资料 + 网页资料）拿 roomID，但不走 DYYYFansService 单例——不调 prepare:（星牌开关关着就 403，榜单不该被它卡住；开关默认值不动）、不抢星牌查询的单发状态机、不碰 progress UI。原生那步走 DYYYRadarNetwork 的宿主 GET，参数与星牌完全一致（不带 source）；网页那步直接用 DYYYFansWebClient（NSURLSession + a_bogus，与宿主解析 -11001 无关，15 秒看门狗）；room_data 副判；reflow 兜底（需 secUID）。瀑布里每一步失败都继续往下走，只有三路都走完才记 error，步骤短记拼进错误描述（如“原生资料失败(-11001)；网页资料失败(502)；无 secUID 可走 reflow”）。“未开播”只在解析成功且确实没房间时才下结论：原生资料在本版抖音上经常不带房间信息，不能凭它判未开播，只有网页资料那步解析成功且没房间才能判（否则安顺在播又会被写成未开播）。解析到人时顺手把 secUID 补回 store（只写 secUID 字段），-73 的 backfill 由此替代、已删（它走 service resolveInput，开关关着 403、后备资料接口又撞 -11001，本来就补不上）。榜单页脚如实写最后实际走通的是哪条（“星牌解析 roomID”/“资料接口”/“资料接口（reflow 兜底）”），全失败时写三路断在哪一步（Monitor 新增 lastFailure，成功时清掉）。轮询纪律不变（前台、串行、默认 30 秒、退后台停、不补发、失败退避）。只编译通过、未真机测；未验证：去掉了 source 参数后原生那步还报不报 -11001、网页那步能不能拿到安顺和小哭包的 roomID、页脚写的是哪条路。
- 2.2-9-73：修 -72 两个真机 bug + 用户追加的两点（只做这些，其他不动；基底 -72）。① secUID 在加人时被丢掉：`DYYYFansModel.m:99` 的星牌 person 把 secUID 存在 `secUID` 键里，`confirmAnchor:` 又过一遍 `DYYYRadarProfile`，而 `DYYYRadarModel.m:131` 的 `DYYYRadarProfile` 只从 `sec_uid`/`secUserID` 读 secUID → 转出来是空串 → `addAnchor:` 存下空 secUID → A 路资料接口没返回 room_data、又没 secUID 走 B 路 reflow → 三位全报 502“资料接口未返回直播信息，且没有 secUID 可走兜底”。修法三处：`DYYYRadarProfile` 的 secUID 键表加 `secUID`（共用归一化点，一处修全路通）；`confirmAnchor:` 归一化后从 `secUID/sec_uid/sec_user_id/secUserID` 四键取第一个非空补回（多候选选择后那条也走 confirmAnchor）；`addAnchor:` 同样四键取。已加的三位不用删重加：Monitor 的 tick 发现 secUID 为空的主播先补——星牌 resolveInput（UID 模式）→ 失败走资料接口 `DYYYRadarApi profile:` 后备，补上写回 JSON（Store 新增 `updateSecUID:forUID:`，只写 secUID 字段、不动名字/自定义名字/头像），写回后 `invalidateTarget` 立刻重查；补不上记 attempts 走退避下轮再试。有了 secUID 后 A 路带 `sec_user_id` 再查，仍无 room_data 则 B 路 reflow 接上（有 room_id 即在播，再调 fetchRoomInfo）。② 悬浮榜只在个别直播间出现：查到的真正原因是安装路不全——开播时长胶囊有四组钩子（容器、audience wrapper、inner feed cell 的 `DYYYLiveDurationInstallFromInnerFeedCell`、IESLiveAudienceViewController 自身生命周期），悬浮榜 -72 只有前两条；直播广场/推荐页上下滑切换的房间走 inner feed cell 路，根本没装上。修法：`DYYYLiveBoardOverlayHooks.xm` 补 `IESLiveInnerFeedLiveRoomCell` 四钩（setItemModel/setRoomAisle/setAudienceVC/updateWithItemModel + prepareForReuse 拆除）与 `IESLiveAudienceViewController` 六钩（viewDidLoad/viewWillAppear/didEnterRoom/didPreloadRoom 安装 + didCloseRoom/dealloc 拆除，viewDidLayoutSubviews 故意不钩；viewDidLoad 后 0.35 秒再装一次置顶）；`refresh` 每次都 `bringSubviewToFront:`（房间自己的 view 后加上来会盖住）；进房间时主播还没加完（ShouldShow 假、没装上），之后在设置页加了主播、人在房间里没退出重进——`DYYYLiveBoardOverlayStartWatcher`（`DYYYInstallLiveBoard` 里启动，监听自家 `DYYYLiveBoardStoreChanged`，不是全局 defaults 通知）用弱引用的 lastRoot 给正在开着的房间补装。③ 用户追加：失败错显示成“未开播”——`detailForAnchor:` 只要 checkedAt>0 就返回“未开播”，读失败也被算成确认下播（安顺正在播，三行却全“未开播”）。修法：照抄榜单页 `subtitleForAnchor` 的顺序——在播显示数、有 error 显示“读取失败”、checkedAt>0 且无 error 才“未开播”、否则“暂未读取”；榜单页和悬浮榜状态文案一致。④ 构建事故（本次 -73 修出来的）：`DYYYLiveBoardOverlay.m` 与 `.xm` 同名，Theos 的 `rules.mk` 有 `%.m: %.xm` 规则，.xm 一新就会把手写 .m 覆盖成 logos 输出（-73 初版因此链接失败：Install* 定义全丢）。修法：钩子文件改名 `DYYYLiveBoardOverlayHooks.xm`（Makefile 同步），.m 顶部留了警告注释；教训：本工程禁止 .m 与 .xm 同名。只编译通过、未真机测；未验证：补 secUID 后三位还报不报读取失败、滑着进的房间悬浮榜出不出现、房间里加主播后补装行不行。
- 2.2-9-72：直播间内悬浮人气榜 + 加人改走星牌解析 + 自定义名字（只做这两件，其他不动；基底 -71）。新文件 `DYYYLiveBoardOverlay.h/.m`（悬浮面板 + 安装/拆除函数）+ `DYYYLiveBoardOverlay.xm`（钩点与 -7 开播时长胶囊完全一致：AWELiveAudienceContainerController 的 init/setAudienceVC/setRoomModel/updateWithRoomModel 等 + AWELiveAudienceViewController，声明补进 AwemeHeaders.h）；改 `DYYYLiveBoardModel.h/.m`（新键 DYYYLiveBoardOverlay 默认开、DYYYLiveBoardOverlayCollapsed、中心百分比×4 横竖屏分别记）、`DYYYLiveBoardStore.h/.m`（overlayEnabled 未写过视为 YES、setOption 支持 overlay、anchor 的 remark 字段存自定义名字、最长 30 字、setCustomName:forUID:）、`DYYYLiveBoardUI.m`（设置页第 0 组加“直播间内悬浮显示”开关行；加人三项：抖音号/UID/粘贴分享链接，先走 DYYYFansService resolveInput——UID 模式、抖音号模式、链接自动模式，三路兜底，多候选时弹选择表，失败再走特别关注后备（UID 走资料接口、抖音号走搜索），链接无后备；“没核对上”继续显示具体原因；左滑菜单改名字 + 移除，替换 commitEditingStyle 删除）、`DYYYFloatClearButton.xm`（清屏时悬浮榜跟时长胶囊一起藏/恢复，各受自家开关控制）。悬浮榜样式与时长胶囊一致（黑半透明 0.64、白字、圆角 7、0.5 白边），默认在时长胶囊下方 8pt（按 accessibilityIdentifier 找时长视图，找不到按安全区顶部 +120/横屏 +46），标题行显示“X人在播 · 总人数”、点标题收起/展开（只留标题行 + 总人数，状态存 defaults）、标题栏可拖（横竖屏分别记中心百分比，只改自己的 frame，内部用 Auto Layout、不在 layoutSubviews 里改帧）；行：自定义名字优先（DYYYRadarDisplayName 读 remark）、绿点/灰点、人数万规则、已播时长，在播按人数降序、未开播沉底，点行进直播间（复用 -71 三条路由 + 回退主页）；取数/刷新复用 DYYYLiveBoardMonitor（前台轮询），面板只在 DYYYLiveBoardChanged/StoreChanged 时刷新内容 + 1 秒显示 tick 刷时长文字，不另起轮询定时器；清屏联动在 DYYYRefreshViewsAfterClearToggle 里按 identifier 藏/恢复。注意：DYYYFansService resolveInput 的 prepare: 要求星牌总开关 DYYYFansEnabled 开着，关着时 403 失败后走特别关注后备。只编译通过、未真机测；未验证：悬浮榜默认位置是否正好在用户截图红框处、拖动后横竖屏位置是否各自记住、星牌解析能否核对上 MS1407 与 32556444245、点行进直播间三条路由在真机上是否接手。
- **业务/下载**
  - `DYYYManager.(h/m)`：下载、合成、任务管理、授权。
  - `CityManager.(h/m)`：城市映射与 GeoNames 查询。
  - `AWMSafeDispatchTimer.(h/m)`：安全延时定时器。
- **通用工具/常量**
  - `DYYYUtils.(h/m)`：窗口/颜色/路径等工具。
  - `DYYYConstants.h`：Keys、URL、通知名。
- **设置页复用 UI（按交互类型）**
  - 列表/选择：`DYYYKeywordListView.(h/m)`、`DYYYOptionsSelectionView.(h/m)`、`DYYYFilterSettingsView.(h/m)`。
  - 输入/图标配置：`DYYYCustomInputView.(h/m)`、`DYYYIconOptionsDialogView.(h/m)`、`DYYYImagePickerDelegate.(h/m)`、`DYYYBackupPickerDelegate.(h/m)`。
  - 弹窗/提示：`DYYYBottomAlertView.(h/m)`、`DYYYConfirmCloseView.(h/m)`、`DYYYAboutDialogView.(h/m)`、`DYYYToast.(h/m)`。
- **浮窗与快捷操作**
  - 漂浮按钮：`DYYYFloatSpeedButton.(h/m)`、`DYYYFloatClearButton.(h/xm)`。
  - 长按/面板：`DYYYLongPressPanel.xm`、`DYYYBottomAlertView.(h/m)`（复用提示）。
- **辅助代理**
  - `DYYYImagePickerDelegate.(h/m)`、`DYYYBackupPickerDelegate.(h/m)`：统一封装系统 Picker 逻辑。
  - `DYYYCustomInputView.(h/m)`：文本输入。
- **ABTest / 远程配置**
  - `DYYYABTestHook.(h/xm)`：抖音 ABTest 注入。

(按上述分组定位 `.h/.m/.xm` 文件，可快速找到对应 UI 或业务类。若新增类，请将文件放入同类路径并在这里补充。)

## DYYYManager 与 DYYYUtils 职权边界（必须遵守）
- **DYYYManager（业务编排层）**
  - 负责“业务流程”与“任务生命周期”：下载发起/取消、批量任务、进度聚合、回调分发、相册保存、失败收敛、资源清理。
  - 允许维护业务状态与映射（如 downloadID、batchID、progress/completion 字典）。
  - 可以调用 `DYYYUtils` 完成底层工具能力，但不应在这里堆积与业务无关的通用工具。
- **DYYYUtils（无状态工具层）**
  - 负责可复用的通用能力：窗口/控制器查找、文件与缓存路径、媒体格式识别与转换、视频音频合成辅助、颜色与文本渲染、通用提示封装。
  - 方法应尽量“输入明确、输出明确”，不保存下载任务状态，不承担批量流程编排。
  - 不依赖 `DYYYManager`，保持单向依赖：`DYYYManager -> DYYYUtils`。
- **落点判定规则**
  - 需求涉及任务状态机、重试/取消、批次统计、统一收尾：放 `DYYYManager`。
  - 需求可被多个模块复用，且不需要业务上下文状态：放 `DYYYUtils`。
  - 若同一功能同时包含“流程编排 + 工具细节”，编排留在 `DYYYManager`，细节下沉为 `DYYYUtils` 新方法。
- **禁止项**
  - 禁止在 `DYYYUtils` 新增下载任务字典、批量计数器、业务开关同步逻辑。
  - 禁止在 `DYYYManager` 新增纯 UI 颜色算法、通用视图遍历、与下载/保存无关的杂项工具函数。

## 开发规范
### 1. 头文件管理
1. **所有新增的抖音类/方法声明必须写入 `AwemeHeaders.h`**，保持集中管理，避免在其他文件里散落声明。
2. 自定义 `UIView` Category 或辅助宏同样放在 `AwemeHeaders.h`，必要时按功能分段并维持已有注释风格。
3. 外部库统一通过已有 `AwemeHeaders.h` 或对应 `.h` 引入，避免重复 import。

### 2. 类与函数组织
1. 项目内业务类一律使用 `DYYY` 前缀，并拆分 `.h/.m`；Logos Hook 保持在 `.xm` 文件。
2. **禁止随意添加全局 C 函数**。如需新能力，请优先扩展已有类（`DYYYManager`、`DYYYSettingsHelper`、`DYYYUtils` 等）或创建新的 `DYYYXXX` 类。
3. 使用 `#pragma mark` 分隔方法区域，公开方法在 `.h`，实现细节留在 `.m`。

### 3. Hook 实现
1. 使用 Logos 语法 `%hook/%orig/%new`。对敏感类（如 `AWESettingBaseViewController`）需要在 `dealloc` 中清理 KVO/通知（示例：`DYYYRemoveRemoteConfigObserver`）。
2. Hook 中新增的手势、子视图必须通过 `objc_setAssociatedObject` 或弱引用管理生命周期（天气控件入口即参考）。
3. 所有 UI 写操作必须在主线程 `dispatch_async(dispatch_get_main_queue(), ^{ ... })`，避免阻塞抖音线程。

### 4. 设置/远程配置
1. 开关值均来自 `NSUserDefaults`，统一使用 `DYYYGetBool/DYYYGetString` 等宏或 `DYYYSettingsHelper` 提供的方法。
2. 复杂依赖关系写入 `+[DYYYSettingsHelper settingsDependencyConfig]`，包括 `dependencies/conditionalDependencies/conflicts/mutualExclusions/valueDependencies/synchronizations`。
3. 远程配置与 ABTest 常量统一在 `DYYYConstants.h`（如 `DYYY_DEFAULT_ABTEST_URL`、`DYYY_REMOTE_CONFIG_FLAG_KEY`、`DYYY_REMOTE_CONFIG_CHANGED_NOTIFICATION`）；新增配置时保持命名一致并添加注释。

### 5. 下载与媒体处理
1. 与下载、文件系统相关的逻辑集中在 `DYYYManager`，复用单例属性（下载队列、任务映射等）。新增流程必须复用 `finalizeDownloadWithFileURL:success:` / `finalizeDownloadWithID:success:fileURL:` 一类公共清理方法。
2. 操作 `PHPhotoLibrary` 前必定请求授权并回到主线程触发 UI（参考 `+saveMedia:mediaType:completion:`）。
3. 转码/合成任务使用 `dispatch_queue_t` 或 `NSOperationQueue`，并通过回调通知 UI 层，避免阻塞 Hook。

### 6. UI 与交互
1. 所有弹窗、输入框、选择视图均继承自 `UIView` 或自定义控件，负责自己的布局和动画，控制器或 Hook 仅负责组装。
2. 新的设置项请沿用 AWESetting 模型（`AWESettingSectionModel`、`AWESettingItemModel`）的构造方式，保持 icon/identifier/type 配置完整。
3. Toast、提示统一调用 `DYYYToast` / `DYYYBottomAlertView`，不要直接 `UIAlertController`。

### 7. 资源与缓存
1. `DYYYCustomAssetsDirectory`、`NSCache` 等资源缓存均用 `dispatch_once` 初始化。新增缓存时务必限制容量或提供清理策略。
2. 自定义图片命名遵循 `DYYYCustomIconFileNameForButtonName` 中的映射逻辑，保持文件夹结构一致。

### 8. 代码风格
1. 注释与 UI 文案使用简体中文，文案集中在对应视图或 `DYYYConstants` 中。
2. 常量使用 `static const` 或 `#define`，根据是否需要编译期常量选择，命名与现有风格一致（如 `kDYYYGlobalTransparencyDidChangeNotification`）。
3. 统一 clang 格式：4 空格缩进，`@interface` 属性使用 `nonatomic, strong/assign/copy` 顺序。

### 9. 调试与日志
1. 允许在调试时使用 `NSLog(@"[DYYY] ...")`，发布前要确保不会过度刷屏。
2. 关键路径失败时发送 UI 反馈（`DYYYToast showToast:`）并写 log，保证用户可感知。

### 10. 最终检查
- 新增 Hook 是否受开关保护并能恢复默认行为。
- 是否确保弱引用/通知/定时器释放（`AWMSafeDispatchTimer` 用于延时场景）。
- 所有新增抖音类声明已写入 `AwemeHeaders.h`。
- 是否在对应类/文件中添加函数，并补充必要头文件 import。

## 常见工作流示例
1. **新增抖音 UI Hook**
   - 在 `AwemeHeaders.h` 声明目标类/属性。
   - 于 `DYYY.xm` 或 `DYYYSettings.xm` 新增 `%hook`，逻辑用 `NSUserDefaults` 开关控制。
   - 如果需要 UI，则在 `DYYY` 前缀视图中实现并在 Hook 内调用。
2. **扩展设置开关**
   - 在 `DYYYSettingsHelper` 为依赖体系补充 key。
   - 在设置面板中创建 `AWESettingItemModel`，identifier 与 `NSUserDefaults` key 对齐。
   - 按职责边界实现功能：业务流程进 `DYYYManager`，通用无状态能力进 `DYYYUtils`。
3. **新增媒体处理能力**
   - 在 `DYYYManager` 内添加对应实例/类方法，并封装异步流程。
   - 通过现有回调（下载完成、进度回调等）向 UI 传递状态。

## 构建与测试（make）
- 本地验证优先执行 `make clean package`（或至少 `make package`），确认 tweak 能编译并生成 `.deb`。
- 需要安装到设备验证时，执行 `make package INSTALL=1`（依赖 `THEOS_DEVICE_IP` 配置），编译完成后会通过 `after-package` 自动推送并 `dpkg -i`。
- 切换不同包方案（roothide/rootless）时，通过 `make package SCHEME=rootless` 之类的命令指定 `SCHEME`，保持与目标设备一致。
- CI 或无人值守只需运行 `GITHUB_ACTIONS=true make package`，脚本会自动跳过安装并将产物放在 `packages/`。
- 本地机器建议通过 `Makefile.local` 覆盖 `THEOS_DEVICE_IP` 等私有配置，避免直接改主 `Makefile`。
- 每次回答涉及编译/测试的需求前，先说明是否已运行上述 `make` 命令以及结果，避免 AI 漏检构建错误。

## 复查清单（AI 回复前自检）
- 需求涉及的类是否已存在，若无应在 `AwemeHeaders.h` 与对应 `DYYY` 类中创建。
- 逻辑是否保持线程安全（UI→主线程，IO→后台）。
- 是否引用了现有工具（`DYYYUtils`、`DYYYSettingsHelper`、`DYYYToast`），避免重复造轮子。
- 是否描述了用户可见的行为及开关，确保可通过设置界面操作。

遵循以上约定可以保证 tweak 的 Hook 安全性和可维护性，也方便 AI Agent 在回答问题或生成补丁时保持统一风格。

- 2.2-9-82：悬浮榜加宽 200→280（只改面板宽度一件，其他不动；基底 -81）。截图那行“12.38万 · 场观 47.6万 · 00:24:04”详情串 11pt 约 174pt，加上名字（2 字约 24pt、5 字约 60pt）与圆点+边距约 38pt，整行要 236–280pt；200 的面板里名字先被压到 0 宽（名字不见了），详情还被截成“00:2…”。修法只改 `DYYYLiveBoardOverlay.m` 的 `kDYYYLiveBoardOverlayWidth` 常量一处（200.0→280.0）：`applySize` 与 `restorePositionInRoot` 都走它，`clampedCenter` 按 `self.bounds` 动态钳制，拖到屏幕右边不会出屏幕，横屏按新宽度钳制；收起、右滑隐藏/左滑恢复、清屏跟藏、小标签/隐形条都不动；名字截断优先级不变（还放不下先截名字、保详情时长）。802,626 字节，只编译通过、未真机测；未验证：截图那行名字回没回来、在线数场观完整时长是不是全显示、横屏宽不宽得离谱。

- 2.2-9-83：彻底砍掉 ABTest 远程配置（只做这一件，其他不动；基底 -82，用户点选“直接砍掉”，不要只改设置）。删了：Makefile 的 DYYY_FILES 里去掉 DYYYABTestHook.xm（文件本身留盘未删，可恢复，%ctor 启动拉取随之消失）；DYYYSettings.xm 里 ABTest 整组 551 行（8 个设置行 + 两段刷新 block + 通知订阅）+ 整个分组头 + #import + dyyyRemoteConfigChangedToken/DYYYRemoveRemoteConfigObserver/dealloc 调用；DYYYConstants.h 里 4 个 ABTest 常量（DYYY_DEFAULT_ABTEST_URL 含 Nathalie 地址等）；AwemeHeaders.h 里 AWEABTestManager 整个 @interface（只被 DYYYABTestHook.xm 引用）。附带：唯一走 ABTest 注入的“修改底栏高度”设置行随之失效（DYYYABTestHook.xm 里的 DYYYResolveTabBarHeightFromSettings 是唯一读 DYYYTabBarHeight 的地方），两处设置行已一并删掉（DYYYSettings.xm、DYYYSettingViewController.m）；DYYY.xm 里帧式底栏逻辑（gCurrentTabBarHeight 等）不动。grep ABTest 后编译代码里只剩 DYYY.xm 两处 HDR 钩子（AWEKnowledgeABTestSettings、AWEFeedABTestServiceObjc，只关 HDR，与远程配置无关）。手机上已有的本地配置文件（Documents/DYYY/abtest_data_fixed.json 等）没动——砍掉后无代码再读它们，留着无害。strings 核对：Nathalie/ABTestDataPatch/github.com/Nathalie/DYYYUseRemoteConfig/DYYYRemoteConfigStateChanged/远程模式/DYYYRemoteConfigURL/abtest_data_fixed/DYYYABTestHook/AWEABTestManager/isRemoteMode/checkForRemoteConfigUpdate 全部 0；11 个直播信息键各 3 次、DYYYFansEnabled 4、DYYYGlassChatInput 0、DYYYLiveBoardOverlayOpacity 2、场观 2、移除 61。788,004 字节，只编译通过、未真机测。

- 2.2-9-84：视频画质默认最高（只做这一件，其他不动；基底 -83，用户点选“做-84，默认开最高画质”）。只改一处：DYYY.xm 主 %ctor 顶部加一行 registerDefaults:@{@"DYYYEnableVideoHighestQuality": @YES}；画质逻辑（AWEVideoModel -playURL/-bitrateModels 挑最高码率档 + 优先原文件地址）一字未动。registerDefaults 只在键未设置过时生效——以前亲手关过开关的保留关；用户这台从没动过开关，装 -84 后默认开。开关显示不用修：设置页两处（AWESetting cellType 6 经 DYYYSettingsHelper.m:474 getUserDefaults、DYYYSettingViewController.m:643）都用 boolForKey 读，注册默认值后自动显示开。直播画质 DYYYLiveQuality 未动，仍默认“自动”。strings 核对：11 个直播信息键各 3 次、DYYYFansEnabled 4、DYYYGlassChatInput 0、DYYYLiveBoardOverlayOpacity 2、DYYYEnableVideoHighestQuality 3、场观 2、移除 61；Nathalie/ABTestDataPatch/远程模式/github.com/Nathalie/Nathalie-Annis/abtest_data_fixed/DYYYABTestHook/AWEABTestManager/isRemoteMode 全部 0（-83 已砍掉的没回来）。788,346 字节，只编译通过、未真机测。

- 2.2-9-85：在线观众面板加人气榜快捷入口 + 悬浮榜默认关闭（只做这两件，其他不动；基底 -84）。用户嫌直播间悬浮面板挡画面。①入口：新文件 `DYYYLiveBoardAudienceEntry.h/.m`（Makefile 已加），钩子在 `DYYYLiveBoardOverlayHooks.xm` 的 IESLiveAudienceViewController 第二个 %hook 块里（viewDidLoad/viewWillAppear/viewDidAppear/didEnterRoom/didPreloadRoom/presentViewController:animated:completion:——viewDidAppear 另加 1 秒延迟重试；present 钩子把 completion 包一层再装）。Install 逻辑：总开关 `DYYYLiveBoardEnabled` 关着不装；在 room VC 的 view 子树、再不行 keyWindow 各 window 子树里找文字是“在线观众”的 UILabel（不要求可见，按钮装进面板自己的容器、面板藏着它跟着藏）；往上最多 3 层找标题栏（宽 ≥200、高 30–120、标题左缘留得出 16+按钮宽+8，否则一路走到房间根视图就错了）；同一标题栏只加一次（tag 987601 + 已装按钮弱引用快路）；按钮只用自己的 Auto Layout 约束（左贴标题栏 +16、纵向与标题对齐、定高 26），不改任何原生 frame、不碰 layoutSubviews、不订阅通知。点按钮：走到最上层已呈现的控制器再 present，榜单 VC 包一层导航控制器 modal 全屏（榜单页自己没有关闭按钮，presenter 在它的 navigationItem 上补一个“关闭”，不改榜单页本身）。②悬浮默认关：只改 `DYYYLiveBoardStore.m` 的 overlayEnabled，未写过由 YES 改 NO；设置页“直播间内悬浮显示”开关直接读它，自动显示关；以前亲手拨过开关的键已写死，改默认值不生效。编译教训：Logos 的 %hook 方法体里 `typeof(self)` 认不出（8 个错），改显式类型 `IESLiveAudienceViewController *`。790,180 字节，只编译通过、未真机测；未验证：面板是不是在 room VC 子树里、还是单独呈现的 sheet（两种都扫了，但真机上标题栏到底长什么样、按钮位置对不对、点进去打不打得开榜单页，都要用户实测）。

- 2.2-9-86：修 -85 真机入口没出现（只做这一件，其他不动；基底 -85）。用户真机截图：在线观众面板正常打开（标题居中、右上“?”、下方贡献榜等 tab），标题左侧空白处没有“人气榜”按钮。断因：-85 的 Install 只挂在 IESLiveAudienceViewController 生命周期上，它是房间 VC 本身、不是观众列表那张 sheet；面板若由别的 VC 呈现、或经 sheet 管理器挂出来，面板真正出现时没有任何 -85 触发点会跑。修法：`DYYYLiveBoardOverlayHooks.xm` 末尾新增 `%hook UIViewController` 两钩——viewDidAppear 先 %orig、仅 presentingViewController 非空（被呈现的 sheet）时装一次；presentViewController:animated:completion: 先 %orig（completion 包一层），呈现完成后对被呈现 VC 和自己各装一次。原 IESLiveAudienceViewController 各钩一字未动；不钩 layoutSubviews、不订阅通知、不改原生 frame。`DYYYLiveBoardAudienceEntry.m` 三处：往上找标题栏由 3 层放宽到 5 层（宽 ≥200 / 高 30–120 的 guard 不变，仍防挂到房间根视图）；label.text 为空时读 attributedText.string 兜底匹配“在线观众”；Install 各结局加 `[DYYY-86]` NSLog（总开关关 / 找不到标题 / 找不到容器附最后候选宽-高-左缘 / 已装上）。悬浮榜默认关、-83 的 ABTest 砍除、其余 -85 行为一律未动。只编译通过、未真机测；未验证：这版抖音在线观众面板到底由哪个 VC 呈现、标题栏隔了几层容器、入口这次能不能出现，都要用户真机裁决；若仍没出现，让用户把日志里 [DYYY-86] 那行发回来定位。

- 2.2-9-87：诊断专用版（只做诊断这一件，其他不动；基底 -86）。用户装 -86 后入口还是没有，并问去哪里看日志——用户不找日志，所以诊断改成设置页里直接能截到的字。做法：`DYYYLiveBoardAudienceEntry.m` 每次 Install 尝试都把结果写进 NSUserDefaults 单条短字符串 `DYYYLiveBoardEntryDiag`（HH:mm:ss + 触发 VC 类名 + 结果：总开关关 / 找不到标题 / 找不到容器(最后候选宽-高-左缘，需左缘) / 已装上；找不到标题时另附实际见到的最多 8 个 UILabel 文字，截 12 字、去重、跳过自己那个“人气榜”按钮）；NSLog 标签由 [DYYY-86] 改 [DYYY-87]。`DYYYLiveBoardUI.m` 榜单设置页第 0 组页脚现读现显“入口诊断：<诊断串>”，无记录时显示“入口诊断：暂无记录，请先打开一次在线观众面板再回来”；只读一条 defaults，不加开关、不改任何行、不弹提示、不订阅通知、不钩 layoutSubviews、不改原生 frame。悬浮榜默认关、-83 的 ABTest 砍除、-86 的触发点与 5 层放宽一律未动。只编译通过、未真机测；用户步骤：进直播间 → 打开“在线观众”面板 → 回设置页 → 直播间人气榜 → 截第 0 组页脚的“入口诊断”那行发回来。


- 2.2-9-88：修 -87 诊断被覆盖 + 入口仍没出现（只做这两件，其他不动；基底 -87）。用户 22:47 的设置页截图是决定性证据：总开关开（正在前台轮询）、悬浮显示关、榜单本身取数正常（木森 20.89 万在线、索图 4.56 万在线），但诊断写“22:47:26 DYYYLiveBoardViewController 找不到标题”，已见标题全是榜单页自己的文字——-86 的通用 viewDidAppear 钩在自家榜单页出现时触发，Install 扫榜单页找不到标题，覆盖了面板打开那一刻的真实诊断。修法：① `DYYYLiveBoardAudienceEntry.m` 新增 1 秒轮询 watcher（StartWatcher/StopWatcher，照抄悬浮榜 tickTimer：1 秒 NSTimer、主 RunLoop、common modes、房间 VC 弱引用、后台不刷；IESLiveAudienceViewController 的 viewDidAppear/didEnterRoom 启动、didCloseRoom/dealloc 停止；每跳调 InstallWithDiag(recordDiag=NO)，找不到标题时不写诊断——面板没开时本来就找不到，写了会冲掉真实诊断；找到标题或已装上时照常记），面板无论何时出现/重建都能装上，不依赖呈现方式；② 自家页面守卫：新增 `DYYYLiveBoardAudienceEntryIsOwnViewController`（类名 DYYY 开头），通用 viewDidAppear/present 两钩与 Install 本身都跳过这类触发 VC，诊断再也不会被自家页面覆盖；③ 快路只认可见的已装按钮（window + 不 hidden + alpha + 祖先链都不 hidden），藏在预建面板容器里的旧按钮不再挡住重装；④ 找不到标题的诊断另记各 window 顶层子视图类名（前 10，去重）与 UILabel 总数，判面板标题是不是根本不是 UILabel（顶层出现 UILynxView/LynxView 之类即 Lynx 渲染）；NSLog 标签由 [DYYY-87] 改 [DYYY-88]。悬浮榜默认关、-83 的 ABTest 砍除、-85/-86/-87 行为（5 层放宽、attributedText 兜底、通用触发点）一律未动。只编译通过、未真机测；用户步骤：装 -88 → 进直播间 → 打开“在线观众”面板 → 回设置页 → 直播间人气榜 → 截第 0 组页脚的“入口诊断”那行发回来。

- 2.2-9-89：修 -88 诊断仍被覆盖 + 入口仍没出现（只做这两件，其他不动；基底 -88）。用户 22:58 的设置页截图是决定性证据：诊断写“22:58:58 AWESettingBaseViewController 找不到标题 | 标签 280个 | 顶层 UITransitionView, MPVolumeView”，已见标题又是设置页文字——-88 只排除了 DYYY 开头的类名，抖音设置宿主 AWESettingBaseViewController 漏网，用户一打开设置读诊断就把它覆盖掉（观察者效应）；且 -88 的 1 秒 watcher 找不到标题时不写诊断，面板打开那一刻到底发生什么仍未知、watcher 是不是在跑也没证据。修法：① 诊断改成最近 3 条环（NSUserDefaults 数组 DYYYLiveBoardEntryDiagRing，最新在前，设置页页脚全显；单条键 DYYYLiveBoardEntryDiag 照常写一份兼容），读诊断的动作最多追加最新一条，面板打开那一刻的记录仍留在环里；② 守卫放宽：类名含 "Setting" 的触发 VC 也跳过安装与诊断（DYYYLiveBoardAudienceEntryIsOwnViewController：DYYY 前缀或含 "Setting"；观众面板 VC 类名里不会有 "Setting"），通用 viewDidAppear/present 两钩与 Install 本身共用这一处判断；③ watcher 心跳：每跳写 "HH:mm:ss 第N跳" + 时间戳（DYYYLiveBoardEntryWatcherBeat/BeatAt，进房间启动时跳数清零），页脚另起一行现显——10 秒内算活跃，否则写上一跳时间与跳数，从来没有心跳就写无心跳；④ 第二锚点：标题找不到时改找面板 tab 标签（文字以“贡献榜”或“高等级”开头，截图里看得见），用它的容器作面板锚点、按钮放标题行左端（leading 16、centerY = tab 中心往上 44pt、定高 26；tab 行容器常是滚动视图会裁剪，往上 5 层内优先找不裁剪的祖先，找不到才退回第一个合尺寸容器；容器 guard 宽 ≥200、高 30–200，整屏高的房间根视图仍挡在外面）；标题路仍是首选，tab 只在标题找不到时兜底；诊断里记明锚点是“标题”还是“贡献榜锚点”。悬浮榜默认关、-83 的 ABTest 砍除、-85/-86/-87/-88 行为（5 层放宽、attributedText 兜底、通用触发点、1 秒 watcher）一律未动。只编译通过、未真机测；用户步骤：装 -89 → 进直播间 → 打开“在线观众”面板等几秒 → 回设置页 → 直播间人气榜 → 截“入口诊断”三行 + watcher 心跳那行发回来。

## GitHub 同步（2026-11-11 用户要求：每次更新完就同步到 GitHub，手动太麻烦）
- 私有库 xiaoqiang8023/dyyy（main 分支），只推源码，不推 packages/、.theos/、*.deb。
- push_files 批量推被 GitHub 403 拒绝（建树接口 Resource not accessible by integration），单文件 create_or_update_file 实测可用；但单文件每次写都要用户点一次允许，141 个文件要点 141 次——首次同步改由用户从自己 Mac 上 git push（一次推完，不用逐个允许）。之后每次新版只推 git diff 出来的改动文件（新增/修改走 create_or_update_file，删除走 delete_file，一般只有 1–5 个文件）。
- 同步状态记在 ~/workspace/dyyy-build-github-sync.json（最后同步的本地 commit SHA + 文件清单），每次同步后更新。
- 顺序：本地改动先 git commit，再同步到 GitHub。
