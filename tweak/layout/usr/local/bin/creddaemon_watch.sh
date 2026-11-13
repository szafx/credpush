#!/usr/bin/bash
# creddaemon_watch —— 「凭证守护进程卡死」的看门狗（**独立 launchd label**，StartInterval=30）
#
# 为什么必须是另一个 label：
#   launchd 对**同一个** label 不会并发拉起 —— 11-13 22:44 就是这么停摆 65 分钟的：
#   主实例卡住不退，launchd 以为它还在跑，于是再也不拉新的。两个不同 label 之间
#   没有这个限制，所以看门狗自己每 30 秒跑一次，专门收拾这种情况。
#
# 做三件事（都写日志、都把结果写进 watchdog.json 给 App 显示）：
#   ① 锁超龄（默认 >90 秒）且持锁 PID 还活着 → kill -9（先把它卡在哪一步记下来）
#   ② 锁是僵尸（PID 已不在）→ 直接删
#   ③ 心跳超龄（默认 >5 分钟）→ launchctl kickstart 一次（10 分钟节流）
#
# 安全：只杀「锁文件和 run.stage 里记的同一个 PID」——绝不会误杀别人。
#
# 环境变量（测试用）：CREDDAEMON_DIR / WATCH_STALE / WATCH_HB / WATCH_KICK_GAP
set -u

DIR="${CREDDAEMON_DIR:-/var/mobile/Library/CredDaemon}"
LOCK="$DIR/run.lock"
HB="$DIR/heartbeat.json"
STAGE="$DIR/run.stage"
WLOG="$DIR/watchdog.log"
WSTATE="$DIR/watchdog.json"
KICKFILE="$DIR/watchdog.kick"
STALE="${WATCH_STALE:-90}"          # 锁超过这么久没放 → 判卡死
HB_STALE="${WATCH_HB:-300}"         # 心跳超过这么久没更新 → 判停摆
KICK_GAP="${WATCH_KICK_GAP:-600}"   # 两次 kickstart 至少隔这么久
JOB="${WATCH_JOB:-user/501/com.szafx.creddaemon}"
DRY="${WATCH_DRY:-0}"               # 1 = 只记日志，不真动手（离线测试用）

mkdir -p "$DIR" 2>/dev/null || exit 0
now=${EPOCHSECONDS:-$(date +%s)}

log() {
    printf '%(%Y-%m-%d %H:%M:%S)T %s\n' -1 "$*" >> "$WLOG" 2>/dev/null
}

# 日志别无限长
sz=$(stat -c %s "$WLOG" 2>/dev/null || echo 0)
if [ "${sz:-0}" -gt 262144 ] 2>/dev/null; then
    tail -c 65536 "$WLOG" > "$WLOG.tmp" 2>/dev/null && mv -f "$WLOG.tmp" "$WLOG"
fi

killed_pid=0
killed_stage=""
kicked=0
lock_age=-1
hb_age=-1

# ---------------------------------------------------------------- ① / ② 锁
if [ -f "$LOCK" ]; then
    pid=$(cat "$LOCK" 2>/dev/null || echo 0)
    case "$pid" in ''|*[!0-9]*) pid=0;; esac
    lock_age=$(( now - $(stat -c %Y "$LOCK" 2>/dev/null || echo "$now") ))

    # run.stage 的第一列是写它的进程号 —— 用来确认「这个 PID 确实是我们的 daemon」
    stage_pid=0
    if [ -f "$STAGE" ]; then
        stage_pid=$(head -1 "$STAGE" 2>/dev/null | awk '{print $1}')
        case "$stage_pid" in ''|*[!0-9]*) stage_pid=0;; esac
    fi
    stage_text=$(head -1 "$STAGE" 2>/dev/null | cut -c1-160)

    alive=0
    [ "$pid" -gt 0 ] 2>/dev/null && kill -0 "$pid" 2>/dev/null && alive=1

    if [ "$alive" = 1 ] && [ "$lock_age" -ge "$STALE" ]; then
        if [ "$stage_pid" = "$pid" ] || [ "$stage_pid" = 0 ]; then
            log "★ 卡死：pid=$pid 持锁 ${lock_age}s（stage: ${stage_text:-?}）→ kill -9"
            if [ "$DRY" = "1" ]; then
                log "DRY   不真杀"
            else
                kill -9 "$pid" 2>/dev/null
                i=0
                while [ $i -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
                    sleep 1
                    i=$((i + 1))
                done
                kill -9 "$pid" 2>/dev/null
            fi
            killed_pid=$pid
            killed_stage="$stage_text"
            if [ "$DRY" != "1" ] && ! kill -0 "$pid" 2>/dev/null; then
                # 只有确认死了才删锁；否则宁留给主脚本的 EXIT trap 处理
                cur=$(cat "$LOCK" 2>/dev/null || echo '')
                [ "$cur" = "$pid" ] && rm -f "$LOCK" 2>/dev/null
                log "   已杀掉并清锁"
            elif [ "$DRY" != "1" ]; then
                log "   ⚠ kill -9 之后 pid=$pid 仍活着（D 状态？）—— 锁保留，下一轮再试"
            fi
        else
            log "锁超龄 ${lock_age}s，但 run.stage 记的是 pid=$stage_pid（不是 $pid）—— 不敢杀"
        fi
    elif [ "$alive" = 0 ] && [ "$lock_age" -ge "$STALE" ]; then
        log "清理僵尸锁：pid=$pid 已不在（锁龄 ${lock_age}s）"
        [ "$DRY" = "1" ] || rm -f "$LOCK" 2>/dev/null
    fi
fi

# ---------------------------------------------------------------- ③ 心跳
if [ -f "$HB" ]; then
    ts=$(sed -n 's/.*"ts":\([0-9][0-9]*\).*/\1/p' "$HB" 2>/dev/null | head -1)
    case "$ts" in ''|*[!0-9]*) ts=0;; esac
    if [ "$ts" -gt 0 ] 2>/dev/null; then
        hb_age=$(( now - ts ))
    fi
fi

if [ "$hb_age" -ge "$HB_STALE" ] 2>/dev/null; then
    last_kick=0
    [ -f "$KICKFILE" ] && last_kick=$(cat "$KICKFILE" 2>/dev/null || echo 0)
    case "$last_kick" in ''|*[!0-9]*) last_kick=0;; esac
    if [ $(( now - last_kick )) -ge "$KICK_GAP" ] 2>/dev/null; then
        log "★ 心跳 ${hb_age}s 没更新 → launchctl kickstart -k $JOB"
        if [ "$DRY" = "1" ]; then
            log "DRY   不真 kickstart"
            kicked=1
        else
            printf '%s\n' "$now" > "$KICKFILE" 2>/dev/null
            if /usr/bin/launchctl kickstart -k "$JOB" >> "$WLOG" 2>&1; then
                kicked=1
                log "   kickstart OK"
            else
                log "   kickstart 失败（domain/label 可能不对）—— 需要人工看一眼"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------- 状态落盘（App 读）
prev_kicks=0
[ -f "$WSTATE" ] && prev_kicks=$(sed -n 's/.*"kicks":\([0-9][0-9]*\).*/\1/p' "$WSTATE" 2>/dev/null | head -1)
case "$prev_kicks" in ''|*[!0-9]*) prev_kicks=0;; esac
[ "$kicked" = 1 ] && prev_kicks=$((prev_kicks + 1))

# ★ 落盘前清掉控制字符和控制引号 —— 否则 watchdog.json 不是合法 JSON（踩过）
clean() {
    printf '%s' "$1" | tr -d '\000-\037' | tr '"' "'" | cut -c1-160
}
printf '{"t":"%(%Y-%m-%d %H:%M:%S)T","ts":%s,"lock_age":%s,"heartbeat_age":%s,"killed_pid":%s,"killed_stage":"%s","kicks":%s,"stage":"%s"}\n' \
    -1 "$now" "$lock_age" "$hb_age" "$killed_pid" \
    "$(clean "$killed_stage")" "$prev_kicks" \
    "$(clean "$(head -1 "$STAGE" 2>/dev/null)")" \
    > "$WSTATE.tmp" 2>/dev/null && mv -f "$WSTATE.tmp" "$WSTATE" 2>/dev/null

exit 0
