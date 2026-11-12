// creddaemon — 中国移动容器「新会话」看门狗（roothide / iOS 16）
//
// 和上一版 bash 实现的区别：**不轮询**。用 kqueue 盯住各个 cn.10086.app 容器的
//   Documents/userInfo.a、Library/Caches/cn.10086.app/Cache.db{,-wal}、
//   Library/Cookies/Cookies.binarycookies 以及 Caches 目录本身；
// 平时进程阻塞在 kevent() 里（0% CPU），只有这些文件被写/被替换时才醒。
// 每 30 秒醒一次写心跳（给 App 判断守护进程是否活着）。
//
// 发现「新的 JSESSIONID」→ posix_spawn("/usr/bin/uiopen", "--url", "credpush://pull?c=<容器id>")
// 凭据内容不落盘、不进日志；日志只写容器 id / 触发次数。
//
// 环境变量（调试用）：
//   CREDDAEMON_DRY=1     只看不动（日志里写 DRY trigger，不调 uiopen）
//   CREDDAEMON_APPS=...  换一个容器根目录（测试用）

#define _DARWIN_C_SOURCE 1

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

#define APPS_DEFAULT "/var/mobile/Containers/Data/Application"
#define DIRPATH "/var/mobile/Library/CredDaemon"
#define LOGPATH DIRPATH "/daemon.log"
#define HBPATH DIRPATH "/heartbeat.json"
#define UIO "/usr/bin/uiopen"

#define MAX_CONT 32
#define MAX_FD 8
#define MAX_IDS 64
#define MAX_FIRED 512
#define IDLEN 36
#define TAIL_BYTES (1024 * 1024)
#define SCAN_MIN_SEC 2   // 同一容器两次解析至少隔 2 秒（中国移动前台时文件一直在写）
#define HB_SEC 30        // 心跳 / 容器重扫间隔

typedef struct {
    char base[512];          // 容器根目录
    char cid[64];            // 目录名（容器 id）
    int fds[MAX_FD];
    int nfd;
    char ids[MAX_IDS][IDLEN + 1];
    int nids;
    int baselined;           // 第一次扫到的会话不算「新」
    time_t last_scan;
} cont_t;

static cont_t g_cont[MAX_CONT];
static int g_ncont;
static char g_fired[MAX_FIRED][IDLEN + 1];
static int g_nfired;
static long g_triggers;
static const char *g_apps = APPS_DEFAULT;
static int g_dry;

static void dbg(const char *fmt, ...) {
    FILE *f = fopen("/var/mobile/Documents/creddaemon.dbg", "a");
    if (!f) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc(10, f);
    fclose(f);
}

static void logmsg(const char *fmt, ...) {
    FILE *f = fopen(LOGPATH, "a");
    if (!f) return;
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    fprintf(f, "%04d-%02d-%02d %02d:%02d:%02d ", tmv.tm_year + 1900, tmv.tm_mon + 1,
            tmv.tm_mday, tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static void heartbeat(void) {
    char buf[256];
    int n = snprintf(buf, sizeof buf,
                     "{\"ts\":%ld,\"pid\":%d,\"containers\":%d,\"triggers\":%ld,\"dry\":%s}\n",
                     (long)time(NULL), (int)getpid(), g_ncont, g_triggers,
                     g_dry ? "true" : "false");
    int fd = open(HBPATH, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        ssize_t w = write(fd, buf, (size_t)n);
        (void)w;
        close(fd);
    }
}

static int is_dir(const char *p) {
    struct stat st;
    return stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

static int has_cache(const char *base) {
    char p[600];
    snprintf(p, sizeof p, "%s/Library/Caches/cn.10086.app", base);
    return is_dir(p);
}

static void add_cont(const char *base) {
    for (int i = 0; i < g_ncont; i++)
        if (!strcmp(g_cont[i].base, base)) return;
    if (g_ncont >= MAX_CONT) return;
    cont_t *c = &g_cont[g_ncont++];
    memset(c, 0, sizeof *c);
    snprintf(c->base, sizeof c->base, "%s", base);
    const char *p = strrchr(base, '/');
    snprintf(c->cid, sizeof c->cid, "%s", p ? p + 1 : base);
    for (int i = 0; i < MAX_FD; i++) c->fds[i] = -1;
}

// 扫一遍所有 App 容器（主容器）及其 Crane 分身
static void scan_containers(void) {
    DIR *d = opendir(g_apps);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        char base[512];
        snprintf(base, sizeof base, "%s/%s", g_apps, e->d_name);
        if (!has_cache(base)) continue;
        add_cont(base);
        char sub[600];
        snprintf(sub, sizeof sub, "%s/Library/___Crane_Containers", base);
        DIR *cd = opendir(sub);
        if (!cd) continue;
        struct dirent *ce;
        while ((ce = readdir(cd))) {
            if (ce->d_name[0] == '.') continue;
            char cb[700];
            snprintf(cb, sizeof cb, "%s/%s", sub, ce->d_name);
            if (has_cache(cb)) add_cont(cb);
        }
        closedir(cd);
    }
    closedir(d);
}

static int hexdash(unsigned char ch) {
    return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') ||
           (ch >= 'A' && ch <= 'F') || ch == '-';
}

// 从文件尾部 TAIL_BYTES 里抠 JSESSIONID（36 位 hex/短横），去重塞进 out
static void collect_ids(const char *file, char out[MAX_IDS][IDLEN + 1], int *n) {
    int fd = open(file, O_RDONLY);
    if (fd < 0) return;
    off_t sz = lseek(fd, 0, SEEK_END);
    if (sz <= 0) {
        close(fd);
        return;
    }
    size_t want = (size_t)sz > (size_t)TAIL_BYTES ? (size_t)TAIL_BYTES : (size_t)sz;
    char *buf = malloc(want);
    if (!buf) {
        close(fd);
        return;
    }
    if (lseek(fd, sz - (off_t)want, SEEK_SET) < 0) {
        free(buf);
        close(fd);
        return;
    }
    ssize_t got = read(fd, buf, want);
    close(fd);
    if (got <= 0) {
        free(buf);
        return;
    }
    static const char KEY[] = "JSESSIONID=";
    const size_t klen = sizeof KEY - 1;
    for (ssize_t i = 0; i + (ssize_t)klen + IDLEN <= got; i++) {
        if (memcmp(buf + i, KEY, klen) != 0) continue;
        const char *p = buf + i + klen;
        int ok = 1;
        for (int k = 0; k < IDLEN; k++)
            if (!hexdash((unsigned char)p[k])) {
                ok = 0;
                break;
            }
        if (!ok) continue;
        char id[IDLEN + 1];
        memcpy(id, p, IDLEN);
        id[IDLEN] = 0;
        int dup = 0;
        for (int k = 0; k < *n; k++)
            if (!memcmp(out[k], id, IDLEN + 1)) {
                dup = 1;
                break;
            }
        if (!dup && *n < MAX_IDS) memcpy(out[(*n)++], id, IDLEN + 1);
    }
    free(buf);
}

static int id_in(char list[MAX_IDS][IDLEN + 1], int n, const char *id) {
    for (int i = 0; i < n; i++)
        if (!memcmp(list[i], id, IDLEN + 1)) return 1;
    return 0;
}

static int already_fired(const char *id) {
    for (int i = 0; i < g_nfired; i++)
        if (!memcmp(g_fired[i], id, IDLEN + 1)) return 1;
    return 0;
}

static void mark_fired(const char *id) {
    if (g_nfired >= MAX_FIRED) {
        memmove(g_fired[0], g_fired[1], sizeof(g_fired[0]) * (MAX_FIRED - 1));
        g_nfired = MAX_FIRED - 1;
    }
    memcpy(g_fired[g_nfired++], id, IDLEN + 1);
}

static void fire(const char *cid) {
    if (g_dry) {
        logmsg("DRY   trigger %s", cid);
        return;
    }
    char url[256];
    snprintf(url, sizeof url, "credpush://pull?c=%s", cid);
    char *argv[] = { (char *)UIO, (char *)"--url", url, NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, UIO, NULL, NULL, argv, environ);
    if (rc == 0) {
        (void)waitpid(pid, NULL, 0);
        logmsg("trigger %s", cid);
    } else {
        logmsg("trigger %s FAILED rc=%d", cid, rc);
    }
}

// 读一次会话集合，和上次比；有「没触发过的」新会话就 fire
static void scan_cont(cont_t *c) {
    time_t now = time(NULL);
    if (now - c->last_scan < SCAN_MIN_SEC) return;
    c->last_scan = now;

    static char cur[MAX_IDS][IDLEN + 1];
    int nc = 0;
    char p[600];
    snprintf(p, sizeof p, "%s/Library/Caches/cn.10086.app/Cache.db-wal", c->base);
    collect_ids(p, cur, &nc);
    snprintf(p, sizeof p, "%s/Library/Caches/cn.10086.app/Cache.db", c->base);
    collect_ids(p, cur, &nc);
    snprintf(p, sizeof p, "%s/Library/Cookies/Cookies.binarycookies", c->base);
    collect_ids(p, cur, &nc);
    if (nc == 0) {
        // 空容器也算「已知基线」：之后登录产生的新会话才会被当成新的
        c->baselined = 1;
        return;
    }

    int fresh = 0;
    if (c->baselined) {
        for (int i = 0; i < nc; i++) {
            if (id_in(c->ids, c->nids, cur[i])) continue;
            if (already_fired(cur[i])) continue;
            mark_fired(cur[i]);
            fresh = 1;
        }
    }

    c->nids = 0;
    for (int i = 0; i < nc && c->nids < MAX_IDS; i++)
        memcpy(c->ids[c->nids++], cur[i], IDLEN + 1);

    if (!c->baselined) {
        c->baselined = 1;
        return;
    }
    if (fresh) {
        fire(c->cid);
        g_triggers++;
    }
}

static void unwatch(cont_t *c) {
    for (int i = 0; i < c->nfd; i++) {
        if (c->fds[i] >= 0) close(c->fds[i]);
        c->fds[i] = -1;
    }
    c->nfd = 0;
}

static void watch_one(int kq, cont_t *c, const char *path, int isdir) {
    if (c->nfd >= MAX_FD) return;
    int fd = open(path, O_EVTONLY);
    if (fd < 0) return;
    struct kevent ev;
    uint32_t flags = NOTE_WRITE | NOTE_EXTEND | NOTE_DELETE | NOTE_RENAME;
    if (isdir) flags |= NOTE_ATTRIB;
    EV_SET(&ev, fd, EVFILT_VNODE, EV_ADD | EV_CLEAR, flags, 0, c);
    if (kevent(kq, &ev, 1, NULL, 0, NULL) == 0) {
        c->fds[c->nfd++] = fd;
    } else {
        close(fd);
    }
}

static void watch_cont(int kq, cont_t *c) {
    char p[600];
    snprintf(p, sizeof p, "%s/Library/Caches/cn.10086.app", c->base);
    watch_one(kq, c, p, 1);   // 目录：文件被新建/替换时也能醒
    snprintf(p, sizeof p, "%s/Library/Caches/cn.10086.app/Cache.db-wal", c->base);
    watch_one(kq, c, p, 0);
    snprintf(p, sizeof p, "%s/Library/Caches/cn.10086.app/Cache.db", c->base);
    watch_one(kq, c, p, 0);
    snprintf(p, sizeof p, "%s/Library/Cookies/Cookies.binarycookies", c->base);
    watch_one(kq, c, p, 0);
    snprintf(p, sizeof p, "%s/Documents/userInfo.a", c->base);
    watch_one(kq, c, p, 0);
}

int main(void) {
    dbg("main enter uid=%d euid=%d", (int)getuid(), (int)geteuid());
    int mk = mkdir(DIRPATH, 0755);
    dbg("mkdir rc=%d errno=%d", mk, errno);
    if (getenv("CREDDAEMON_DRY") && !strcmp(getenv("CREDDAEMON_DRY"), "1")) g_dry = 1;
    if (getenv("CREDDAEMON_APPS")) g_apps = getenv("CREDDAEMON_APPS");

    int kq = kqueue();
    dbg("kqueue kq=%d errno=%d", kq, errno);
    if (kq < 0) {
        logmsg("kqueue() failed errno=%d", errno);
        return 1;
    }

    logmsg("start pid=%d (kqueue) apps=%s dry=%d", (int)getpid(), g_apps, g_dry);

    scan_containers();
    dbg("scan_containers n=%d errno=%d", g_ncont, errno);
    for (int i = 0; i < g_ncont; i++) {
        watch_cont(kq, &g_cont[i]);
        scan_cont(&g_cont[i]);   // 首次扫描：只记基线，不 fire
    }
    heartbeat();
    dbg("heartbeat done errno=%d", errno);

    time_t last_hb = time(NULL);
    struct timespec ts = { HB_SEC, 0 };

    for (;;) {
        struct kevent evs[16];
        int n = kevent(kq, NULL, 0, evs, 16, &ts);
        if (n < 0) {
            if (errno == EINTR) continue;
            logmsg("kevent errno=%d，1s 后重试", errno);
            sleep(1);
            continue;
        }
        if (n == 0) {
            // 超时：重扫容器列表（Crane 新建分身能被认出来）+ 心跳
            scan_containers();
            for (int i = 0; i < g_ncont; i++) {
                // 每 30 秒把所有 watch 重建一遍：文件被替换/删除后能自动补挂
                unwatch(&g_cont[i]);
                watch_cont(kq, &g_cont[i]);
                scan_cont(&g_cont[i]);
            }
            heartbeat();
            last_hb = time(NULL);
            continue;
        }
        for (int i = 0; i < n; i++) {
            cont_t *c = (cont_t *)evs[i].udata;
            if (!c) continue;
            if (evs[i].flags & EV_ERROR) continue;
            // 文件可能被删/改名（App 登出、WAL 重置）：全部重新 watch 一遍，
            // 顺手读一次（读是节流的，不会因为写得频繁而狂读）
            scan_cont(c);
            int needs_reopen = (evs[i].fflags & (NOTE_DELETE | NOTE_RENAME)) ? 1 : 0;
            if (needs_reopen) {
                unwatch(c);
                watch_cont(kq, c);
            }
        }
        if (time(NULL) - last_hb >= HB_SEC) {
            heartbeat();
            last_hb = time(NULL);
        }
    }
    return 0;
}
