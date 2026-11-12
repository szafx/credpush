#!/usr/bin/bash
# creddaemon（一次性扫描版）
#
# launchd 每 20 秒跑一次；每次：扫一遍中国移动容器 → 出现「没见过的 JSESSIONID」就
# `uiopen --url credpush://pull?c=<容器id>` → 写心跳 → 退出。
# 跑完就退，不存在常驻进程；空闲时只是一次 bash + 几次 grep（约 20ms）。
#
# 为什么不用编译版（kqueue 常驻）：roothide 会把 Choicy/Crane/AutoPatches 注入进
# /usr/local/bin 下的第三方二进制，初始化阶段会卡住（实测 main 都进不去）；
# 而 /usr/bin/bash 是启动器自带的二进制、注入是安全的 —— 所以这里用 bash。

set -u

APPS="${CREDDAEMON_APPS:-/var/mobile/Containers/Data/Application}"
DIR="/var/mobile/Library/CredDaemon"
STATE="$DIR/state"
LOG="$DIR/daemon.log"
HB="$DIR/heartbeat.json"
TRIG="$DIR/triggered.txt"

DRY="${CREDDAEMON_DRY:-0}"
MIN_GAP="${CREDDAEMON_MIN_GAP:-600}"   # 同一个容器最短触发间隔（秒）——别反复换票把自己顶掉

mkdir -p "$STATE" 2>/dev/null

log() {
    printf '%(%Y-%m-%d %H:%M:%S)T %s\n' -1 "$*" >> "$LOG" 2>/dev/null
}

rotate() {
    local sz
    sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    if [ "${sz:-0}" -gt 262144 ] 2>/dev/null; then
        tail -c 65536 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
    fi
}

containers() {
    local m base sub
    for m in "$APPS"/*/Library/Caches/cn.10086.app; do
        [ -d "$m" ] || continue
        base="${m%/Library/Caches/cn.10086.app}"
        printf '%s\n' "$base"
        for sub in "$base"/Library/___Crane_Containers/*/; do
            [ -d "$sub/Library/Caches/cn.10086.app" ] && printf '%s\n' "${sub%/}"
        done
    done
}

sessions_of() {
    local c="$1" f
    {
        f="$c/Library/Caches/cn.10086.app/Cache.db-wal"
        [ -f "$f" ] && tail -c 1048576 "$f"
        f="$c/Library/Caches/cn.10086.app/Cache.db"
        [ -f "$f" ] && cat "$f"
        f="$c/Library/Cookies/Cookies.binarycookies"
        [ -f "$f" ] && cat "$f"
    } 2>/dev/null | grep -aoE 'JSESSIONID=[0-9a-fA-F-]{36}' | sort -u
}

fire() {
    local cid="$1"
    if [ "$DRY" = "1" ]; then
        log "DRY   trigger $cid"
        return
    fi
    /usr/bin/uiopen --url "credpush://pull?c=$cid" >/dev/null 2>&1
    log "trigger $cid"
}

now=$EPOCHSECONDS
n=0
t=0
while IFS= read -r c; do
    [ -z "$c" ] && continue
    n=$((n + 1))
    cid="${c##*/}"
    st="$STATE/$cid.sessions"

    cur=$(sessions_of "$c")
    [ -z "$cur" ] && continue

    new=""
    if [ -f "$st" ]; then
        new=$(comm -13 "$st" <(printf '%s\n' "$cur") 2>/dev/null)
    fi
    printf '%s\n' "$cur" > "$st.tmp" && mv -f "$st.tmp" "$st"

    [ -z "$new" ] && continue

    # ★ 同一容器最短 10 分钟才触发一次：连续换票会让服务端判「登录状态已过期」
    lt_file="$STATE/$cid.last"
    lt=0
    [ -f "$lt_file" ] && lt=$(cat "$lt_file" 2>/dev/null || echo 0)
    if [ $((now - lt)) -lt "$MIN_GAP" ] 2>/dev/null; then
        continue
    fi

    fresh=0
    while IFS= read -r sid; do
        [ -z "$sid" ] && continue
        grep -qxF "$sid" "$TRIG" 2>/dev/null && continue
        printf '%s\n' "$sid" >> "$TRIG"
        fresh=1
    done <<< "$new"

    if [ "$fresh" = "1" ]; then
        printf '%s
' "$now" > "$lt_file" 2>/dev/null
        fire "$cid"
        t=$((t + 1))
    fi
done < <(containers)

# 触发记录别无限长
tsz=$(stat -c %s "$TRIG" 2>/dev/null || echo 0)
if [ "${tsz:-0}" -gt 40960 ] 2>/dev/null; then
    tail -n 300 "$TRIG" > "$TRIG.tmp" 2>/dev/null && mv -f "$TRIG.tmp" "$TRIG"
fi

rotate

printf '{"ts":%s,"pid":%s,"containers":%s,"triggers":%s,"dry":%s,"mode":"oneshot"}\n' \
    "$now" "$$" "$n" "$t" "$([ "$DRY" = "1" ] && echo true || echo false)" > "$HB.tmp" 2>/dev/null \
    && mv -f "$HB.tmp" "$HB"

exit 0
