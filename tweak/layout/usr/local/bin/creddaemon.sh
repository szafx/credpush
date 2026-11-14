#!/usr/bin/bash
# creddaemon（一次性扫描版）—— 2026-11-14 加固 + 省电版
#
# launchd 每 20 秒跑一次（StartInterval=20）；每次：
#   ① 先只 stat 目标文件（size / mtime / ctime），和上一轮一样就**几毫秒退出**；
#   ② 变了才读：Cookies.binarycookies 全量（~1.6KB）+ Cache.db-wal / Cache.db 的**尾部**；
#   ③ 出现「没见过的 JSESSIONID」→ 直推（装了 helper 时）或 `uiopen credpush://pull?c=<id>`；
#   ④ 写心跳 / 清理，退出。
#
# ── 2026-11-14 的改动（依据见 项目/凭证链路自愈方案.md）─────────────────────
#   * 整轮限时：这台**没有 perl**（旧方案那层 alarm 一直没生效），改用 /usr/bin/timeout。
#   * stat 门控 + 尾部读取：实测旧版每轮读 ~13MB、耗时 ~49 秒（7 个容器），
#     正常轮次现在降到「几次 stat + 毫秒级」。
#   * 每一步写 run.stage：卡死时看门狗能记下**卡在哪一步**（11-13 那次就是查不出）。
#   * fire 之前先写日志、uiopen 带 timeout；**只有 fire 成功才推进基线和 triggered.txt**
#     （旧版先记后 fire —— uiopen 一失败，这条会话就永远不会再触发）。
#   * 抢锁时如果老实例还活着（超龄）→ 先 kill -9 再接管，绝不并存两个实例。
#   * 可选直推：/var/jb/usr/local/bin/credpush-helper 存在就交给它（不再切 App、
#     不打断用户）。协议：`credpush-helper --container <路径> --id <容器id>`，
#     自己解析 Cookies.binarycookies → 按 cookie 创建时间挑最新会话 → POST /api/cred/push。
#   * 2026-11-14 00:03 的误触发（会话没变、只是 cookie 延迟落盘）：
#     App 会把它**服务端当前持有的那条会话**的前 8 位写进 `hint/<容器id>.sid`；
#     本轮唯一的「新会话」如果就是它，直接记成见过、不 fire（不打断用户）。
#   * 收紧会话正则：原来 `[0-9a-fA-F-]{36}` 会误配 36 位裸 hex
#     （实测把 `76B7145E81C78A302B2506B75793F3E4B998` 当成了会话），改成 UUID 形状。
#
# 环境变量（调试 / 离线测试用）：
#   CREDDAEMON_DRY=1       只看不动（日志写 DRY trigger，不调 uiopen）
#   CREDDAEMON_APPS=...    换一个容器根目录
#   CREDDAEMON_DIR=...     换一个状态目录（本机测试必用）
#   CREDDAEMON_TIMEOUT=60  整轮限时（秒）
#   CREDDAEMON_PUSH=       直推 helper 路径（设成空串 = 不直推）

set -u

# ---- 0. 整轮限时（替代原来那层 perl alarm —— 这台没有 perl）----
#   正常一轮几十毫秒；首次建基线（全量扫）几十秒。超时直接 SIGTERM，3 秒后 SIGKILL。
#   kill 之后 EXIT trap 会放掉锁；万一连 trap 都没跑，看门狗（另一个 label）会兜住。
_TO=$(command -v timeout 2>/dev/null || true)
if [ -z "${CREDDAEMON_ALARMED:-}" ] && [ -n "$_TO" ]; then
    CREDDAEMON_ALARMED=1 exec "$_TO" -k 3 "${CREDDAEMON_TIMEOUT:-60}" \
        /usr/bin/bash "$0" "$@"
fi

# 给单条命令加超时；机器上没有 timeout 时**直接跑**（不能因为缺它就不工作）
run_to() {
    local sec="$1"
    shift
    if [ -n "$_TO" ]; then "$_TO" -k 3 "$sec" "$@"; else "$@"; fi
}

APPS="${CREDDAEMON_APPS:-/var/mobile/Containers/Data/Application}"
DIR="${CREDDAEMON_DIR:-/var/mobile/Library/CredDaemon}"
STATE="$DIR/state"
# 文件名可覆盖只为**离线测试**（本机 TSD 会把子进程写的 .txt 盖章成密文）
LOG="$DIR/${CREDDAEMON_LOG_NAME:-daemon.log}"
HB="$DIR/heartbeat.json"
TRIG="$DIR/${CREDDAEMON_TRIG_NAME:-triggered.txt}"
STAGE="$DIR/run.stage"
LOCK="$DIR/run.lock"
HINT="$DIR/hint"                     # App 写的「服务端当前那条会话」前 8 位
PUSH="${CREDDAEMON_PUSH-/var/jb/usr/libexec/credpush-helper}"   # 注意用 `-`：允许设成空串
DRY="${CREDDAEMON_DRY:-0}"
MIN_GAP="${CREDDAEMON_MIN_GAP:-60}"        # 同一容器最短触发间隔（秒）；真正的去重靠 triggered.txt
WAL_TAIL="${CREDDAEMON_WAL_TAIL:-262144}"  # WAL 只读尾部 256KB
DB_TAIL="${CREDDAEMON_DB_TAIL:-262144}"    # Cache.db 只读尾部 256KB（首次建基线时读全量）

mkdir -p "$STATE" "$HINT" 2>/dev/null || exit 0

T0=$EPOCHSECONDS

log() {
    printf '%(%Y-%m-%d %H:%M:%S)T %s\n' -1 "$*" >> "$LOG" 2>/dev/null
}

# 卡在哪一步 —— 看门狗 kill 之前会把它记进 watchdog.log
stage() {
    printf '%s %s\n' "$$" "$*" > "$STAGE.tmp" 2>/dev/null && mv -f "$STAGE.tmp" "$STAGE" 2>/dev/null
}

rotate() {
    local sz
    sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    if [ "${sz:-0}" -gt 262144 ] 2>/dev/null; then
        tail -c 65536 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
    fi
}

containers() {
    # ★ 每轮 glob 367 个 App 容器目录要 300ms+（还会触发 Crane 子目录 glob），
    #   容器列表十分钟内基本不变 → 缓存起来，过期才重建。
    local cache="$DIR/containers.cache" age
    age=$(( ${now:-$(date +%s)} - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    if [ -s "$cache" ] && [ "${age:-99999}" -lt "${CREDDAEMON_CONTAINER_TTL:-600}" ]; then
        cat "$cache"
        return
    fi
    local m base sub tmp="$cache.tmp"
    : > "$tmp" 2>/dev/null
    for m in "$APPS"/*/Library/Caches/cn.10086.app; do
        [ -d "$m" ] || continue
        base="${m%/Library/Caches/cn.10086.app}"
        printf '%s
' "$base" >> "$tmp"
        for sub in "$base"/Library/___Crane_Containers/*/; do
            [ -d "$sub/Library/Caches/cn.10086.app" ] && printf '%s
' "${sub%/}" >> "$tmp"
        done
    done
    cat "$tmp" 2>/dev/null
    mv -f "$tmp" "$cache" 2>/dev/null
}

# 三个文件的指纹：cookies(size,mtime,ctime) + wal(size) + db(size)
# ★ 为什么用 ctime：同秒内两次写入、大小又恰好一样时，mtime 可能不跳，ctime 会跳。
fp_of() {
    # ★ 2026-11-14 实测：这台机器每次 stat 约 200ms（roothide 路径拦截），
    #   原来每容器 5 次 stat → 一轮 20+ 秒。改成**一次 stat 拿三个字段**。
    #   新会话落在 Cookies.binarycookies（实测），所以用它做唯一指纹；
    #   WAL/DB 只在指纹变了之后才读（sessions_of 里）。
    local c="$1"
    stat -c '%s %Y %Z' "$c/Library/Cookies/Cookies.binarycookies" 2>/dev/null || printf '%s' '- - -'
}

# mode=full：首次建基线（读整个 Cache.db）；mode=tail：只读尾部
# ★ 实测（2026-11-13 main 容器）：最新两条会话在 Cache.db 里分别距文件尾 5KB / 21KB，
#   尾部 256KB 足够覆盖「新会话」；只有很老的历史会话会落在尾部之外 —— 而它们
#   早就在 state/<cid>.sessions 里记过了，不影响「发现新会话」。
sessions_of() {
    local c="$1" mode="${2:-tail}" f
    {
        f="$c/Library/Cookies/Cookies.binarycookies"
        [ -f "$f" ] && cat "$f"
        f="$c/Library/Caches/cn.10086.app/Cache.db-wal"
        [ -f "$f" ] && tail -c "$WAL_TAIL" "$f"
        f="$c/Library/Caches/cn.10086.app/Cache.db"
        if [ -f "$f" ]; then
            if [ "$mode" = "full" ]; then cat "$f"; else tail -c "$DB_TAIL" "$f"; fi
        fi
    } 2>/dev/null | grep -aoE 'JSESSIONID=[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | sort -u
}

# 合并写基线：**只增不减**（尾部扫描看不到的老会话不能从基线里消失，
# 否则哪天它们又滚回尾部就会被当成「新会话」再触发一次）
save_state() {
    local merged
    merged=$( { [ -f "$1" ] && cat "$1"; printf '%s\n' "$2"; } 2>/dev/null \
              | sort -u | tail -n 200 )
    printf '%s\n' "$merged" > "$1.tmp" 2>/dev/null && mv -f "$1.tmp" "$1" 2>/dev/null
}

# 成功返回 0。失败时**不**记 triggered.txt，下一轮重试。
fire() {
    local c="$1" cid="$2"
    if [ "$DRY" = "1" ]; then
        log "DRY   trigger $cid"
        return 0
    fi
    # ① 直推（装了 helper 才走）：不切 App、不打断用户
    if [ -n "$PUSH" ] && [ -x "$PUSH" ]; then
        stage "direct-push $cid"
        log "push  $cid（直推）"
        # ★ 2026-11-14：helper 这个 Theos TOOL 读不了文件系统，所以
        #   ① cookie 由这里（bash/root，读文件正常）cat 出来从 stdin 喂进去；
        #   ② 推送令牌从环境变量传。
        _ck="$c/Library/Cookies/Cookies.binarycookies"
        _tok=$(cat "$DIR/cred_push.token" 2>/dev/null)
        if [ -f "$_ck" ] && CREDD_TOKEN="$_tok" run_to "${CREDDAEMON_PUSH_TIMEOUT:-25}" "$PUSH"                 --stdin --id "$cid" < "$_ck" >> "$DIR/push.log" 2>&1; then
            log "push  $cid OK（直推，不切 App）"
            return 0
        fi
        log "push  $cid 直推失败 → 回退 uiopen"
    fi
    # ② 回退：拉起我们自己的 App 补抓。
    #    ★ 必须带 timeout —— 锁屏 / SpringBoard 忙时 uiopen 会一直阻塞（11-13 那次卡死）。
    stage "uiopen $cid"
    log "fire  $cid（拉起 App）"
    if run_to "${CREDDAEMON_UIOPEN_TIMEOUT:-12}" \
            /usr/bin/uiopen --url "credpush://pull?c=$cid" >/dev/null 2>&1; then
        log "trigger $cid"
        return 0
    fi
    log "★ fire 失败 $cid（uiopen 超时/出错）—— 下一轮重试"
    return 1
}

cleanup() {
    local cur
    cur=$(cat "$LOCK" 2>/dev/null || echo '')
    [ "$cur" = "$$" ] && rm -f "$LOCK" 2>/dev/null
    return 0
}
trap 'cleanup' EXIT
trap 'exit 143' TERM INT HUP

now=$EPOCHSECONDS

# ---- 单实例锁 ----
#   旧版：老实例超龄就直接覆盖锁 → 可能两个实例并存（一起读盘、互相抢）。
#   现在：还活着就 kill -9 再接管；只有确认死了才接管。
if [ -f "$LOCK" ]; then
    old=$(cat "$LOCK" 2>/dev/null || echo 0)
    case "$old" in ''|*[!0-9]*) old=0;; esac
    lage=$(( now - $(stat -c %Y "$LOCK" 2>/dev/null || echo 0) ))
    if [ "$old" -gt 0 ] 2>/dev/null && kill -0 "$old" 2>/dev/null; then
        if [ "${lage:-0}" -lt "${CREDDAEMON_LOCK_OK:-120}" ] 2>/dev/null; then
            exit 0                       # 上一轮还在正常跑：让开
        fi
        log "★ 锁超龄 ${lage}s（pid=$old 仍活着）→ kill -9 后接管"
        stage "takeover old=$old age=${lage}s"
        kill -9 "$old" 2>/dev/null
        sleep 1
        kill -9 "$old" 2>/dev/null
    fi
fi
printf '%s\n' "$$" > "$LOCK" 2>/dev/null
trap 'cleanup' EXIT

n=0          # 容器数
t=0          # 本轮的触发次数
scanned=0    # 真正读了盘的容器数
skipped=0    # 被 stat 门控跳过的容器数

while IFS= read -r c; do
    [ -z "$c" ] && continue
    n=$((n + 1))
    cid="${c##*/}"
    st="$STATE/$cid.sessions"
    fpfile="$STATE/$cid.fp"
    lt_file="$STATE/$cid.last"

    stage "stat $cid"
    cur_fp=$(fp_of "$c")
    old_fp=""
    [ -f "$fpfile" ] && old_fp=$(cat "$fpfile" 2>/dev/null || true)
    if [ -n "$old_fp" ] && [ "$cur_fp" = "$old_fp" ]; then
        skipped=$((skipped + 1))
        continue                          # ★ 什么都没变：直接跳过（省电的关键）
    fi

    # 第一次见这个容器：全量扫一遍建基线（之后只读尾部）
    mode=tail
    [ -f "$st" ] || mode=full
    stage "scan $cid ($mode)"
    scanned=$((scanned + 1))
    cur=$(sessions_of "$c" "$mode")

    if [ -z "$cur" ]; then
        printf '%s' "$cur_fp" > "$fpfile" 2>/dev/null
        continue
    fi

    new=""
    if [ -f "$st" ]; then
        new=$(comm -13 "$st" <(printf '%s\n' "$cur") 2>/dev/null)
    fi
    if [ -z "$new" ]; then
        save_state "$st" "$cur"
        printf '%s' "$cur_fp" > "$fpfile" 2>/dev/null
        continue
    fi

    lt=0
    [ -f "$lt_file" ] && lt=$(cat "$lt_file" 2>/dev/null || echo 0)
    case "$lt" in ''|*[!0-9]*) lt=0;; esac
    if [ $((now - lt)) -lt "$MIN_GAP" ] 2>/dev/null; then
        # ★ 冷却中：**不推进** fp / sessions —— 下一轮还要再看这一批，
        #   否则冷却期间出现的新会话会被永久吞掉（老版本靠这段注释保证，但 fp 没考虑）。
        rm -f "$fpfile" 2>/dev/null
        continue
    fi

    # 还没触发过的会话
    todo=""
    while IFS= read -r sid; do
        [ -z "$sid" ] && continue
        grep -qxF "$sid" "$TRIG" 2>/dev/null && continue
        todo="$todo$sid"$'\n'
    done <<< "$new"

    # ★ 2026-11-14 00:03 的误触发：会话其实没变，只是 cookie 延迟落盘，
    #   于是「第一次见」的其实是服务端早就有的那条。
    #   App 会把「服务端当前持有的会话」前 8 位写进 hint/<cid>.sid —— 对得上就不 fire。
    if [ -n "$todo" ]; then
        hint_sid=""
        [ -f "$HINT/$cid.sid" ] && hint_sid=$(head -c 8 "$HINT/$cid.sid" 2>/dev/null || true)
        if [ -n "$hint_sid" ]; then
            filtered=$(printf '%s' "$todo" | grep -v "^JSESSIONID=$hint_sid" 2>/dev/null || true)
            if [ -z "$filtered" ]; then
                log "skip  $cid（服务端已有 ${hint_sid}…，是落盘延迟造成的误报，不打断用户）"
                printf '%s' "$todo" >> "$TRIG" 2>/dev/null
                save_state "$st" "$cur"
                printf '%s' "$cur_fp" > "$fpfile" 2>/dev/null
                todo=""
            else
                todo="$filtered"
            fi
        fi
    fi

    if [ -n "$todo" ]; then
        if fire "$c" "$cid"; then
            # ★ 只有 fire 成功才推进基线 + 记 triggered；失败下一轮还会重试
            save_state "$st" "$cur"
            printf '%s' "$todo" >> "$TRIG" 2>/dev/null
            printf '%s\n' "$now" > "$lt_file" 2>/dev/null
            t=$((t + 1))
        else
            rm -f "$fpfile" 2>/dev/null
        fi
    else
        save_state "$st" "$cur"
        printf '%s' "$cur_fp" > "$fpfile" 2>/dev/null
    fi
done < <(containers)

# 触发记录别无限长
tsz=$(stat -c %s "$TRIG" 2>/dev/null || echo 0)
if [ "${tsz:-0}" -gt 40960 ] 2>/dev/null; then
    tail -n 300 "$TRIG" > "$TRIG.tmp" 2>/dev/null && mv -f "$TRIG.tmp" "$TRIG"
fi

rotate
stage "done"

printf '{"ts":%s,"pid":%s,"containers":%s,"triggers":%s,"scanned":%s,"skipped":%s,"ms":%s,"dry":%s,"mode":"oneshot","stage":"done"}\n' \
    "$now" "$$" "$n" "$t" "$scanned" "$skipped" \
    "$(( (EPOCHSECONDS - T0) * 1000 ))" \
    "$([ "$DRY" = "1" ] && echo true || echo false)" \
    > "$HB.tmp" 2>/dev/null && mv -f "$HB.tmp" "$HB"

exit 0
