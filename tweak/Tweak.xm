// CredHUD —— 移动工具集的悬浮进度窗
//
// 原理：
//   * 注入 SpringBoard，在这里建一个高 windowLevel 的小窗口（盖在所有 App 之上）
//   * 每 0.5 秒读一次 /var/mobile/Library/Preferences/credpush_hud.json
//   * 计时由本窗口自己按 startedAt 走（1 秒一跳），App 只在**换步**时写文件
//
// JSON 格式（由 App 的 HUDWriter 写）：
//   {"visible":true,"title":"195 抓取","step":3,"total":6,
//    "short":"等待登录","detail":"等待登录完成…","startedAt":1750000000.0}
//
// ★ 不用裸 JSON 文件：SpringBoard 的沙盒读不了 /var/mobile/Library/Preferences 下的任意新文件
//   （实测 NSData dataWithContentsOfFile: 返回 nil）。改用 NSUserDefaults 的共享域
//   `com.szafx.credhud` —— 走 cfprefsd，App 和 SpringBoard 都能读写。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static NSString *const kHUDDomain = @"com.szafx.credhud";

static id HUDValue(NSString *key) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)kHUDDomain);
    return v ? (__bridge_transfer id)v : nil;
}

#pragma mark - 视图

@interface CredHUDView : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *stepLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UILabel *timerLabel;
@end

@implementation CredHUDView

- (UILabel *)makeLabel:(CGFloat)size weight:(UIFontWeight)w color:(UIColor *)color mono:(BOOL)mono {
    UILabel *l = [UILabel new];
    l.font = mono ? [UIFont monospacedSystemFontOfSize:size weight:w]
                  : [UIFont systemFontOfSize:size weight:w];
    l.textColor = color;
    l.numberOfLines = 1;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    return l;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.87];
    self.layer.cornerRadius = 16;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.masksToBounds = YES;
    self.layer.borderWidth = 0.5;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
    self.userInteractionEnabled = NO;

    UIColor *accent = [UIColor colorWithRed:0.25 green:0.80 blue:1.0 alpha:1.0];
    self.titleLabel  = [self makeLabel:13 weight:UIFontWeightSemibold color:UIColor.whiteColor mono:NO];
    self.stepLabel   = [self makeLabel:12 weight:UIFontWeightSemibold color:accent mono:YES];
    self.detailLabel = [self makeLabel:11 weight:UIFontWeightRegular
                                 color:[UIColor colorWithWhite:0.72 alpha:1.0] mono:NO];
    self.timerLabel  = [self makeLabel:11 weight:UIFontWeightRegular color:accent mono:YES];
    for (UILabel *l in @[self.titleLabel, self.stepLabel, self.detailLabel, self.timerLabel]) {
        [self addSubview:l];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height, pad = 14;
    self.titleLabel.frame  = CGRectMake(pad, 12, w - pad * 2 - 92, 18);
    self.stepLabel.frame   = CGRectMake(w - pad - 92, 12, 92, 18);
    self.detailLabel.frame = CGRectMake(pad, h - 12 - 16, w - pad * 2 - 76, 16);
    self.timerLabel.frame  = CGRectMake(w - pad - 76, h - 12 - 16, 76, 16);
    self.stepLabel.textAlignment = NSTextAlignmentRight;
    self.timerLabel.textAlignment = NSTextAlignmentRight;
}

@end

#pragma mark - 窗口

@interface CredHUDWindow : UIWindow
@property (nonatomic, strong) CredHUDView *hud;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, strong) NSTimer *tickTimer;
@property (nonatomic, assign) NSTimeInterval startedAt;
@property (nonatomic, assign) BOOL visible;
@end

@implementation CredHUDWindow

// ★ 触摸穿透：窗口本身不参与 hit-test，点击直接落到下面的 App / 桌面。
//   只设 userInteractionEnabled=NO 不够 —— 窗口服务器仍会把该矩形内的触摸投给最上层窗口，
//   必须在窗口级别把 hitTest 直接返回 nil。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return NO;
}

+ (instancetype)shared {
    static CredHUDWindow *w;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ w = [[CredHUDWindow alloc] init]; });
    return w;
}

- (void)setup {
    if (self.rootViewController) return;
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if (ws.activationState == UISceneActivationStateForegroundActive) { scene = ws; break; }
        if (!scene) scene = ws;   // 兜底：先记下第一个
    }
    if (!scene) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self setup]; });
        return;
    }

    self.windowScene = scene;
    CGRect bounds = scene.coordinateSpace.bounds;
    CGFloat w = 300, h = 88;
    self.frame = CGRectMake(bounds.size.width - w - 12, 60, w, h);
    self.windowLevel = UIWindowLevelAlert + 100;   // 压在所有 App 之上
    self.backgroundColor = UIColor.clearColor;
    self.userInteractionEnabled = NO;
    self.hidden = YES;

    self.rootViewController = [UIViewController new];
    self.rootViewController.view.userInteractionEnabled = NO;
    self.hud = [[CredHUDView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    [self.rootViewController.view addSubview:self.hud];

    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self
                                                    selector:@selector(poll) userInfo:nil repeats:YES];
    self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                                    selector:@selector(tick) userInfo:nil repeats:YES];
    NSLog(@"[CredHUD] window ready %@", NSStringFromCGRect(self.frame));
}

- (void)poll {
    NSNumber *vis = HUDValue(@"visible");
    if (![vis isKindOfClass:NSNumber.class] || !vis.boolValue) { [self hide]; return; }
    NSString *title  = HUDValue(@"title");
    NSString *detail = HUDValue(@"detail");
    NSInteger step   = [HUDValue(@"step") integerValue];
    NSInteger total  = [HUDValue(@"total") integerValue] ?: 6;
    double started   = [HUDValue(@"startedAt") doubleValue];

    self.hud.titleLabel.text  = [title isKindOfClass:NSString.class] ? title : @"";
    self.hud.detailLabel.text = [detail isKindOfClass:NSString.class] ? detail : @"";
    self.hud.stepLabel.text   = [NSString stringWithFormat:@"%ld/%ld",
                                 (long)(MIN(step + 1, total)), (long)total];
    self.startedAt = started;

    if (!self.visible) {
        self.visible = YES;
        self.hidden = NO;
    }
    [self tick];
}

- (void)tick {
    if (!self.visible) return;
    NSTimeInterval el = self.startedAt > 0
        ? [[NSDate date] timeIntervalSince1970] - self.startedAt : 0;
    if (el < 0) el = 0;
    int s = (int)el;
    self.hud.timerLabel.text = [NSString stringWithFormat:@"%02d:%02d", s / 60, s % 60];
}

- (void)hide {
    if (!self.visible) return;
    self.visible = NO;
    self.hidden = YES;
}

@end

#pragma mark - 启动（SpringBoard 起来后建窗口）

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[CredHUDWindow shared] setup];
    });
}
