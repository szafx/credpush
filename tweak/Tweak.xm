// CredHUD —— 移动工具集的悬浮进度窗
//
// 原理：
//   * 注入 SpringBoard，在这里建一个高 windowLevel 的小窗口（盖在所有 App 之上）
//   * 每 0.5 秒从 NSUserDefaults 共享域 `com.szafx.credhud` 读一次进度
//     （不用裸 JSON 文件：SpringBoard 沙盒读不了 /var/mobile/Library/Preferences 下的任意新文件）
//   * 计时由本窗口自己按 startedAt 走（1 秒一跳），App 只在**换步**时写一次
//
// 数据（App 的 HUDWriter 写）：
//   visible: true, title: "195 抓取", step: 3, total: 6,
//   detail: "等待登录完成…", startedAt: 1750000000.0
//
// 布局（260×64）：
//   ┌──────────────────────────────┐
//   │ 测试 · 195 抓取      ■ ■ ■ ■ □ □ │
//   │ 等待登录完成…              00:49 │
//   └──────────────────────────────┘
//   方块：已完成=绿，当前=黄，未到=暗灰

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
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UILabel *timerLabel;
@property (nonatomic, strong) NSArray<UIView *> *blocks;
@property (nonatomic, assign) NSInteger step;
@property (nonatomic, assign) NSInteger total;
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
    self.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.88];
    self.layer.cornerRadius = 15;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.masksToBounds = YES;
    self.layer.borderWidth = 0.5;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
    self.userInteractionEnabled = YES;   // 可拖动，需要接收触摸

    UIColor *accent = [UIColor colorWithRed:0.25 green:0.80 blue:1.0 alpha:1.0];
    self.titleLabel  = [self makeLabel:13 weight:UIFontWeightSemibold color:UIColor.whiteColor mono:NO];
    self.detailLabel = [self makeLabel:11 weight:UIFontWeightRegular
                                 color:[UIColor colorWithWhite:0.72 alpha:1.0] mono:NO];
    self.timerLabel  = [self makeLabel:11 weight:UIFontWeightRegular color:accent mono:YES];
    for (UILabel *l in @[self.titleLabel, self.detailLabel, self.timerLabel]) {
        [self addSubview:l];
    }

    NSMutableArray *arr = [NSMutableArray array];
    for (int i = 0; i < 6; i++) {
        UIView *b = [UIView new];
        b.layer.cornerRadius = 2.5;
        b.layer.cornerCurve = kCACornerCurveContinuous;
        [self addSubview:b];
        [arr addObject:b];
    }
    self.blocks = arr;
    self.step = 0;
    self.total = 6;
    [self refreshBlocks];
    return self;
}

- (void)setStep:(NSInteger)step total:(NSInteger)total {
    self.step = MAX(0, step);
    self.total = MAX(1, total);
    [self refreshBlocks];
}

- (void)refreshBlocks {
    UIColor *green  = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
    UIColor *yellow = [UIColor colorWithRed:1.00 green:0.80 blue:0.20 alpha:1.0];
    UIColor *dim    = [UIColor colorWithWhite:1.0 alpha:0.16];
    for (NSInteger i = 0; i < (NSInteger)self.blocks.count; i++) {
        UIView *b = self.blocks[i];
        b.hidden = (i >= self.total);
        if (i < self.step)          b.backgroundColor = green;   // 已完成
        else if (i == self.step)    b.backgroundColor = yellow;  // 当前
        else                        b.backgroundColor = dim;     // 未到
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height, pad = 12;
    CGFloat blockW = 10, gap = 4;
    CGFloat blocksW = 6 * blockW + 5 * gap;       // 80
    CGFloat row1H = 14, row2H = 16;
    CGFloat row2Y = h - pad - row2H;

    self.titleLabel.frame  = CGRectMake(pad, pad + (row1H - 15) / 2.0,
                                        w - pad * 2 - blocksW - 8, 15);
    CGFloat bx = w - pad - blocksW;
    for (NSInteger i = 0; i < (NSInteger)self.blocks.count; i++) {
        self.blocks[i].frame = CGRectMake(bx + i * (blockW + gap),
                                          pad + (row1H - blockW) / 2.0, blockW, blockW);
    }
    self.detailLabel.frame = CGRectMake(pad, row2Y, w - pad * 2 - 56, row2H);
    self.timerLabel.frame  = CGRectMake(w - pad - 50, row2Y, 50, row2H);
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
    CGFloat w = 260, h = 64;
    self.frame = CGRectMake(bounds.size.width - w - 12, 60, w, h);
    self.windowLevel = UIWindowLevelAlert + 100;   // 压在所有 App 之上
    self.backgroundColor = UIColor.clearColor;
    self.userInteractionEnabled = YES;             // 可拖动
    self.hidden = YES;

    self.rootViewController = [UIViewController new];
    self.hud = [[CredHUDView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    [self.rootViewController.view addSubview:self.hud];

    // 拖动：整张卡片都是拖拽区；松手时记住位置（写回共享域，重启/重登后恢复）
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(handlePan:)];
    [self.hud addGestureRecognizer:pan];

    NSNumber *sx = HUDValue(@"hudX");
    NSNumber *sy = HUDValue(@"hudY");
    if ([sx isKindOfClass:NSNumber.class] && [sy isKindOfClass:NSNumber.class]) {
        CGFloat x = [sx doubleValue], y = [sy doubleValue];
        x = MAX(0, MIN(x, bounds.size.width - w));
        y = MAX(0, MIN(y, bounds.size.height - h));
        self.frame = CGRectMake(x, y, w, h);
    }

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
    [self.hud setStep:step total:total];
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

- (void)handlePan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:nil];
    [g setTranslation:CGPointZero inView:nil];
    CGRect f = self.frame;
    f.origin.x += t.x;
    f.origin.y += t.y;
    CGRect b = self.windowScene.coordinateSpace.bounds;
    f.origin.x = MAX(0, MIN(f.origin.x, b.size.width - f.size.width));
    f.origin.y = MAX(0, MIN(f.origin.y, b.size.height - f.size.height));
    self.frame = f;
    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled) {
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kHUDDomain];
        [d setDouble:f.origin.x forKey:@"hudX"];
        [d setDouble:f.origin.y forKey:@"hudY"];
        [d synchronize];
    }
}

@end

#pragma mark - 启动（SpringBoard 起来后建窗口）

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[CredHUDWindow shared] setup];
    });
}
