#!/usr/bin/env bash
# vps-traffic-guard: traffic guard for self-hosted proxy VPS
#
#   check    伪装域名体检：检查 Xray / sing-box 的 REALITY 回落目标（target/dest）是否指向 Cloudflare 等 CDN，或微软、苹果的域名。
#            指向 CDN 时，鉴权失败的连接会被原样转发过去，VPS 可能被人当成中转偷跑流量。
#   install  每天发一份流量额度（剩余流量 ÷ 账期剩余天数），额度内满速；
#            当天用完就限速，次日 0 点自动恢复。SSH 端口永不限速。
#   ports    可选：从外网关掉对公网开放、又明确认得出用不到的端口（数据库、缓存等）。
#            SSH、80/443、面板、代理和认不出的程序一律保留；改完 3 分钟内不确认就自动撤销。
#
# 依赖：bash 4+、iproute2（ip、tc、ss）、GNU date、awk、systemd；关端口另需 nft 或 iptables。
# 不上报任何数据；只有 check 会向被检查的目标网站发一次 HTTPS 请求（有 curl 时）。

set -uo pipefail

VERSION="0.2.2"
APP="vps-traffic-guard"

CONF="${VTG_CONF:-/etc/$APP.conf}"
STATE_DIR="${VTG_STATE_DIR:-/var/lib/$APP}"
STATE="$STATE_DIR/state"
EVENTS="$STATE_DIR/events.log"
SYS_NET="${VTG_SYS_NET:-/sys/class/net}"
TC="${VTG_TC:-tc}"
LOCK="${VTG_LOCK:-/run/$APP.lock}"
BIN_PATH="${VTG_BIN:-/usr/local/bin/$APP}"
UNIT_DIR="${VTG_UNIT_DIR:-/etc/systemd/system}"
NFT="${VTG_NFT:-nft}"
IPT="${VTG_IPT:-iptables}"
IP6T="${VTG_IP6T:-ip6tables}"
PORTS_FILE="${VTG_PORTS_FILE:-/etc/$APP.ports}"   # 已确认关闭的端口（单独存放，写坏了也不影响限流）
PENDING="$STATE_DIR/ports.pending"                 # 试用中、等待确认的端口改动
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"

GB=1000000000   # 1 GB = 10^9 字节；商家若按 GiB 算，这样换算只会更保守
MIN_KBIT=64     # 限速下限
HARD_PCT=98     # 限速速率按“满速跑到账期结束也不超过套餐 98%”封顶
QH="7e5d"       # 本工具 tc 根队列的句柄（十六进制）。只认这个句柄，别人的规则一律不碰
FW_TABLE="vps_traffic_guard"   # 本工具的 nft 表名；iptables 用下面的链名。只认这两个名字，别人的规则一律不碰
FW_CHAIN="VTG_PORTS"
FW_RESCUE=180   # 关端口后多少秒内不确认就自动撤销（VTG_FW_RESCUE 仅供测试缩短，最少 40）
[[ ${VTG_FW_RESCUE:-} =~ ^[0-9]{2,4}$ ]] && (( 10#$VTG_FW_RESCUE >= 40 )) && FW_RESCUE=$((10#$VTG_FW_RESCUE))
FW_ASK=$((FW_RESCUE - 30))   # 交互确认的等待秒数（比自动撤销早一点，自己先撤）
QUIET_EVENTS=0

CONF_KEYS="IFACE QUOTA_GB RESET_DAY COUNT_MODE THRESHOLD THROTTLE_KBIT EXEMPT_PORTS"
STATE_KEYS="LAST_IFACE LAST_RX LAST_TX CYCLE_RDAY CYCLE_START CYCLE_RX CYCLE_TX CYCLE_OFFSET DAY DAY_START_BILLED DAY_BUDGET STATUS APPLIED APPLIED_KBIT APPLIED_PORTS PAUSED CLEANUP_IFACE"
PORTS_KEYS="PORTS_IFACE CLOSED_PORTS"

# Cloudflare 官方公布的 IP 段：https://www.cloudflare.com/ips-v4 、https://www.cloudflare.com/ips-v6
CF_V4="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
CF_V6="2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32"

# ---------------------------------------------------------------- 通用工具

die()  { printf '错误：%s\n' "$*" >&2; exit 1; }
warn() { printf '提示：%s\n' "$*" >&2; }
now()  { if [[ -n ${VTG_NOW:-} ]]; then printf '%s\n' "$VTG_NOW"; else date +%s; fi; }
fmt_gb()   { awk -v b="$1" 'BEGIN { printf "%.1f GB", b / 1e9 }'; }
fmt_mbps() { awk -v k="$1" 'BEGIN { printf "%.2f Mbps", k / 1000 }'; }
fmt_day()  { date -d "@$1" '+%Y-%m-%d'; }
is_uint()  { [[ $1 =~ ^[0-9]+$ ]]; }
is_int()   { [[ $1 =~ ^-?[0-9]+$ ]]; }

mode_name() {
  case $1 in
    both) echo "双向（进+出）" ;;
    out)  echo "仅出站" ;;
    in)   echo "仅入站" ;;
    max)  echo "进、出取较大值" ;;
    *)    echo "$1" ;;
  esac
}

require_root() {
  [[ ${VTG_SKIP_ROOT:-0} == 1 ]] || (( EUID == 0 )) || die "请用 root 运行（先 sudo -i）"
}

need_cmds() {
  local c miss=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || miss+=("$c"); done
  (( ${#miss[@]} == 0 )) || die "缺少命令：${miss[*]}。ip/tc 在 Debian/Ubuntu 属于 iproute2 包；RHEL/Rocky/Alma 8+ 的 tc 要装 iproute-tc 包"
}

ask() { # 变量名 提示 默认值
  local __var=$1 __prompt=$2 __def=$3 __ans=""
  read -r -p "$__prompt [$__def]: " __ans || true
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

gb_to_bytes() {
  [[ $1 =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  awk -v g="$1" -v u="$GB" 'BEGIN { printf "%.0f\n", g * u }'
}

log_event() {
  (( QUIET_EVENTS == 1 )) && return 0
  local msg="$*" ts
  ts=$(date -d "@$(now)" '+%F %T')
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s %s\n' "$ts" "$msg" >> "$EVENTS" 2>/dev/null
  if [[ -f $EVENTS ]] && (( $(wc -l < "$EVENTS") > 400 )); then
    tail -n 200 "$EVENTS" > "$EVENTS.tmp" && mv -f "$EVENTS.tmp" "$EVENTS"
  fi
  if command -v logger >/dev/null 2>&1; then logger -t "$APP" -- "$msg" 2>/dev/null; fi
  return 0
}

# 所有会读写状态的命令都先拿锁、再读状态，避免两个进程拿着旧状态互相覆盖
take_lock() {
  command -v flock >/dev/null 2>&1 || return 0
  { exec 9>"$LOCK"; } 2>/dev/null || return 0
  flock -w 30 9 || die "另一个 $APP 进程正在运行，稍后再试"
}

# ---------------------------------------------------------------- 配置与状态（只按白名单解析，不 source）

kv_load() { # 文件 允许的键
  local file=$1 allowed=" $2 " line k v
  local re='^([A-Z_]+)=("([^"#]*)"|([^"#[:space:]]*))[[:space:]]*(#.*)?$'
  local ok='^[-A-Za-z0-9_.:/ ]*$'
  [[ -r $file ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line =~ $re ]] || continue
    k=${BASH_REMATCH[1]}
    if [[ ${BASH_REMATCH[2]} == \"* ]]; then v=${BASH_REMATCH[3]}; else v=${BASH_REMATCH[4]}; fi
    [[ $v =~ $ok ]] || continue
    v=${v%"${v##*[! ]}"}   # 去掉行尾空格
    [[ $allowed == *" $k "* ]] && printf -v "$k" '%s' "$v"
  done < "$file"
  return 0
}

kv_save() { # 文件 键...
  local file=$1 tmp k
  shift
  tmp="$file.tmp.$$"
  { for k in "$@"; do printf '%s="%s"\n' "$k" "${!k-}"; done; } > "$tmp" && mv -f "$tmp" "$file"
}

save_state() {
  mkdir -p "$STATE_DIR" || return 1
  # shellcheck disable=SC2086
  kv_save "$STATE" $STATE_KEYS
}

init_conf_defaults() {
  IFACE="" QUOTA_GB="" RESET_DAY="" COUNT_MODE=both THRESHOLD=90 THROTTLE_KBIT=auto EXEMPT_PORTS=22
}

init_state_defaults() {
  LAST_IFACE="" LAST_RX="" LAST_TX="" CYCLE_RDAY="" CYCLE_START=0 CYCLE_RX=0 CYCLE_TX=0 CYCLE_OFFSET=0
  DAY="" DAY_START_BILLED=0 DAY_BUDGET=0 STATUS=normal APPLIED=0 APPLIED_KBIT=0 APPLIED_PORTS="" PAUSED=0
  CLEANUP_IFACE="" OLD_IFACE=""
}

validate_conf() {
  [[ $IFACE =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || { echo "网卡名不对：'$IFACE'"; return 1; }
  [[ $QUOTA_GB =~ ^[0-9]{1,7}$ ]] && (( 10#$QUOTA_GB >= 1 && 10#$QUOTA_GB <= 1000000 )) \
    || { echo "套餐流量应为 1~1000000 的整数（GB）"; return 1; }
  [[ $RESET_DAY =~ ^[0-9]{1,2}$ ]] && (( 10#$RESET_DAY >= 1 && 10#$RESET_DAY <= 31 )) \
    || { echo "重置日应为 1~31"; return 1; }
  [[ $COUNT_MODE =~ ^(both|out|in|max)$ ]] || { echo "计费方式只能是 both / out / in / max"; return 1; }
  [[ $THRESHOLD =~ ^[0-9]{1,3}$ ]] && (( 10#$THRESHOLD >= 50 && 10#$THRESHOLD <= 100 )) \
    || { echo "触发线应为 50~100（百分比）"; return 1; }
  if [[ $THROTTLE_KBIT != auto ]]; then
    [[ $THROTTLE_KBIT =~ ^[0-9]{1,8}$ ]] && (( 10#$THROTTLE_KBIT >= MIN_KBIT )) \
      || { echo "限速应为 auto 或不小于 $MIN_KBIT 的整数（kbit/s）"; return 1; }
  fi
  local p n=0
  for p in $EXEMPT_PORTS; do
    [[ $p =~ ^[0-9]{1,5}$ ]] && (( 10#$p >= 1 && 10#$p <= 65535 )) || { echo "端口不对：'$p'"; return 1; }
    n=$((n + 1))
  done
  (( n > 0 )) || { echo "至少要保留一个不限速端口（SSH）"; return 1; }
}

normalize_conf() {
  local p out=""
  QUOTA_GB=$((10#$QUOTA_GB)) RESET_DAY=$((10#$RESET_DAY)) THRESHOLD=$((10#$THRESHOLD))
  [[ $THROTTLE_KBIT == auto ]] || THROTTLE_KBIT=$((10#$THROTTLE_KBIT))
  for p in $EXEMPT_PORTS; do out+="$((10#$p)) "; done
  EXEMPT_PORTS=${out% }
}

sanitize_state() {
  local k
  for k in CYCLE_START CYCLE_RX CYCLE_TX DAY_START_BILLED DAY_BUDGET APPLIED APPLIED_KBIT PAUSED; do
    is_uint "${!k}" || printf -v "$k" '%s' 0
  done
  is_int "$CYCLE_OFFSET" || CYCLE_OFFSET=0
  is_uint "$LAST_RX" || LAST_RX=""
  is_uint "$LAST_TX" || LAST_TX=""
  is_uint "$CYCLE_RDAY" || CYCLE_RDAY=""
  [[ $LAST_IFACE =~ ^[A-Za-z0-9_.-]{0,15}$ ]] || LAST_IFACE=""
  [[ $CLEANUP_IFACE =~ ^[A-Za-z0-9_.-]{0,15}$ ]] || CLEANUP_IFACE=""
  [[ $APPLIED_PORTS =~ ^[0-9\ ]*$ ]] || APPLIED_PORTS=""
  [[ $DAY =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || DAY=""
  case $STATUS in normal|throttled|paused|error) ;; *) STATUS=normal ;; esac
}

load_all() {
  init_conf_defaults
  init_state_defaults
  kv_load "$CONF" "$CONF_KEYS" || return 1
  local err
  err=$(validate_conf) || { warn "配置有误（$CONF）：$err"; return 1; }
  normalize_conf
  kv_load "$STATE" "$STATE_KEYS" || true
  sanitize_state
}

write_config() {
  local tmp="$CONF.tmp.$$"
  cat > "$tmp" <<EOF || return 1
# $APP 配置文件。改完下一分钟自动生效。
# 统计哪块网卡的流量
IFACE="$IFACE"
# 套餐每月流量，单位 GB（1 GB = 10^9 字节）
QUOTA_GB="$QUOTA_GB"
# 每月几号重置流量（1~31；当月没有这一天就按月底算）
RESET_DAY="$RESET_DAY"
# 计费方式：both=双向(进+出)  out=仅出站  in=仅入站  max=进出取较大值
COUNT_MODE="$COUNT_MODE"
# 用到套餐的百分之多少就不再发每日额度（给计数误差留余量）
THRESHOLD="$THRESHOLD"
# 超额后的限速，单位 kbit/s。auto = 按“限速状态满速跑一整天也不超过日均额度”自动计算
THROTTLE_KBIT="$THROTTLE_KBIT"
# 永不限速的本机端口（默认是 SSH 端口），空格分隔
EXEMPT_PORTS="$EXEMPT_PORTS"
EOF
  mv -f "$tmp" "$CONF"
}

# ---------------------------------------------------------------- 账期与额度

day_epoch() { # YYYY-MM-DD -> 当天 0 点；该时区当天没有 0 点（夏令时在 0 点切换）就取 1 点
  date -d "$1 00:00:00" +%s 2>/dev/null || date -d "$1 01:00:00" +%s
}
ymd_epoch() { day_epoch "$(printf '%04d-%02d-%02d' "$1" "$2" "$3")"; }

reset_epoch() { # 年 月 -> 该月重置日 0 点（当月没有这一天就取月底）
  local dim d=$RESET_DAY
  # 用 UTC 算当月天数：与时区、夏令时无关（时间后面紧跟 +1 会被 GNU date 当成时区，所以不写时间）
  dim=$(date -u -d "$(printf '%04d-%02d-01' "$1" "$2") +1 month -1 day" +%d)
  dim=$((10#$dim))
  (( d > dim )) && d=$dim
  ymd_epoch "$1" "$2" "$d"
}

cycle_bounds() { # 时间戳 -> CB_START CB_NEXT
  local t=$1 y m this
  y=$(date -d "@$t" +%Y); m=$(date -d "@$t" +%m)
  y=$((10#$y)); m=$((10#$m))
  this=$(reset_epoch "$y" "$m")
  if (( t >= this )); then
    CB_START=$this
    if (( m == 12 )); then CB_NEXT=$(reset_epoch $((y + 1)) 1); else CB_NEXT=$(reset_epoch "$y" $((m + 1))); fi
  else
    CB_NEXT=$this
    if (( m == 1 )); then CB_START=$(reset_epoch $((y - 1)) 12); else CB_START=$(reset_epoch "$y" $((m - 1))); fi
  fi
}

midnight()   { day_epoch "$(date -d "@$1" +%F)"; }
days_left()  { local d=$(( (CB_NEXT - $(midnight "$1") + 43200) / 86400 )); (( d < 1 )) && d=1; echo "$d"; }
cycle_days() { local d=$(( (CB_NEXT - CB_START + 43200) / 86400 )); (( d < 1 )) && d=1; echo "$d"; }

billed_raw() {
  case $COUNT_MODE in
    both) echo $(( CYCLE_RX + CYCLE_TX )) ;;
    out)  echo "$CYCLE_TX" ;;
    in)   echo "$CYCLE_RX" ;;
    max)  echo $(( CYCLE_RX > CYCLE_TX ? CYCLE_RX : CYCLE_TX )) ;;
  esac
}
billed()      { local b=$(( $(billed_raw) + CYCLE_OFFSET )); (( b < 0 )) && b=0; echo "$b"; }
mult()        { if [[ $COUNT_MODE == both ]]; then echo 2; else echo 1; fi; }
limit_bytes() { echo $(( QUOTA_GB * GB / 100 * THRESHOLD )); }

calibrate_used() { # 字节：让“本期已用”等于商家面板的数字
  CYCLE_OFFSET=$(( $1 - $(billed_raw) ))
}

day_budget() { # 时间戳 已用 -> 今日额度
  local lim
  lim=$(limit_bytes)
  if (( $2 >= lim )); then echo 0; else echo $(( (lim - $2) / $(days_left "$1") )); fi
}

throttle_cap_kbit() {
  if [[ $THROTTLE_KBIT != auto ]]; then echo "$THROTTLE_KBIT"; return; fi
  # 限速状态下满速跑 24 小时，计费流量也不超过日均额度
  local k=$(( $(limit_bytes) / $(cycle_days) / ($(mult) * 86400) * 8 / 1000 ))
  (( k < MIN_KBIT )) && k=$MIN_KBIT
  echo "$k"
}

effective_kbit() { # 时间戳 已用
  local cap safe remain secs
  cap=$(throttle_cap_kbit)
  remain=$(( QUOTA_GB * GB / 100 * HARD_PCT - $2 ))
  secs=$(( CB_NEXT - $1 )); (( secs < 60 )) && secs=60
  if (( remain <= 0 )); then safe=$MIN_KBIT; else safe=$(( remain / ($(mult) * secs) * 8 / 1000 )); fi
  (( safe < MIN_KBIT )) && safe=$MIN_KBIT
  echo $(( cap < safe ? cap : safe ))
}

# ---------------------------------------------------------------- 计数

read_counters() {
  local d="$SYS_NET/$IFACE/statistics"
  [[ -r $d/rx_bytes && -r $d/tx_bytes ]] || return 1
  CUR_RX=$(<"$d/rx_bytes"); CUR_TX=$(<"$d/tx_bytes")
  CUR_RX=${CUR_RX//[!0-9]/}; CUR_TX=${CUR_TX//[!0-9]/}
  [[ -n $CUR_RX && -n $CUR_TX ]]
}

update_counters() { # 时间戳（只改内存里的变量，不碰 tc、不写文件）
  local t=$1 drx dtx
  read_counters || return 1
  cycle_bounds "$t"
  if [[ $CYCLE_RDAY != "$RESET_DAY" ]]; then
    # 首次运行或改了重置日：对齐账期，不清零
    CYCLE_RDAY=$RESET_DAY CYCLE_START=$CB_START DAY=""
  elif (( CB_START > CYCLE_START )); then
    log_event "新账期开始（$(fmt_day "$CB_START") ~ $(fmt_day "$CB_NEXT")），本期计数清零"
    CYCLE_START=$CB_START CYCLE_RX=0 CYCLE_TX=0 CYCLE_OFFSET=0 DAY=""
  fi
  # 系统时间被往回调（CB_START < CYCLE_START）时什么都不做，保留计数
  OLD_IFACE=""
  if [[ $LAST_IFACE != "$IFACE" ]]; then
    [[ -n $LAST_IFACE ]] && OLD_IFACE=$LAST_IFACE   # 换了网卡：旧网卡上的限速稍后撤掉
    LAST_RX="" LAST_TX=""                           # 重新取基准
  fi
  if [[ -n $LAST_RX && -n $LAST_TX ]]; then
    drx=$(( CUR_RX - LAST_RX )); dtx=$(( CUR_TX - LAST_TX ))
    (( drx < 0 )) && drx=$CUR_RX    # 计数器归零：重启或网卡重建
    (( dtx < 0 )) && dtx=$CUR_TX
    CYCLE_RX=$(( CYCLE_RX + drx )); CYCLE_TX=$(( CYCLE_TX + dtx ))
  fi
  LAST_IFACE=$IFACE LAST_RX=$CUR_RX LAST_TX=$CUR_TX
}

# ---------------------------------------------------------------- 限速（tc）
# 是不是本工具的规则，只看网卡上的实际情况（根队列是 htb 且句柄为 $QH:），不依赖状态文件。

root_qdisc_of() { # 网卡 -> 根队列的 "类型 句柄"，例如 "fq 0:"、"htb 7e5d:"
  "$TC" qdisc show dev "$1" 2>/dev/null |
    awk '$1 == "qdisc" { for (i = 4; i <= 6 && i <= NF; i++) if ($i == "root") { print $2 " " $3; exit } }'
}

tc_clear_dev() { # 网卡：只删本工具的根队列；删除后内核自动换回系统默认队列
  [[ $(root_qdisc_of "$1") == "htb $QH:" ]] || return 0
  "$TC" qdisc del dev "$1" root 2>/dev/null
}

tc_clear() {
  tc_clear_dev "$IFACE" || return 1
  APPLIED=0 APPLIED_KBIT=0 APPLIED_PORTS=""
}

tc_clear_all_ours() { # 扫描所有网卡，撤掉本工具加的限速（配置损坏、卸载时用）
  local d
  for d in "$SYS_NET"/*; do
    [[ ${d##*/} =~ ^[A-Za-z0-9_.-]{1,15}$ ]] && tc_clear_dev "${d##*/}"
  done
  return 0
}

tc_build() { # kbit
  local k=$1 p
  "$TC" qdisc replace dev "$IFACE" root handle "$QH:" htb default 20 || return 1
  if ! { "$TC" class add dev "$IFACE" parent "$QH:" classid "$QH:10" htb rate 10gbit quantum 60000 &&
         "$TC" class add dev "$IFACE" parent "$QH:" classid "$QH:20" htb rate "${k}kbit" ceil "${k}kbit" quantum 1514; }; then
    tc_clear; return 1
  fi
  "$TC" qdisc add dev "$IFACE" parent "$QH:20" handle 7e5e: fq_codel 2>/dev/null || true
  for p in $EXEMPT_PORTS; do
    if ! { "$TC" filter add dev "$IFACE" parent "$QH:" protocol ip prio 1 u32 match ip sport "$p" 0xffff flowid "$QH:10" &&
           "$TC" filter add dev "$IFACE" parent "$QH:" protocol ipv6 prio 2 u32 match ip6 sport "$p" 0xffff flowid "$QH:10"; }; then
      tc_clear; return 1
    fi
  done
  APPLIED=1 APPLIED_KBIT=$k APPLIED_PORTS=$EXEMPT_PORTS
}

has_custom_qdisc() { # 网卡上有没有人手动加的队列（句柄不是 0:；ingress/clsact 不受根队列替换影响，不算）
  "$TC" qdisc show dev "$1" 2>/dev/null |
    awk '$1 == "qdisc" && $2 != "ingress" && $2 != "clsact" && $3 != "0:" { found = 1 } END { exit !found }'
}

tc_apply() { # kbit；返回 0 成功，1 tc 失败，2 网卡上是别人的队列规则
  local k=$1 rq diff
  rq=$(root_qdisc_of "$IFACE")
  if [[ $rq == "htb $QH:" ]]; then
    if (( APPLIED == 1 && APPLIED_KBIT > 0 )) && [[ $APPLIED_PORTS == "$EXEMPT_PORTS" ]]; then
      diff=$(( k > APPLIED_KBIT ? k - APPLIED_KBIT : APPLIED_KBIT - k ))
      if (( diff * 10 > APPLIED_KBIT )); then
        "$TC" class change dev "$IFACE" parent "$QH:" classid "$QH:20" htb rate "${k}kbit" ceil "${k}kbit" quantum 1514 || return 1
        APPLIED_KBIT=$k
      fi
      return 0
    fi
    # 是本工具的规则，但状态对不上（改了端口、状态文件丢失等）：删掉重建
    "$TC" qdisc del dev "$IFACE" root 2>/dev/null || return 1
  elif has_custom_qdisc "$IFACE"; then
    return 2    # 根队列或其下的子队列句柄不是 0:，说明有人手动加过队列（内核默认队列的句柄都是 0:）
  fi
  tc_build "$k"
}

enforce() { # 期望状态 kbit 原因
  local want=$1 kbit=$2 why=${3:-} prev=$STATUS rc
  if [[ $want == throttled ]]; then
    tc_apply "$kbit"; rc=$?
    case $rc in
      0) STATUS=throttled ;;
      2) STATUS=error
         [[ $prev == error ]] || log_event "网卡 $IFACE 上已有别人加的 tc 队列（$(root_qdisc_of "$IFACE")），为避免破坏它，本工具不做限速" ;;
      *) STATUS=error
         [[ $prev == error ]] || log_event "设置 tc 限速失败（网卡 $IFACE）。OpenVZ/LXC 等容器型 VPS 可能不允许改队列；RHEL 系需安装 iproute-tc" ;;
    esac
  elif tc_clear; then
    STATUS=$want
  else
    STATUS=error
    [[ $prev == error ]] || log_event "撤销限速失败（网卡 $IFACE），下一分钟重试"
  fi
  [[ $STATUS == "$prev" ]] && return 0
  case $STATUS in
    throttled)
      if [[ $why == limit ]]; then
        log_event "本期已用到触发线：限速 ${kbit} kbit/s 直到账期重置（不限速端口：$EXEMPT_PORTS）"
      else
        log_event "今日额度已用完：限速 ${kbit} kbit/s，明天 0 点恢复（不限速端口：$EXEMPT_PORTS）"
      fi ;;
    normal) log_event "已恢复满速" ;;
    paused) log_event "已暂停限速（仍在计数）" ;;
  esac
  return 0
}

evaluate() { # 时间戳：决定满速还是限速，并落实到 tc
  local t=$1 b lim today used want=normal kbit=0 why="" first=0
  if [[ -n ${OLD_IFACE:-} ]]; then
    CLEANUP_IFACE=$OLD_IFACE first=1
    APPLIED=0 APPLIED_KBIT=0 APPLIED_PORTS="" OLD_IFACE=""
  fi
  if [[ -n $CLEANUP_IFACE ]]; then    # 换网卡后撤掉旧网卡上的限速；失败就每分钟重试
    if tc_clear_dev "$CLEANUP_IFACE"; then
      CLEANUP_IFACE=""
    elif (( first )); then
      log_event "撤销旧网卡 $CLEANUP_IFACE 上的限速失败，之后每分钟重试"
    fi
  fi
  cycle_bounds "$t"
  b=$(billed); lim=$(limit_bytes); today=$(date -d "@$t" +%F)
  if [[ $DAY != "$today" ]]; then
    DAY=$today DAY_START_BILLED=$b DAY_BUDGET=$(day_budget "$t" "$b")
  fi
  used=$(( b - DAY_START_BILLED )); (( used < 0 )) && used=0
  if (( PAUSED == 1 )); then
    want=paused
  elif (( used >= DAY_BUDGET )); then
    want=throttled
    kbit=$(effective_kbit "$t" "$b")
    if (( b >= lim )); then why=limit; else why=day; fi
  fi
  enforce "$want" "$kbit" "$why"
}

# ---------------------------------------------------------------- 状态显示

print_status() {
  local t b lim used left extra=""
  t=$(now); cycle_bounds "$t"; b=$(billed); lim=$(limit_bytes)
  used=$(( b - DAY_START_BILLED )); (( used < 0 )) && used=0
  left=$(days_left "$t")
  (( CYCLE_OFFSET != 0 )) && extra="，另含面板校准 $(fmt_gb "$CYCLE_OFFSET")"
  echo "== $APP $VERSION 状态 =="
  echo "网卡：$IFACE    计费方式：$(mode_name "$COUNT_MODE")    不限速端口：$EXEMPT_PORTS"
  echo "账期：$(fmt_day "$CB_START") ~ $(fmt_day "$CB_NEXT")（含今天还剩 $left 天；每日额度按系统时区 0 点切换）"
  echo "本期已用：$(fmt_gb "$b") / 套餐 $(fmt_gb $(( QUOTA_GB * GB )))，触发线 ${THRESHOLD}% = $(fmt_gb "$lim")"
  echo "  本机计数：入站 $(fmt_gb "$CYCLE_RX")，出站 $(fmt_gb "$CYCLE_TX")$extra"
  if [[ $COUNT_MODE == both ]]; then
    echo "  双向计费下代理每走 1 GB 约记 2 GB，本期约合代理用量 $(fmt_gb $(( b / 2 )))"
  fi
  echo "今日额度：$(fmt_gb "$DAY_BUDGET")    今日已用：$(fmt_gb "$used")"
  case $STATUS in
    normal) echo "当前状态：满速" ;;
    throttled)
      if (( b >= lim )); then
        echo "当前状态：本期已到触发线，限速 ${APPLIED_KBIT} kbit/s（$(fmt_mbps "$APPLIED_KBIT")），直到 $(fmt_day "$CB_NEXT") 重置"
      else
        echo "当前状态：今日额度已用完，限速 ${APPLIED_KBIT} kbit/s（$(fmt_mbps "$APPLIED_KBIT")），明天 0 点恢复"
      fi ;;
    paused) echo "当前状态：已暂停限速（仍在计数）。恢复：$APP resume" ;;
    error)  echo "当前状态：限速操作没能完成，见下方事件" ;;
  esac
  ports_status_line
  if [[ -s $EVENTS ]]; then
    echo "最近事件："
    tail -n 5 "$EVENTS" | sed 's/^/  /'
  fi
  echo "本机计数和商家面板会有出入，对不上时校准：$APP set-used <面板显示的本期已用 GB>"
}

# ---------------------------------------------------------------- 命令：tick / status / set-used / pause / resume

cmd_tick() {
  take_lock
  if ! load_all; then
    tc_clear_all_ours   # 配置缺失或写坏了：宁可撤掉限速，也不留下撤不掉的规则
    exit 1
  fi
  local t
  t=$(now)
  if ! update_counters "$t"; then
    warn "读取网卡 $IFACE 的流量计数失败（网卡名写错了？），先撤掉本工具加的限速"
    tc_clear_all_ours
    exit 1
  fi
  evaluate "$t"
  save_state
}

cmd_status() {
  local t
  if [[ ${VTG_SKIP_ROOT:-0} == 1 ]] || (( EUID == 0 )); then
    take_lock
    load_all || die "还没安装，或配置文件 $CONF 有误。安装：bash $APP.sh install"
    t=$(now)
    if update_counters "$t"; then evaluate "$t"; save_state; fi
  else
    load_all || die "还没安装，或配置文件 $CONF 有误"
  fi
  print_status
}

cmd_set_used() {
  require_root
  (( $# == 1 )) || die "用法：$APP set-used <商家面板显示的本期已用 GB>"
  local bytes t
  bytes=$(gb_to_bytes "$1") || die "请填数字，例如 123.4"
  take_lock
  load_all || die "还没安装，或配置文件 $CONF 有误"
  t=$(now)
  update_counters "$t" || die "读取网卡 $IFACE 的流量计数失败"
  calibrate_used "$bytes"
  DAY=""    # 今日额度按校准后的数字重算
  log_event "已按面板校准本期已用为 $(fmt_gb "$bytes")，今日额度重新计算"
  evaluate "$t"
  save_state
  print_status
}

cmd_pause_resume() { # 1=暂停 0=恢复
  require_root
  take_lock
  load_all || die "还没安装，或配置文件 $CONF 有误"
  local t
  t=$(now)
  if ! update_counters "$t"; then
    tc_clear_all_ours
    die "读取网卡 $IFACE 的流量计数失败（网卡名写错了？）。已撤掉本工具加的限速，请检查 $CONF"
  fi
  PAUSED=$1
  evaluate "$t"
  save_state
  if (( $1 == 1 )); then echo "已暂停限速（仍在计数）。恢复：$APP resume"; else print_status; fi
}

# ---------------------------------------------------------------- 命令：install / uninstall

stdin_is_tty() { [[ -t 0 ]]; }   # 单独成函数，测试里可以替换

iface_looks_virtual() { # 默认路由走 WARP / WireGuard / 隧道 / 容器网桥时，按它统计流量多半不对
  case ${1,,} in
    wg*|warp*|cloudflarewarp*|tun*|tap*|tailscale*|zt*|docker*|br-*|veth*|virbr*|lo) return 0 ;;
  esac
  return 1
}

detect_iface() {
  local i
  i=$(ip -4 route show default 2>/dev/null | awk '{ for (n = 1; n < NF; n++) if ($n == "dev") { print $(n + 1); exit } }')
  [[ -z $i ]] && i=$(ip -6 route show default 2>/dev/null | awk '{ for (n = 1; n < NF; n++) if ($n == "dev") { print $(n + 1); exit } }')
  echo "$i"
}

detect_ssh_ports() { # 合并多个来源，宁多勿少
  local p="" sshd_bin u
  sshd_bin=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)
  if [[ -x $sshd_bin ]]; then
    p+=$("$sshd_bin" -T 2>/dev/null | awk '$1 == "port" { print $2 } $1 == "listenaddress" { n = split($2, a, ":"); if (n > 1) print a[n] }')$'\n'
  fi
  if [[ -n ${SSH_CONNECTION:-} ]]; then
    p+=$(awk '{ print $4 }' <<< "$SSH_CONNECTION")$'\n'    # 当前这个 SSH 会话的服务端端口
  fi
  if command -v systemctl >/dev/null 2>&1; then           # socket 激活（如 Ubuntu 22.10+ 的 ssh.socket）
    for u in ssh.socket sshd.socket; do
      p+=$(systemctl show -p Listen "$u" 2>/dev/null | grep -oE ':[0-9]+ \(Stream\)' | grep -oE '[0-9]+')$'\n'
    done
  fi
  if command -v ss >/dev/null 2>&1; then
    p+=$(ss -tlnp 2>/dev/null | awk 'NR > 1 && /"sshd/ { n = split($4, a, ":"); print a[n] }')$'\n'
  fi
  p+=$(live_ssh_ports)$'\n'
  p=$(printf '%s' "$p" | grep -E '^[0-9]{1,5}$' | sort -un | tr '\n' ' ')
  p=${p% }
  echo "${p:-22}"
}

live_ssh_ports() { # 正在使用中的 SSH 连接的服务端端口
  # SSH_CONNECTION 在 sudo -i / su - 之后会被清掉，所以再从已建立的 sshd 连接里找
  awk '{ print $4 }' <<< "${SSH_CONNECTION:-}"
  if command -v ss >/dev/null 2>&1; then
    ss -tnp 2>/dev/null | awk '$1 == "ESTAB" && /"sshd(-session)?"/ { n = split($4, a, ":"); print a[n] }'
  fi
}

add_current_ssh_port() { # 正在用的 SSH 端口必须在豁免列表里
  local cur
  for cur in $(live_ssh_ports | grep -E '^[0-9]{1,5}$' | sort -un); do
    [[ " $EXEMPT_PORTS " == *" $cur "* ]] && continue
    EXEMPT_PORTS="${EXEMPT_PORTS:+$EXEMPT_PORTS }$cur"
    warn "检测到正在使用的 SSH 端口 $cur，已自动加入不限速端口"
  done
  return 0
}

write_units() {
  cat > "$UNIT_DIR/$APP.service" <<EOF || return 1
[Unit]
Description=VPS traffic guard: count traffic and enforce the daily budget

[Service]
Type=oneshot
ExecStart=$BIN_PATH tick
EOF
  cat > "$UNIT_DIR/$APP.timer" <<EOF || return 1
[Unit]
Description=Run VPS traffic guard every minute

[Timer]
OnBootSec=20s
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
  cat > "$UNIT_DIR/$APP-save.service" <<EOF || return 1
[Unit]
Description=VPS traffic guard: save counters before shutdown
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=$BIN_PATH tick

[Install]
WantedBy=multi-user.target
EOF
}

load_state_fresh() {
  init_state_defaults
  if [[ -r $STATE ]]; then kv_load "$STATE" "$STATE_KEYS"; sanitize_state; fi
}

cmd_install() {
  require_root
  need_cmds ip "$TC" awk date systemctl sort
  local o_quota="" o_reset="" o_mode="" o_used="" o_thr="" o_throttle="" o_iface="" o_ports="" yes=0 o_close=0
  while (( $# )); do
    case $1 in
      -y|--yes) yes=1; shift; continue ;;
      --close-ports) o_close=1; shift; continue ;;
      --quota|--reset-day|--mode|--used|--threshold|--throttle|--iface|--exempt-ports)
        (( $# >= 2 )) || die "$1 后面需要一个值" ;;
      *) die "未知参数：$1（$APP help 查看用法）" ;;
    esac
    case $1 in
      --quota) o_quota=$2 ;;      --reset-day) o_reset=$2 ;;   --mode) o_mode=$2 ;;
      --used) o_used=$2 ;;        --threshold) o_thr=$2 ;;     --throttle) o_throttle=$2 ;;
      --iface) o_iface=$2 ;;      --exempt-ports) o_ports=$2 ;;
    esac
    shift 2
  done

  init_conf_defaults
  local had_conf=0 had_state=0 interactive=0
  kv_load "$CONF" "$CONF_KEYS" && had_conf=1
  [[ -r $STATE ]] && had_state=1
  [[ -n $o_iface ]] && IFACE=$o_iface
  [[ -z $IFACE ]] && IFACE=$(detect_iface)
  if [[ -n $o_ports ]]; then EXEMPT_PORTS=$o_ports; elif (( had_conf == 0 )); then EXEMPT_PORTS=$(detect_ssh_ports); fi
  [[ -n $o_quota ]] && QUOTA_GB=$o_quota
  [[ -n $o_reset ]] && RESET_DAY=$o_reset
  [[ -n $o_mode ]] && COUNT_MODE=$o_mode
  [[ -n $o_thr ]] && THRESHOLD=$o_thr
  [[ -n $o_throttle ]] && THROTTLE_KBIT=$o_throttle

  (( yes == 0 )) && stdin_is_tty && interactive=1
  if (( interactive )); then
    echo "== 安装 $APP（直接回车 = 用方括号里的值）=="
    [[ -n $o_quota ]] || ask QUOTA_GB "套餐每月流量（GB）" "${QUOTA_GB:-1000}"
    [[ -n $o_reset ]] || ask RESET_DAY "每月几号重置流量（看商家面板，1~31）" "${RESET_DAY:-1}"
    [[ -n $o_mode ]]  || ask COUNT_MODE "计费方式 both=双向(进+出) out=仅出站 in=仅入站 max=取大值" "$COUNT_MODE"
    if [[ -z $o_used ]]; then
      if (( had_state )); then
        ask o_used "本期商家面板显示已用多少 GB（回车 = 保留现有计数）" "keep"
        [[ $o_used == keep ]] && o_used=""
      else
        ask o_used "本期商家面板显示已用多少 GB" "0"
      fi
    fi
    # 网卡按默认路由自动识别，新手不用懂这个词；认不出来、或认到的像是 WARP 这类虚拟网卡时才问
    local why_ask=""
    if [[ -z $o_iface ]]; then
      if [[ -z $IFACE || ! -r $SYS_NET/$IFACE/statistics/rx_bytes ]]; then
        why_ask="没能自动找到 VPS 连外网用的网卡（流量就是按它统计的）。"
      elif iface_looks_virtual "$IFACE"; then
        why_ask="自动找到的网卡是 $IFACE，看起来是 WARP、WireGuard 这类虚拟网卡，按它统计流量可能不准。"
      fi
    fi
    if [[ -n $why_ask ]]; then
      echo "$why_ask"
      echo "运行 ip -br addr 可以查看：带公网 IP 的那一行，最前面的名字就是（常见 eth0、ens3）。"
      ask IFACE "网卡名" "${IFACE:-eth0}"
    fi
    [[ -n $o_ports ]] || ask EXEMPT_PORTS "永不限速的端口（已自动填好你的 SSH 登录端口，一般直接回车）" "$EXEMPT_PORTS"
  else
    [[ -n $QUOTA_GB && -n $RESET_DAY ]] || die "非交互安装需要 --quota 和 --reset-day"
  fi
  [[ -z $o_used ]] && (( had_state == 0 )) && o_used=0
  add_current_ssh_port

  local err used_bytes="" t b cap
  err=$(validate_conf) || die "$err"
  normalize_conf
  [[ -r $SYS_NET/$IFACE/statistics/rx_bytes ]] || die "找不到网卡 $IFACE（用 ip link 查看网卡名，--iface 指定）"
  if [[ -n $o_used ]]; then used_bytes=$(gb_to_bytes "$o_used") || die "已用流量请填数字，例如 123.4"; fi

  # 预览：只在内存里算，不写文件、不碰 tc
  QUIET_EVENTS=1
  load_state_fresh
  t=$(now)
  update_counters "$t" || die "读取网卡 $IFACE 的流量计数失败"
  [[ -n $used_bytes ]] && calibrate_used "$used_bytes"
  b=$(billed); cap=$(throttle_cap_kbit)
  echo
  echo "将按以下设置运行："
  echo "  统计的网卡：$IFACE（VPS 连外网用的那块）"
  echo "  $(mode_name "$COUNT_MODE")计费，套餐 ${QUOTA_GB} GB，每月 ${RESET_DAY} 号重置"
  echo "  本期 $(fmt_day "$CB_START") ~ $(fmt_day "$CB_NEXT")，已用 $(fmt_gb "$b")，用到 ${THRESHOLD}% 后不再发额度"
  echo "  今日额度约 $(fmt_gb "$(day_budget "$t" "$b")")；超额后限速不高于 ${cap} kbit/s（$(fmt_mbps "$cap")）"
  echo "  永不限速端口：$EXEMPT_PORTS（请确认包含你的 SSH 端口）"
  if (( interactive )); then
    local yn
    echo "  哪一项不对就回答 n 取消，改好再运行（网卡可以加 --iface 网卡名 指定）。"
    ask yn "确认？" "Y"
    [[ $yn == [Yy]* ]] || { echo "已取消，未做任何改动。"; exit 0; }
  fi
  QUIET_EVENTS=0

  # 正式写入：先拿锁，再从磁盘重新读状态，避免和定时任务互相覆盖
  take_lock
  load_state_fresh
  t=$(now)
  update_counters "$t" || die "读取网卡 $IFACE 的流量计数失败"
  [[ -n $used_bytes ]] && calibrate_used "$used_bytes"
  DAY=""

  mkdir -p "$STATE_DIR" "$(dirname "$BIN_PATH")" "$UNIT_DIR" "$(dirname "$CONF")" || die "创建目录失败"
  if [[ $SELF != "$(readlink -f "$BIN_PATH" 2>/dev/null)" ]]; then
    [[ -f $SELF ]] || die "找不到脚本文件本身。请先下载到本地再运行：bash $APP.sh install"
    cp -f "$SELF" "$BIN_PATH" || die "复制到 $BIN_PATH 失败"
  fi
  chmod 0755 "$BIN_PATH" || die "设置 $BIN_PATH 执行权限失败"   # 直接 curl 下载到这里时没有执行权限
  write_config || die "写入 $CONF 失败"
  log_event "安装/更新配置：套餐 ${QUOTA_GB} GB，$(mode_name "$COUNT_MODE")计费，每月 ${RESET_DAY} 号重置，不限速端口 $EXEMPT_PORTS"
  evaluate "$t"
  save_state || die "写入 $STATE 失败"
  write_units || die "写入 systemd 单元失败"
  systemctl daemon-reload || die "systemctl daemon-reload 失败"
  systemctl enable --now "$APP.timer" "$APP-save.service" >/dev/null 2>&1 || die "启用 systemd 定时器失败"
  # 限流已经装好。关端口是独立的可选步骤：没选它就完全不碰防火墙
  if (( interactive || o_close )); then
    echo
    ports_offer "$interactive" "$o_close"
  fi
  echo
  print_status
  echo
  echo "已安装。每分钟自动统计一次。常用命令：$APP status / $APP check / $APP help"
  # 伪装域名体检是可选的，默认不做。先放开锁：等用户回答、做体检时都别挡住每分钟的统计
  exec 9>&-
  echo
  if (( interactive )); then
    ask yn "要不要顺便检查伪装域名（REALITY 的 target）有没有被人借道偷流量的风险？（只读，不改任何东西；输入 y 检查，直接回车跳过）" "N"
    if [[ $yn == [Yy]* ]]; then
      echo
      cmd_check || true   # 结果只是建议，不影响安装
    else
      echo "跳过。以后想查，运行：$APP check"
    fi
  else
    echo "想检查伪装域名（REALITY 的 target）有没有被人借道偷流量的风险，运行：$APP check（只读）"
  fi
}

cmd_uninstall() {
  require_root
  local yes=0 a=""
  [[ ${1-} == -y || ${1-} == --yes ]] && yes=1
  echo "将删除：$BIN_PATH、$CONF、$PORTS_FILE、$STATE_DIR（流量计数和事件记录）、systemd 单元 $APP*，并撤销本工具加的限速和关闭的端口。"
  if (( yes == 0 )); then
    read -r -p "确认卸载？[y/N] " a || true
    [[ $a == [Yy]* ]] || { echo "已取消。"; return 0; }
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$APP.timer" "$APP-save.service" "$APP.service" "$APP-ports.service" >/dev/null 2>&1 || true
  fi
  take_lock          # 等可能还在跑的 tick 结束
  tc_clear_all_ours  # 不依赖配置和状态文件，按句柄撤掉所有网卡上本工具的限速
  rescue_stop
  fw_clear_all || warn "没能完全撤掉本工具的端口规则（nft 表 $FW_TABLE / iptables 链 $FW_CHAIN），可重启后再卸载一次"
  rm -f "$UNIT_DIR/$APP.service" "$UNIT_DIR/$APP.timer" "$UNIT_DIR/$APP-save.service" "$UNIT_DIR/$APP-ports.service"
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1
  rm -f "$BIN_PATH" "$CONF" "$PORTS_FILE"
  [[ $STATE_DIR == */"$APP" ]] && rm -rf -- "$STATE_DIR"
  echo "已卸载。"
}

# ---------------------------------------------------------------- 命令：ports（可选：从外网关掉用不到的端口）
# 只关“程序名和端口号都对得上”的已知高风险服务（数据库、缓存等）；面板、代理、认不出的程序一律保留。
# 规则只放在本工具自己的 nft 表 inet vps_traffic_guard（没有 nft 时用 iptables 链 VTG_PORTS），
# 只挡从外网网卡进来的新连接：TCP 只丢 SYN，不需要连接跟踪；本机自己访问、已建立的连接都不受影响。
# 每分钟的定时任务不碰防火墙；开机由 $APP-ports.service 按已确认的列表恢复。

risky_name() { # 程序名 端口/协议 -> 说明；不在表里返回 1
  case "$1 $2" in
    "mysqld 3306/tcp"|"mysqld 33060/tcp"|"mariadbd 3306/tcp") echo "MySQL 数据库" ;;
    "postgres 5432/tcp")                         echo "PostgreSQL 数据库" ;;
    "redis-server 6379/tcp")                     echo "Redis 数据库" ;;
    "mongod 27017/tcp")                          echo "MongoDB 数据库" ;;
    "memcached 11211/tcp"|"memcached 11211/udp") echo "Memcached 缓存" ;;
    "rpcbind 111/tcp"|"rpcbind 111/udp")         echo "rpcbind，NFS 用的，VPS 一般用不到" ;;
    "dockerd 2375/tcp")                          echo "Docker 远程管理接口，没有密码" ;;
    *) return 1 ;;
  esac
}

risky_prog() { # 程序名 -> 是不是表里的高风险程序（不看端口；手动指定端口时用）
  case $1 in mysqld|mariadbd|postgres|redis-server|mongod|memcached|rpcbind|dockerd) return 0 ;; esac
  return 1
}

risky_of() { # 协议 端口 程序名列表 -> 说明；这个端口上的每个程序都在表里才算
  local p d=""
  for p in $3; do d=$(risky_name "$p" "$2/$1") || return 1; done
  [[ -n $d ]] && echo "$d"
}

listen_rows() { # 每行：协议 端口 地址 程序名（多个用逗号分隔；读不到程序名写 -）
  ss -tulnp 2>/dev/null | awk 'NR > 1 && ($1 == "tcp" || $1 == "udp") {
      n = split($5, a, ":"); port = a[n]
      addr = substr($5, 1, length($5) - length(port) - 1)
      gsub(/\[/, "", addr); gsub(/\]/, "", addr); sub(/%.*/, "", addr)
      names = ""; i = index($0, "users:(")
      if (i) {
        s = substr($0, i + 6)
        while (match(s, /\("[^"]*"/)) {     # users:(("nginx",pid=1,fd=7),("nginx",pid=2,fd=7)) 里的每个程序名
          p = substr(s, RSTART + 2, RLENGTH - 3); gsub(/[[:space:],]/, "_", p)
          if (p != "" && index("," names ",", "," p ",") == 0) names = names (names == "" ? "" : ",") p
          s = substr(s, RSTART + RLENGTH)
        }
      }
      if (names == "") names = "-"
      print $1, port, addr, names
    }'
}

port_exposed() { # 监听地址 本网卡地址列表（前后带空格） -> 外网能不能连到
  case $1 in
    '*'|0.0.0.0|::) return 0 ;;
    127.*|::1|::ffff:127.*|[fF][eE]80:*) return 1 ;;
  esac
  [[ $2 == "  " || $2 == *" ${1#::ffff:} "* ]]   # 读不到网卡地址时按“能连到”算
}

est_ports() { # 此刻有外网 TCP 连接的本机端口（前后带空格）
  echo " $(ss -tn 2>/dev/null | awk '$1 == "ESTAB" && $5 !~ /^(127\.|\[::1\]|\[::ffff:127\.)/ { n = split($4, a, ":"); print a[n] }' | sort -un | tr '\n' ' ') "
}

ports_scan() { # 输出每行：close|keep 端口/协议 程序名(逗号分隔) 说明
  local ssh addrs est proto port addr list proc key why act
  local -A procs=()
  ssh=" $(detect_ssh_ports) ${EXEMPT_PORTS:-} "
  addrs=" $(ip -o addr show dev "$IFACE" 2>/dev/null | awk '{ split($4, a, "/"); print a[1] }' | tr '\n' ' ') "
  est=$(est_ports)
  while read -r proto port addr list; do
    [[ $port =~ ^[0-9]{1,5}$ && -n $list ]] || continue
    port_exposed "$addr" "$addrs" || continue
    key="$port/$proto"
    for proc in ${list//,/ }; do
      [[ " ${procs[$key]-} " == *" $proc "* ]] || procs[$key]="${procs[$key]:+${procs[$key]} }$proc"
    done
  done < <(listen_rows)
  (( ${#procs[@]} )) || return 0
  for key in $(printf '%s\n' "${!procs[@]}" | sort -t/ -k1,1n -k2,2); do
    port=${key%/*}; proto=${key#*/}; act=keep
    if [[ $ssh == *" $port "* ]]; then why="SSH"
    elif [[ $port == 80 || $port == 443 ]]; then why="网站/代理常用端口"
    elif why=$(risky_of "$proto" "$port" "${procs[$key]}"); then
      if [[ $proto == tcp && $est == *" $port "* ]]; then why="正在有外部连接，算在用"
      else act=close; fi
    else why=""; fi
    printf '%s %s %s %s\n' "$act" "$key" "${procs[$key]// /,}" "$why"
  done
}

ports_print_table() { # 已关闭列表；标准输入是 ports_scan 的输出
  local closed=" $1 " act key procs why name p
  while read -r act key procs why; do
    name=""
    for p in ${procs//,/ }; do [[ $p == - ]] && p="系统内核或未知程序"; name+="${name:+、}$p"; done
    if [[ $closed == *" $key "* ]]; then printf '    已关  %-10s %s%s\n' "$key" "$name" "${why:+（$why）}"
    elif [[ $act == close ]]; then printf '    关闭  %-10s %s（%s）\n' "$key" "$name" "$why"
    else printf '    保留  %-10s %s%s\n' "$key" "$name" "${why:+（$why）}"; fi
  done
}

ports_parse() { # 6379 / 6379/tcp / 6379/udp ... -> 规范的“端口/协议”列表；写错返回 1
  local a p out=""
  for a in "$@"; do
    [[ $a =~ ^([0-9]{1,5})(/(tcp|udp))?$ ]] || return 1
    p=$((10#${BASH_REMATCH[1]}))
    (( p >= 1 && p <= 65535 )) || return 1
    if [[ -n ${BASH_REMATCH[3]} ]]; then out+=" $p/${BASH_REMATCH[3]}"; else out+=" $p/tcp $p/udp"; fi
  done
  echo "${out# }"
}

ports_protect() { # 列表 -> 去掉 SSH、不限速端口和 80/443（每次下规则前的最后一道过滤）
  local i out="" keep
  keep=" $(detect_ssh_ports) ${EXEMPT_PORTS:-} 80 443 "
  for i in $1; do
    [[ $keep == *" ${i%/*} "* || " $out " == *" $i "* ]] || out+="${out:+ }$i"
  done
  echo "$out"
}

sanitize_ports() {
  local i out="" p
  [[ $PORTS_IFACE =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || PORTS_IFACE=""
  for i in $CLOSED_PORTS; do
    [[ $i =~ ^([0-9]{1,5})/(tcp|udp)$ ]] || continue
    p=$((10#${BASH_REMATCH[1]}))
    (( p >= 1 && p <= 65535 )) || continue
    i="$p/${BASH_REMATCH[2]}"
    [[ " $out " == *" $i "* ]] || out+="${out:+ }$i"
  done
  CLOSED_PORTS=$out
  [[ -n $PORTS_IFACE ]] || CLOSED_PORTS=""
}

load_ports() { # 读已确认关闭的端口（文件不存在或写坏 = 没关任何端口）
  PORTS_IFACE="" CLOSED_PORTS=""
  kv_load "$PORTS_FILE" "$PORTS_KEYS" || true
  sanitize_ports
}

save_ports() {
  local tmp="$PORTS_FILE.tmp.$$"
  { echo "# $APP 已关闭的端口。修改请用：$APP ports open 端口号 / $APP ports off"
    printf 'PORTS_IFACE="%s"\nCLOSED_PORTS="%s"\n' "$PORTS_IFACE" "$CLOSED_PORTS"; } > "$tmp" && mv -f "$tmp" "$PORTS_FILE"
}

fw_backend() { # nft 优先；没有 nft 或内核不支持再用 iptables
  if command -v "$NFT" >/dev/null 2>&1 && "$NFT" list tables >/dev/null 2>&1; then echo nft
  elif command -v "$IPT" >/dev/null 2>&1; then echo ipt
  else return 1; fi
}

fw_nft_rules() { # 网卡 端口列表 -> nft 脚本（先建、再删、再建：整张表在一个事务里原子替换）
  local tcp="" udp="" i
  for i in $2; do
    case $i in
      */tcp) tcp+="${tcp:+, }${i%/*}" ;;
      */udp) udp+="${udp:+, }${i%/*}" ;;
    esac
  done
  printf 'table inet %s\ndelete table inet %s\ntable inet %s {\n' "$FW_TABLE" "$FW_TABLE" "$FW_TABLE"
  printf '  chain input {\n    type filter hook input priority 0; policy accept;\n'
  [[ -n $tcp ]] && printf '    iifname "%s" tcp dport { %s } tcp flags & (syn | ack) == syn counter drop\n' "$1" "$tcp"
  [[ -n $udp ]] && printf '    iifname "%s" udp dport { %s } counter drop\n' "$1" "$udp"
  printf '  }\n}\n'
}

fw_apply() { # 后端 网卡 端口列表；返回 0 成功，3 = nft 预检没通过（什么都没改），其他 = 失败
  local be=$1 dev=$2 list=$3 t i
  case $be in
    nft)
      fw_nft_rules "$dev" "$list" | "$NFT" -c -f - >/dev/null 2>&1 || return 3
      fw_nft_rules "$dev" "$list" | "$NFT" -f - || return 1
      fw_clear_ipt || return 1 ;;   # 以前没有 nft 时用过 iptables：旧链不清掉，打开的端口其实还被挡着
    ipt)
      for t in "$IPT" "$IP6T"; do
        command -v "$t" >/dev/null 2>&1 || continue
        "$t" -w -N "$FW_CHAIN" >/dev/null 2>&1    # 链已存在时会报错，忽略
        "$t" -w -F "$FW_CHAIN" || return 1
        for i in $list; do
          case $i in
            */tcp) "$t" -w -A "$FW_CHAIN" -i "$dev" -p tcp --dport "${i%/*}" --syn -j DROP || return 1 ;;
            */udp) "$t" -w -A "$FW_CHAIN" -i "$dev" -p udp --dport "${i%/*}" -j DROP || return 1 ;;
          esac
        done
        "$t" -w -C INPUT -j "$FW_CHAIN" >/dev/null 2>&1 || "$t" -w -I INPUT 1 -j "$FW_CHAIN" || return 1
      done
      fw_clear_nft || return 1 ;;   # 反过来也一样：nft 后来不能用了，残留的表也清掉
    *) return 1 ;;
  esac
}

fw_present() { # 后端 -> 本工具的端口规则在不在
  case $1 in
    nft) "$NFT" list table inet "$FW_TABLE" >/dev/null 2>&1 ;;
    ipt) "$IPT" -w -C INPUT -j "$FW_CHAIN" >/dev/null 2>&1 ;;
    *)   return 1 ;;
  esac
}

fw_hits() { # 后端 -> 已拦下的包数
  case $1 in
    nft) "$NFT" list table inet "$FW_TABLE" 2>/dev/null |
           awk '{ for (i = 1; i < NF; i++) if ($i == "packets") s += $(i + 1) } END { print s + 0 }' ;;
    ipt) { "$IPT" -w -L "$FW_CHAIN" -nvx 2>/dev/null
           command -v "$IP6T" >/dev/null 2>&1 && "$IP6T" -w -L "$FW_CHAIN" -nvx 2>/dev/null; } |
           awk '$1 ~ /^[0-9]+$/ { s += $1 } END { print s + 0 }' ;;
  esac
}

fw_clear_nft() { # 删掉本工具的 nft 表（没有就算成功）
  command -v "$NFT" >/dev/null 2>&1 && "$NFT" list table inet "$FW_TABLE" >/dev/null 2>&1 || return 0
  "$NFT" delete table inet "$FW_TABLE"
}

fw_clear_ipt() { # 删掉本工具的 iptables / ip6tables 链（没有就算成功）
  local rc=0 t n
  for t in "$IPT" "$IP6T"; do
    command -v "$t" >/dev/null 2>&1 || continue
    "$t" -w -S "$FW_CHAIN" >/dev/null 2>&1 || continue
    n=0
    while (( n < 20 )) && "$t" -w -D INPUT -j "$FW_CHAIN" >/dev/null 2>&1; do n=$((n + 1)); done
    { "$t" -w -F "$FW_CHAIN" && "$t" -w -X "$FW_CHAIN"; } || rc=1
  done
  return $rc
}

fw_clear_all() { # 撤掉本工具的端口规则（只按表名、链名认，不依赖任何文件）；没撤干净返回 1
  local rc=0
  fw_clear_nft || rc=1
  fw_clear_ipt || rc=1
  return $rc
}

rescue_cmd() { # 自动撤销保险：先无条件删掉本工具的规则（不依赖本脚本），再按已确认的列表恢复
  printf '%s' "nft delete table inet $FW_TABLE 2>/dev/null; for t in iptables ip6tables; do n=0; while [ \$n -lt 20 ] && \$t -w -D INPUT -j $FW_CHAIN 2>/dev/null; do n=\$((n+1)); done; \$t -w -F $FW_CHAIN 2>/dev/null; \$t -w -X $FW_CHAIN 2>/dev/null; done; [ -x $BIN_PATH ] && $BIN_PATH ports restore >/dev/null 2>&1; true"
}

rescue_arm() {
  systemctl stop vtg-ports-rescue.timer vtg-ports-rescue.service >/dev/null 2>&1
  systemctl reset-failed vtg-ports-rescue.timer vtg-ports-rescue.service >/dev/null 2>&1
  systemd-run --quiet --on-active="$FW_RESCUE" --timer-property=AccuracySec=1s --unit=vtg-ports-rescue \
    /bin/sh -c "$(rescue_cmd)" >/dev/null 2>&1
}

rescue_stop() {
  command -v systemctl >/dev/null 2>&1 && systemctl stop vtg-ports-rescue.timer >/dev/null 2>&1
  return 0
}

write_ports_unit() {
  cat > "$UNIT_DIR/$APP-ports.service" <<EOF
[Unit]
Description=VPS traffic guard: restore closed ports at boot
After=network-pre.target nftables.service netfilter-persistent.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$BIN_PATH ports restore

[Install]
WantedBy=multi-user.target
EOF
}

ports_env_problem() { # 不适合由本工具改防火墙时，输出原因
  local s
  if command -v ufw >/dev/null 2>&1; then
    s=$(LC_ALL=C ufw status 2>/dev/null)
    if [[ $s == "Status: active"* ]]; then
      echo "ufw 防火墙已启用，端口请用 ufw 管理（例如 ufw deny 6379/tcp），本工具不去改它"; return
    fi
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "firewalld 防火墙已启用，端口请用 firewall-cmd 管理，本工具不去改它"; return
  fi
  if ! command -v systemd-run >/dev/null 2>&1; then
    echo "没有 systemd-run，无法设置“不确认就自动撤销”的保险，为安全起见不改防火墙"; return
  fi
  fw_backend >/dev/null || echo "缺少 nft 和 iptables 命令（Debian/Ubuntu 可 apt install nftables），没法关端口"
}

ports_sync() { # 让实际规则与已确认的列表一致；失败返回 1
  local list be
  load_ports
  list=$(ports_protect "$CLOSED_PORTS")
  if [[ -z $list ]]; then fw_clear_all; return; fi
  be=$(fw_backend) || return 1
  fw_apply "$be" "$PORTS_IFACE" "$list"
}

ports_rollback() { # 撤销试用中的改动，回到已确认的样子
  ports_sync || fw_clear_all
  rm -f "$PENDING"
  rescue_stop
  log_event "关端口没有确认，已撤销"
}

ports_commit() { # 试用转正式；返回 1 = 没有待确认的改动，2 = 规则已不在（超时被撤销），3 = 保存失败
  local PORTS_IFACE="" CLOSED_PORTS="" be
  [[ -f $PENDING ]] || return 1
  kv_load "$PENDING" "$PORTS_KEYS"
  sanitize_ports
  [[ -n $CLOSED_PORTS ]] || { rm -f "$PENDING"; return 1; }
  if ! { be=$(fw_backend) && fw_present "$be"; }; then
    ports_sync >/dev/null 2>&1          # 规则已不在（被撤销）：回到已确认的样子，并作废这次试用
    rm -f "$PENDING"
    rescue_stop
    return 2
  fi
  save_ports || return 3
  rm -f "$PENDING"
  rescue_stop
  if ! { write_ports_unit && systemctl daemon-reload >/dev/null 2>&1 && systemctl enable "$APP-ports.service" >/dev/null 2>&1; }; then
    warn "设置开机自动恢复失败：重启后这些端口会重新打开，到时再运行一次 $APP ports restore"
  fi
  log_event "已确认关闭端口：$CLOSED_PORTS"
  echo "  已确认。关闭的端口：$CLOSED_PORTS（开机自动恢复；重新打开：$APP ports open 端口号）"
}

ports_trial_abort() { # 等确认时收到中断/断线信号：撤销后退出
  trap - INT TERM HUP
  take_lock
  echo
  if [[ -f $PENDING ]]; then
    ports_rollback
    echo "  已撤销，端口恢复原样。"
  else   # 等回话期间，别的窗口已经确认或撤销了这次试关
    echo "  这次试关已经在别处确认或撤销，这里不再改动。"
  fi
  exit 130
}

ports_apply_trial() { # 新的完整列表 交互(1/0)；先上保险再改，确认后才保存
  local list inter=$2 be rc ans="" PORTS_IFACE=$IFACE CLOSED_PORTS
  list=$(ports_protect "$1")    # 下规则前的最后一道过滤：SSH、不限速端口、80/443 永远不关
  CLOSED_PORTS=$list
  [[ -n $list ]] || { echo "  没有可以关的端口"; return 1; }
  be=$(fw_backend) || { echo "  跳过：缺少 nft 和 iptables 命令"; return 1; }
  rescue_arm || { echo "  跳过：没能设置“不确认就自动撤销”的保险（systemd-run 失败），为安全起见不改防火墙"; return 1; }
  mkdir -p "$STATE_DIR"
  kv_save "$PENDING" PORTS_IFACE CLOSED_PORTS || { rescue_stop; echo "  跳过：写入 $PENDING 失败"; return 1; }
  fw_apply "$be" "$IFACE" "$list"; rc=$?
  if (( rc != 0 )); then
    ports_sync >/dev/null 2>&1 || fw_clear_all
    rm -f "$PENDING"
    rescue_stop
    if (( rc == 3 )); then echo "  没改：防火墙规则预检没通过（OpenVZ/LXC 等容器型 VPS 可能不允许改防火墙）"
    else echo "  没改：设置防火墙规则失败（见上方报错），已恢复原样"; fi
    return 1
  fi
  log_event "试关端口：$list（$FW_RESCUE 秒内不确认就自动撤销）"
  echo "  已关闭：$list（试用中）"
  if (( inter == 0 )); then
    echo "  请在 $FW_RESCUE 秒内运行：$APP ports confirm    不确认会自动撤销。"
    return 0
  fi
  exec 9>&-    # 等用户回话期间放开锁，每分钟的流量统计照常进行
  trap ports_trial_abort INT TERM HUP
  echo "  请确认 SSH 还能正常操作：$FW_ASK 秒内在这里输入 y 回车。"
  echo "  超时、断线或输入别的，都会自动撤销，恢复原样。"
  read -r -t "$FW_ASK" -p "  还能正常操作吗？[y/N]: " ans || ans=""
  trap - INT TERM HUP
  take_lock
  if [[ $ans == [Yy]* ]]; then
    ports_commit && return 0
    echo "  没能确认（可能已超时自动撤销），可以重新运行：$APP ports close"
    return 1
  fi
  if [[ ! -f $PENDING ]]; then   # 等回话期间，别的窗口已经确认或撤销了这次试关
    echo "  这次试关已经在别处确认或撤销，这里不再改动。当前情况：$APP status"
    return 1
  fi
  ports_rollback
  echo "  已撤销，端口恢复原样。"
  return 1
}

ports_check_given() { # 手动指定的列表 -> 设置 GIVEN_OK；正被别的程序使用或正有外网连接的端口不关
  local scan est i line act key procs why p ok bad=""
  GIVEN_OK=""
  scan=$(ports_scan)
  est=$(est_ports)
  for i in $1; do
    line=$(awk -v k="$i" '$2 == k' <<< "$scan")
    [[ -n $line ]] || continue
    read -r act key procs why <<< "$line"
    ok=1
    for p in ${procs//,/ }; do risky_prog "$p" || ok=0; done
    [[ $why == 正在有外部连接* ]] && ok=0
    # 扫描只对标准端口查连接；手动指定的（比如改到 3307 的 mysqld）这里自己查
    if [[ ${i#*/} == tcp && $est == *" ${i%/*} "* ]]; then ok=0; why="正在有外部连接，算在用"; fi
    if (( ok == 0 )); then
      echo "  不关 $i：正被 ${procs//,/、} 使用${why:+（$why）}。本工具只关数据库、缓存这类服务，不关在用的端口"
      bad+=" ${i%/*}"
    fi
  done
  for i in $1; do   # 端口号有一个协议在用，同号的另一个协议也不关
    [[ " $bad " == *" ${i%/*} "* ]] || GIVEN_OK+="${GIVEN_OK:+ }$i"
  done
}

ports_offer() { # 交互(1/0) 免问(1/0) [指定的端口列表]：列出端口，问一句，再试用
  local inter=$1 auto=$2 given=${3-} scan="" cands="" i why yn list
  echo "【可选】关闭用不到的端口"
  command -v ss >/dev/null 2>&1 || { echo "  跳过：缺少 ss 命令（iproute2 包），查不了端口"; return 0; }
  ports_drop_stale
  [[ -f $PENDING ]] && { echo "  上一次关端口还在等确认，这次先不动（运行 $APP ports confirm，或等它自动撤销）"; return 0; }
  if [[ -n $given ]]; then
    load_ports
    cands=$(ports_protect "$given")
    [[ $cands == "$given" ]] || echo "  SSH、不限速端口和 80/443 永远不关，已从列表里去掉"
    ports_check_given "$cands"
    cands=$GIVEN_OK
    [[ -n $cands ]] || { echo "  没有可以关的端口，什么都没改"; return 0; }
  else
    load_ports
    scan=$(ports_scan)
    for i in $(awk '$1 == "close" { print $2 }' <<< "$scan"); do
      [[ " $CLOSED_PORTS " == *" $i "* ]] || cands+="${cands:+ }$i"
    done
    cands=$(ports_protect "$cands")
    if [[ -z $cands ]]; then
      echo "  没发现多余的对外端口：对公网开着的是 SSH、网站、代理、面板这类在用的，或认不出用途的程序，一律保留。"
      return 0
    fi
    echo "  对公网开放的端口："
    ports_print_table "$CLOSED_PORTS" <<< "$scan"
    echo "  标着“关闭”的端口对公网开着，但不是你登录、上网、建站用的。关掉后从外网网卡进来的连接都会被挡（云服务器上同一内网的其他机器也算），本机程序照常能用。"
  fi
  if (( auto == 0 )); then
    if (( inter == 0 )); then echo "  要关闭请在终端里运行：$APP ports close（脚本里加 --yes）"; return 0; fi
    exec 9>&-    # 等用户回答期间放开锁，每分钟的流量统计照常进行
    ask yn "  要从外面关掉 $cands 吗？输入 y 关闭，直接回车不关" "N"
    [[ $yn == [Yy]* ]] || { echo "  好的，不关。以后想关：$APP ports close"; return 0; }
    take_lock
    ports_drop_stale
    [[ -f $PENDING ]] && { echo "  另一个窗口正在关端口，这次什么都不改"; return 0; }
    load_ports   # 等回答期间可能有变化，重新读一次
  fi
  why=$(ports_env_problem)
  [[ -z $why ]] || { echo "  跳过：$why"; return 0; }
  list=$CLOSED_PORTS
  for i in $cands; do [[ " $list " == *" $i "* ]] || list+="${list:+ }$i"; done
  ports_apply_trial "$list" "$inter"
  return 0
}

ports_status_line() {
  local be hits PORTS_IFACE CLOSED_PORTS
  if pending_live; then
    echo "关闭端口：试用中，等待确认（$APP ports confirm），不确认会自动撤销"; return 0
  fi
  load_ports
  if [[ -z $CLOSED_PORTS ]]; then echo "关闭端口：未开启（可选，查看：$APP ports）"; return 0; fi
  if [[ ${VTG_SKIP_ROOT:-0} == 1 ]] || (( EUID == 0 )); then
    if be=$(fw_backend) && fw_present "$be"; then
      hits=$(fw_hits "$be")
      echo "关闭端口：$CLOSED_PORTS（已拦下 ${hits:-0} 个连接请求）"
    else
      echo "关闭端口：$CLOSED_PORTS，但规则现在不在（被别的程序清掉了？）。恢复：$APP ports restore"
    fi
    return 0
  fi
  echo "关闭端口：$CLOSED_PORTS"
}

ports_need_install() {
  load_all || die "还没安装，或配置文件 $CONF 有误。先安装：bash $APP.sh install（安装时可以顺便关端口）"
}

pending_live() { # 有试用中的改动，而且自动撤销保险还在倒计时（或正在执行）
  [[ -f $PENDING ]] && command -v systemctl >/dev/null 2>&1 || return 1
  # 触发过的临时定时器会一直挂着“active (elapsed)”，is-active 照样成功，所以看 SubState
  case $(systemctl show -p SubState vtg-ports-rescue.timer 2>/dev/null) in
    SubState=waiting|SubState=running) return 0 ;;
  esac
  return 1
}

ports_drop_stale() { # 试用文件还在、保险却已经没了（中途重启、撤销时出错）：作废这次试用（需持锁）
  [[ -f $PENDING ]] || return 0
  pending_live && return 0
  ports_sync >/dev/null 2>&1 || fw_clear_all
  rm -f "$PENDING"
  log_event "上次关端口没有确认（重启或超时），已作废"
}

ports_no_pending() {
  ports_drop_stale
  [[ -f $PENDING ]] && die "上一次关端口还在等确认：运行 $APP ports confirm，或等 $FW_RESCUE 秒自动撤销"
  return 0
}

ports_show() {
  local scan i more=""
  ports_need_install
  command -v ss >/dev/null 2>&1 || die "缺少 ss 命令（iproute2 包）"
  load_ports
  scan=$(ports_scan)
  echo "== 对公网开放的端口（网卡 $IFACE）=="
  if [[ -n $scan ]]; then ports_print_table "$CLOSED_PORTS" <<< "$scan"; else echo "    （没有）"; fi
  ports_status_line
  for i in $(awk '$1 == "close" { print $2 }' <<< "$scan"); do
    [[ " $CLOSED_PORTS " == *" $i "* ]] || more+="${more:+ }$i"
  done
  [[ -n $more && -n $(ports_protect "$more") ]] && echo "关掉标着“关闭”的端口：$APP ports close"
  echo "说明：只会关数据库、缓存这类认得出的高风险服务；SSH、80/443、面板、代理和认不出的程序一律保留。"
}

ports_close() { # [--yes] [端口...]
  local yes=0 inter=0 given="" args=()
  while (( $# )); do
    case $1 in -y|--yes) yes=1 ;; *) args+=("$1") ;; esac
    shift
  done
  if (( ${#args[@]} )); then given=$(ports_parse "${args[@]}") || die "端口写法不对：用 6379、6379/tcp 或 6379/udp"; fi
  (( yes == 0 )) && [[ -t 0 ]] && inter=1
  take_lock
  ports_need_install
  ports_no_pending
  ports_offer "$inter" "$yes" "$given"
}

ports_confirm() {
  take_lock
  init_conf_defaults
  kv_load "$CONF" "$CONF_KEYS" || true
  ports_commit
  case $? in
    0) ;;
    1) die "没有等待确认的改动（可能已经超时自动撤销），可以重新运行：$APP ports close" ;;
    2) die "规则已经被自动撤销（超时），什么都没保存。可以重新运行：$APP ports close" ;;
    *) die "保存 $PORTS_FILE 失败" ;;
  esac
}

ports_open() { # [端口...]；不带端口 = 全部打开
  local drop="" i new=""
  if (( $# )); then drop=$(ports_parse "$@") || die "端口写法不对：用 6379、6379/tcp 或 6379/udp"; fi
  take_lock
  ports_need_install
  ports_no_pending
  load_ports
  if [[ -z $CLOSED_PORTS ]]; then
    fw_clear_all
    echo "本工具没有关闭任何端口。"; return 0
  fi
  if [[ -n $drop ]]; then
    for i in $CLOSED_PORTS; do [[ " $drop " == *" $i "* ]] || new+="${new:+ }$i"; done
    [[ $new != "$CLOSED_PORTS" ]] || { echo "这些端口不是本工具关的。本工具关闭的：$CLOSED_PORTS"; return 0; }
  fi
  if [[ -z $new ]]; then
    fw_clear_all || die "撤掉端口规则失败"
    rm -f "$PORTS_FILE"
    if command -v systemctl >/dev/null 2>&1; then
      systemctl disable "$APP-ports.service" >/dev/null 2>&1
      rm -f "$UNIT_DIR/$APP-ports.service"
      systemctl daemon-reload >/dev/null 2>&1
    fi
    log_event "已重新打开本工具关闭的全部端口"
    echo "已重新打开全部端口，本工具不再改防火墙。"
    return 0
  fi
  CLOSED_PORTS=$new
  save_ports || die "写入 $PORTS_FILE 失败"
  ports_sync || die "更新端口规则失败"
  log_event "重新打开部分端口，仍关闭：$new"
  echo "已重新打开。仍关闭：$new"
}

ports_restore() { # 开机、自动撤销保险调用：按已确认的列表恢复规则
  take_lock
  init_conf_defaults
  kv_load "$CONF" "$CONF_KEYS" || true
  if [[ -f $PENDING ]]; then
    rm -f "$PENDING"
    log_event "关端口在 $FW_RESCUE 秒内没有确认，已自动撤销"
  fi
  ports_sync || die "恢复端口规则失败"
}

cmd_ports() {
  require_root
  local sub=${1:-show}
  (( $# )) && shift
  case $sub in
    show)    ports_show ;;
    close)   ports_close "$@" ;;
    confirm) ports_confirm ;;
    open)    ports_open "$@" ;;
    off)     ports_open ;;
    restore) ports_restore ;;
    *)       die "用法：$APP ports [show | close [端口...] | confirm | open [端口...] | off | restore]" ;;
  esac
}

# ---------------------------------------------------------------- 命令：check（REALITY 回落目标体检）

ip4_to_int() { local IFS=.; set -- $1; echo $(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 )); }

in_cidr4() { # IP CIDR
  local bits=${2#*/} a b mask
  a=$(ip4_to_int "$1"); b=$(ip4_to_int "${2%/*}")
  mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  (( (a & mask) == (b & mask) ))
}

expand_v6() { # 输出 32 位十六进制
  local ip=${1%%\%*} h i n out=() hd=() tl=()
  if [[ $ip == *::* ]]; then
    [[ -n ${ip%%::*} ]] && IFS=: read -ra hd <<< "${ip%%::*}"
    [[ -n ${ip#*::} ]] && IFS=: read -ra tl <<< "${ip#*::}"
    n=$(( 8 - ${#hd[@]} - ${#tl[@]} ))
    (( n >= 1 )) || return 1
    out=(${hd[@]+"${hd[@]}"})
    for (( i = 0; i < n; i++ )); do out+=(0); done
    out+=(${tl[@]+"${tl[@]}"})
  else
    IFS=: read -ra out <<< "$ip"
  fi
  (( ${#out[@]} == 8 )) || return 1
  for h in "${out[@]}"; do
    [[ $h =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    printf '%04x' "$((16#$h))"
  done
}

in_cidr6() { # IP CIDR
  local a b bits=${2#*/} full rem x y m
  a=$(expand_v6 "$1") || return 1
  b=$(expand_v6 "${2%/*}") || return 1
  full=$(( bits / 4 )); rem=$(( bits % 4 ))
  [[ ${a:0:full} == "${b:0:full}" ]] || return 1
  (( rem == 0 )) && return 0
  x=$((16#${a:full:1})); y=$((16#${b:full:1})); m=$(( (0xF << (4 - rem)) & 0xF ))
  (( (x & m) == (y & m) ))
}

is_cf_ip() {
  local ip=$1 c
  [[ $ip =~ ^::[fF]{4}:([0-9.]+)$ ]] && ip=${BASH_REMATCH[1]}
  if [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    for c in $CF_V4; do in_cidr4 "$ip" "$c" && return 0; done
  elif [[ $ip == *:* ]]; then
    for c in $CF_V6; do in_cidr6 "$ip" "$c" && return 0; done
  fi
  return 1
}

parse_target_host() { # target 值 -> 主机（本机回落输出 local）
  local v=$1
  case $v in /*|@*) echo local; return ;; esac
  if [[ $v =~ ^\[([0-9A-Fa-f:.]+)\](:[0-9]+)?$ ]]; then echo "${BASH_REMATCH[1]}"; return; fi
  if [[ $v =~ ^[0-9]+$ ]]; then echo local; return; fi
  if [[ $v == *:*:* ]]; then echo "$v"; return; fi
  echo "${v%%:*}"
}

is_local_host() {
  [[ $1 == local || $1 == localhost || $1 =~ ^127\. || $1 == ::1 || $1 == 0.0.0.0 ]]
}

resolve_host() {
  if command -v getent >/dev/null 2>&1; then
    getent ahosts "$1" 2>/dev/null | awk '{ print $1 }' | sort -u
  elif command -v dig >/dev/null 2>&1; then
    { dig +short A "$1"; dig +short AAAA "$1"; } 2>/dev/null | grep -E '^[0-9A-Fa-f:.]+$' | sort -u
  fi
}

cdn_by_headers() { # 主机 -> 看起来是哪家 CDN（看不出就不输出）。没访问成功返回 1，没装 curl 返回 2
  command -v curl >/dev/null 2>&1 || return 2
  local h
  h=$(curl -sSI -m 8 -A 'Mozilla/5.0' "https://$1/" 2>/dev/null | tr 'A-Z' 'a-z')
  [[ -n $h ]] || return 1
  case $h in
    *"server: cloudflare"*|*"cf-ray:"*)  echo "Cloudflare" ;;
    *"x-amz-cf-id:"*|*cloudfront*)        echo "亚马逊 CloudFront" ;;
    *"x-served-by: cache-"*|*fastly*)     echo "Fastly" ;;
    *akamai*)                             echo "Akamai" ;;
    *"x-azure-ref:"*)                     echo "微软 Azure Front Door" ;;
  esac
}

config_candidates() {
  local f p
  for f in /usr/local/etc/xray/*.json /usr/local/etc/xray/conf/*.json /etc/xray/*.json /etc/xray/conf/*.json \
           /etc/v2ray-agent/xray/conf/*.json /usr/local/x-ui/bin/config.json /etc/x-ui/x-ui.db \
           /etc/sing-box/*.json /etc/sing-box/conf/*.json /usr/local/etc/sing-box/*.json /etc/s-box/*.json; do
    [[ -f $f ]] && echo "$f"
  done
  # 正在运行的 xray / sing-box 进程用的配置
  ps -eo args= 2>/dev/null | awk '/(xray|sing-box)/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "-c" || $i == "-config" || $i == "--config" || $i == "-confdir" || $i == "-C") print $(i + 1)
        else if ($i ~ /^-(c|config|confdir)=/) { sub(/^[^=]*=/, "", $i); print $i }
      }
    }' | while IFS= read -r p; do
      if [[ -d $p ]]; then
        for f in "$p"/*.json; do [[ -f $f ]] && echo "$f"; done
      elif [[ -f $p ]]; then
        echo "$p"
      fi
    done
}

extract_targets() { # 文件 -> 每行 "类型<TAB>值"
  # x-ui.db 是 SQLite 二进制文件：按字节处理，否则 UTF-8 环境下 awk 会报 Invalid multibyte data
  local LC_ALL=C flat seg re_t re_d re_s
  re_t='"target"[[:space:]]*:[[:space:]]*"([^"]+)"'
  re_d='"dest"[[:space:]]*:[[:space:]]*"([^"]+)"'
  re_s='"handshake"[[:space:]]*:[[:space:]]*\{[^}]*"server"[[:space:]]*:[[:space:]]*"([^"]+)"'
  flat=$(LC_ALL=C tr -d '\000\r\n\\' < "$1" 2>/dev/null)
  while IFS= read -r seg; do
    if [[ $seg =~ $re_t ]]; then printf 'xray\t%s\n' "${BASH_REMATCH[1]}"
    elif [[ $seg =~ $re_d ]]; then printf 'xray\t%s\n' "${BASH_REMATCH[1]}"; fi
  done < <(printf '%s' "$flat" | LC_ALL=C awk 'BEGIN { RS = "\"realitySettings\"" } NR > 1 { print substr($0, 1, 4000) }')
  while IFS= read -r seg; do
    if [[ $seg =~ $re_s ]]; then printf 'singbox\t%s\n' "${BASH_REMATCH[1]}"; fi
  done < <(printf '%s' "$flat" | LC_ALL=C awk 'BEGIN { RS = "\"reality\"" } NR > 1 { print substr($0, 1, 4000) }')
}

CHECK_BAD=0      # 危险：走 Cloudflare
CHECK_WARN=0     # 有风险：看起来走别的 CDN，或是微软、苹果的网站
CHECK_UNKNOWN=0  # 没法判断：解析不到 IP

target_brand() { # 主机名 -> 微软 / 苹果 / Cloudflare；按名单，只认完整的一段段域名（notmicrosoft.com 不算）
  local h=${1,,} d
  h=${h%.}
  for d in microsoft.com bing.com live.com msn.com office.com windows.com xbox.com; do
    [[ $h == "$d" || $h == *".$d" ]] && { echo 微软; return 0; }
  done
  for d in apple.com icloud.com apple.com.cn mzstatic.com itunes.com; do
    [[ $h == "$d" || $h == *".$d" ]] && { echo 苹果; return 0; }
  done
  for d in cloudflare.com cloudflare.net cloudflare-dns.com; do
    [[ $h == "$d" || $h == *".$d" ]] && { echo Cloudflare; return 0; }
  done
  return 1
}

# 判断一个回落目标。结果放进 CK_LEVEL（bad 危险 / risk 有风险 / unknown 没法判断 / ok 没问题）、CK_WHY（一句大白话）、CK_IPS
check_one() { # 值
  local val=$1 host ip cf=0 cdn="" brand="" is_ip=0 fetch=0
  CK_LEVEL=ok CK_WHY="" CK_IPS="" CK_PARTIAL=0
  host=$(parse_target_host "$val")
  if is_local_host "$host"; then
    CK_WHY="回落到本机（自建网站 / 偷自己），不会被别人借道"
    return
  fi
  if [[ $host =~ ^[0-9.]+$ || $host == *:* ]]; then
    is_ip=1; CK_IPS=$host
  else
    CK_IPS=$(resolve_host "$host" | tr '\n' ' '); CK_IPS=${CK_IPS% }
    brand=$(target_brand "$host")
  fi
  if [[ -z ${CK_IPS// /} ]]; then
    CK_IPS=""
    case $brand in
      Cloudflare) CK_LEVEL=bad;     CK_WHY="Cloudflare 自己的网站（这次没解析到 IP，按域名就能确定）" ;;
      "")         CK_LEVEL=unknown; CK_WHY="解析不到 IP，没法判断（域名可能写错了，或者 VPS 的 DNS 暂时有问题）" ;;
      *)          CK_LEVEL=risk;    CK_WHY="${brand}的网站：很多教程拿它当默认值，用的人太多，容易被一起识别" ;;
    esac
    return
  fi
  for ip in $CK_IPS; do is_cf_ip "$ip" && cf=1; done
  if (( cf )); then CK_LEVEL=bad; CK_WHY="走 Cloudflare（解析到的 IP 在 Cloudflare 的网段里）"; return; fi
  if [[ $brand == Cloudflare ]]; then CK_LEVEL=bad; CK_WHY="Cloudflare 自己的网站"; return; fi
  if (( !is_ip )); then cdn=$(cdn_by_headers "$host"); fetch=$?; fi   # 0 访问成功 / 1 没访问成功 / 2 没装 curl
  if [[ -n $brand ]]; then
    CK_LEVEL=risk; CK_WHY="${brand}的网站：很多教程拿它当默认值，用的人太多，容易被一起识别"
    [[ -n $cdn ]] && CK_WHY+="；看起来还走 CDN（$cdn）"
    return
  fi
  if [[ -n $cdn ]]; then CK_LEVEL=risk; CK_WHY="看起来走 CDN（$cdn）"; return; fi
  if (( is_ip )); then
    CK_WHY="不在 Cloudflare 的网段里"
  elif (( fetch == 0 )); then
    CK_WHY="没走 Cloudflare，也没看出走别的 CDN"
  elif (( fetch == 2 )); then
    CK_WHY="没走 Cloudflare；本机没装 curl，是不是走别的 CDN 没查"; CK_PARTIAL=1
  else
    # REALITY 要从这台 VPS 连到伪装域名；连不上时代理本身也用不了，不能算“没发现问题”
    CK_LEVEL=unknown
    CK_WHY="没走 Cloudflare，但从这台 VPS 用 HTTPS 访问不了它，看不出是不是走别的 CDN（伪装域名要能从 VPS 访问，REALITY 才能用）"
  fi
}

check_key() { # 回落目标 -> 去重用的键：域名不分大小写、不带端口；本机回落按原值
  local h
  h=$(parse_target_host "$1")
  if is_local_host "$h"; then echo "本机 $1"; return; fi
  h=${h,,}
  echo "${h%.}"
}

join_cn() { local out="" x; for x in "$@"; do out+="${out:+、}$x"; done; printf '%s' "$out"; }

cmd_check() {
  local files=() domains=() f d kind val key name w verbose=0 got xui_cfg=0 partial=0 i
  local -A where=() first=() not_db=()
  local keys=() used=() bad=() risk=() unknown=() lv=() why=() ips=()
  while (( $# )); do
    case $1 in
      -v|--verbose) verbose=1; shift; continue ;;
      --file|--domain) (( $# >= 2 )) || die "$1 后面需要一个值" ;;
      *) die "未知参数：$1（用法：$APP check [-v] [--file 配置文件] [--domain 伪装域名]）" ;;
    esac
    if [[ $1 == --file ]]; then files+=("$2"); else domains+=("$2"); fi
    shift 2
  done
  if (( ${#files[@]} == 0 && ${#domains[@]} == 0 )); then
    mapfile -t files < <(config_candidates | sort -u)
  fi
  CHECK_BAD=0 CHECK_WARN=0 CHECK_UNKNOWN=0
  echo "== 伪装域名体检（REALITY 的回落目标 target / dest）=="

  # 先收集、按域名去重：同一个域名常在多个配置、多个入站里重复出现。
  # x-ui 面板的数据库和它生成的 config.json 都要看：面板可能不重启 xray、直接热更新入站，config.json 不一定是最新的；
  # 数据库是按字节扫的，也可能扫到删掉的旧记录。所以只在数据库里出现的域名照样判断，只是加一句说明
  for f in ${files[@]+"${files[@]}"}; do
    [[ -r $f ]] || { warn "读不到 $f（需要 root？）"; continue; }
    got=0
    while IFS=$'\t' read -r kind val; do
      [[ -n $val ]] || continue
      key=$(check_key "$val"); [[ -n $key ]] || continue
      got=1
      if [[ -z ${first[$key]+x} ]]; then first[$key]=$val; where[$key]=""; keys+=("$key"); fi
      [[ $f == */x-ui.db ]] || not_db[$key]=1
      [[ "、${where[$key]}、" == *"、$f、"* ]] || where[$key]+="${where[$key]:+、}$f"
    done < <(extract_targets "$f")
    if (( got )); then
      used+=("$f")
      [[ $f == */x-ui/bin/config.json ]] && xui_cfg=1
    fi
  done
  for d in ${domains[@]+"${domains[@]}"}; do
    key=$(check_key "$d"); [[ -n $key ]] || continue
    if [[ -z ${first[$key]+x} ]]; then first[$key]=$d; where[$key]=""; keys+=("$key"); fi
    not_db[$key]=1
    [[ "、${where[$key]}、" == *"、手动指定、"* ]] || where[$key]+="${where[$key]:+、}手动指定"
  done

  if (( ${#keys[@]} == 0 )); then
    echo "体检做完了：没在常见位置找到 REALITY 配置，没有可查的。"
    echo "如果用了 REALITY、配置放在别处，可以手动指定："
    echo "  $APP check --file /路径/config.json      或      $APP check --domain 你的伪装域名"
    return 0
  fi
  (( ${#used[@]} )) && echo "查了这些配置：$(join_cn "${used[@]}")"

  # 每个域名只解析、访问一次
  for key in "${keys[@]}"; do
    if [[ $key == "本机 "* ]]; then name=${first[$key]}; else name=$key; fi
    check_one "${first[$key]}"
    (( CK_PARTIAL )) && partial=1
    # 面板生成的 config.json 里没有、只在面板数据库里找到的
    (( xui_cfg )) && [[ -z ${not_db[$key]+x} ]] && CK_WHY+="（只在面板数据库里找到：面板里已经没有这个域名的话，是删掉的旧记录，不用管）"
    lv+=("$CK_LEVEL"); why+=("$CK_WHY"); ips+=("$CK_IPS")
    case $CK_LEVEL in
      bad)     CHECK_BAD=$((CHECK_BAD + 1)); bad+=("$name") ;;
      risk)    CHECK_WARN=$((CHECK_WARN + 1)); risk+=("$name") ;;
      unknown) CHECK_UNKNOWN=$((CHECK_UNKNOWN + 1)); unknown+=("$name") ;;
    esac
  done

  echo
  if (( CHECK_BAD )); then
    echo "结论：危险。伪装域名 $(join_cn "${bad[@]}") 走的是 Cloudflare，别人可以借你的 VPS 中转、偷你的流量，建议尽快换掉。"
    (( CHECK_WARN )) && echo "另外 $(join_cn "${risk[@]}") 也有风险，建议一起换掉。"
  elif (( CHECK_WARN )); then
    echo "结论：有风险。建议换掉伪装域名 $(join_cn "${risk[@]}")，别人可能借你的 VPS 偷流量。"
  elif (( CHECK_UNKNOWN )); then
    echo "结论：没法判断。伪装域名 $(join_cn "${unknown[@]}") 没查成（原因见下面）。请确认域名没写错，过一会儿再运行 $APP check。"
  else
    echo "结论：没发现问题。查到的伪装域名没有走 Cloudflare，也没看出走别的 CDN。"
    (( partial )) && echo "本机没装 curl，是不是走别的 CDN 没查（Cloudflare 照常查了）。装上 curl 再运行一次更准。"
  fi
  echo
  for i in "${!keys[@]}"; do
    key=${keys[$i]}
    if [[ $key == "本机 "* ]]; then name=${first[$key]}; else name=$key; fi
    case ${lv[$i]} in
      bad) w="[危险]" ;; risk) w="[有风险]" ;; unknown) w="[没法判断]" ;; *) w="[没发现问题]" ;;
    esac
    echo "  $w $name：${why[$i]}"
    if (( verbose )); then
      [[ -n ${ips[$i]} ]] && echo "      解析到：${ips[$i]}"
      [[ -n ${where[$key]} ]] && echo "      出现在：${where[$key]}"
    fi
  done

  if (( CHECK_BAD || CHECK_WARN )); then
    echo
    echo "为什么：REALITY 会把没通过验证的连接原样转给伪装域名。伪装域名走 CDN 时，别人能把你的 VPS 当成去 CDN 的中转站，用掉的是你的流量。"
    echo "怎么办："
    echo "  1. 挑一个能用 HTTPS 打开、不走 CDN 的普通网站（最好和 VPS 在同一个国家或机房），"
    echo "     先运行 $APP check --domain 新域名 看看，至少要显示“没发现问题”。"
    echo "  2. 在面板的入站设置（REALITY 那一栏）或配置文件里，把 target（有的叫 dest）和 serverNames（SNI）都换成它。"
    echo "  3. 保存后，客户端里的 SNI（serverName）也改成同一个域名。"
    if [[ -f $CONF ]] && grep -q '^PAUSED="1"' "$STATE" 2>/dev/null; then
      echo "  本工具的自动限速现在是暂停状态，被偷用不会限速；运行 $APP resume 可以恢复。"
    elif [[ -f $CONF ]] && grep -q '^STATUS="error"' "$STATE" 2>/dev/null; then
      echo "  注意：本工具现在没法限速（运行 $APP status 看原因），先别指望它兜底。"
    elif [[ -f $CONF ]]; then
      echo "  暂时不会改也别慌：本工具正常运行时，每日流量额度会兜底，当天额度用完就限速，不会一下子把整月流量跑光。"
      echo "  （运行 $APP status 可以确认它在正常工作。）"
    else
      echo "  暂时不会改的话，可以装上本工具（$APP install），用每日流量额度兜底。"
    fi
  fi
  if (( verbose )); then
    if (( CHECK_BAD || CHECK_WARN )); then
      echo
      echo "进阶建议："
      echo "  - Xray 官方文档建议选与 VPS 同一 ASN（同机房 / 同运营商）的网站当 target。"
      echo "  - 用自己的域名在本机 Nginx 上建一个站，target 指向本机（俗称“偷自己”）。"
      echo "  - 确实要继续用，可在 realitySettings 里设置 limitFallbackUpload / limitFallbackDownload 限制回落流量。"
      echo "    Xray 官方提醒：回落限速本身是一种特征，不建议默认启用，参数应随机化。"
      echo "  - 改完要重启 xray / sing-box（面板里保存后一般会自动重启）。"
    fi
    echo "判断依据：Cloudflare 按官方公布的 IP 段比对，结论可靠；微软、苹果、Cloudflare 的域名按名单判断；其他 CDN 只按响应头推测，仅供参考。"
  else
    echo
    echo "想看解析到的 IP、每个域名出现在哪个配置里、判断依据和进阶建议：$APP check -v"
  fi
  (( CHECK_BAD > 0 )) && return 2
  return 0
}

# ---------------------------------------------------------------- 命令：selftest（在真机上一键自检）

ST_PASS=0 ST_FAIL=0 ST_SKIP=0 ST_TMP="" ST_IFACE=""
ST_BUILT=0    # 1 = 当前网卡上的 htb 7e5d: 是本次自检建的（只有这种才由自检撤销）
ST_RESCUE=0   # 1 = 本次自检设置了 3 分钟自动撤销保险

st_res() { # ok|fail|skip 描述
  case $1 in
    ok)   ST_PASS=$((ST_PASS + 1)); echo "  [通过] $2" ;;
    fail) ST_FAIL=$((ST_FAIL + 1)); echo "  [失败] $2" ;;
    skip) ST_SKIP=$((ST_SKIP + 1)); echo "  [跳过] $2" ;;
  esac
}
st_eq() { if [[ $2 == "$3" ]]; then st_res ok "$1"; else st_res fail "$1（期望 [$3]，实际 [$2]）"; fi; }

fmt_rate() { awk -v b="$1" 'BEGIN { if (b >= 1e6) printf "%.2f MB/s（%.1f Mbps）", b / 1e6, b * 8 / 1e6; else printf "%.0f KB/s（%.2f Mbps）", b / 1e3, b * 8 / 1e6 }'; }

class_bytes() { # 类别 -> 已发送字节
  "$TC" -s class show dev "$IFACE" 2>/dev/null | awk -v c="$1" '$1 == "class" { cur = $3 } $1 == "Sent" && cur == c { print $2; exit }'
}

st_upload() { # 秒数：向 Cloudflare 测速接口上传随机数据，用来制造出站流量
  curl -s -o /dev/null --max-time "$1" -X POST -H 'Content-Type: application/octet-stream' \
    --data-binary @"$ST_TMP/payload" "https://speed.cloudflare.com/__up" >/dev/null 2>&1
  return 0
}

selftest_undo() { # 撤销本次自检建的限速；确认撤销成功才取消保险。成功返回 0
  local rq
  if (( ST_BUILT == 1 )); then
    rq=$(root_qdisc_of "$ST_IFACE")
    [[ -z $rq ]] && return 1                                   # 读不到现状：不敢判定，保留保险
    if [[ $rq == "htb $QH:" ]]; then
      "$TC" qdisc del dev "$ST_IFACE" root 2>/dev/null
      rq=$(root_qdisc_of "$ST_IFACE")
      [[ -z $rq || $rq == "htb $QH:" ]] && return 1            # 没删掉：保留保险，3 分钟后系统再试
    fi
  fi
  ST_BUILT=0
  if (( ST_RESCUE == 1 )); then
    systemctl stop vtg-selftest-rescue.timer >/dev/null 2>&1 && ST_RESCUE=0
  fi
  return 0
}

selftest_cleanup() {
  selftest_undo
  [[ $ST_TMP == /tmp/vtg-selftest.* ]] && rm -rf -- "$ST_TMP"
  return 0
}

cmd_selftest() {
  require_root
  local no_speed=0 c miss="" opt="" ports live nports rq0 rq1 skip_tc="" out f
  local tx0 tx1 t0 t1 base=0 b0 b1 meas s0 s1 cip sdev=""
  [[ ${1-} == --no-speed ]] && no_speed=1
  ST_TMP=$(mktemp -d /tmp/vtg-selftest.XXXXXX) || die "创建临时目录失败"
  trap selftest_cleanup EXIT
  trap 'exit 130' INT TERM HUP PIPE

  echo "== $APP $VERSION 自检 =="
  echo "会临时限速约 15 秒来验证 tc（SSH 端口不限速；脚本退出或 3 分钟后都会自动撤销）。"
  (( no_speed )) || echo "测速会向 speed.cloudflare.com 上传约 10 MB 随机数据。"
  echo "最后的 REALITY 体检会解析你配置里的回落目标域名，并访问一次该网站（推测是否为 CDN）。"
  echo

  echo "【1】环境"
  echo "  系统：$( (. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-未知}") )，内核 $(uname -r)"
  if (( BASH_VERSINFO[0] >= 4 )); then st_res ok "bash $BASH_VERSION"; else st_res fail "bash 版本太低：$BASH_VERSION（需要 4 以上）"; fi
  for c in ip "$TC" awk date systemctl; do command -v "$c" >/dev/null 2>&1 || miss+=" ${c##*/}"; done
  if [[ -z $miss ]]; then st_res ok "必需命令齐全（ip tc awk date systemctl）"; else st_res fail "缺少命令：$miss（RHEL 系的 tc 在 iproute-tc 包）"; fi
  for c in flock curl ss; do command -v "$c" >/dev/null 2>&1 || opt+=" $c"; done
  [[ -n $opt ]] && st_res skip "缺少可选命令：$opt（flock=防并发，curl=测速和 CDN 推测，ss=识别 SSH 端口）"
  ST_IFACE=$(detect_iface)
  if [[ $ST_IFACE =~ ^[A-Za-z0-9_.-]{1,15}$ && -r $SYS_NET/$ST_IFACE/statistics/tx_bytes ]]; then
    st_res ok "默认网卡：$ST_IFACE"
  else
    st_res fail "找不到默认路由所在的网卡"; ST_IFACE=""
  fi
  IFACE=$ST_IFACE
  echo "  根队列：$(root_qdisc_of "$IFACE")    默认队列：$(sysctl -n net.core.default_qdisc 2>/dev/null)    拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"

  echo "【2】计算逻辑（本机 bash / awk / date）"
  st_eq "账期：31 号重置遇到 2 月按月底算" \
    "$(RESET_DAY=31; cycle_bounds "$(date -d '2026-02-15 12:00' +%s)"; echo "$(fmt_day "$CB_START")~$(fmt_day "$CB_NEXT")")" "2026-01-31~2026-02-28"
  st_eq "账期：跨年" \
    "$(RESET_DAY=1; cycle_bounds "$(date -d '2026-12-31 23:00' +%s)"; echo "$(fmt_day "$CB_START")~$(fmt_day "$CB_NEXT")")" "2026-12-01~2027-01-01"
  st_eq "GB 换算" "$(gb_to_bytes 123.4)" "123400000000"
  st_eq "流量显示" "$(fmt_gb 1500000000)" "1.5 GB"
  st_eq "Cloudflare 网段判断" "$(is_cf_ip 104.16.1.1 && echo y)$(is_cf_ip 2a06:98c7::1 && echo y)$(is_cf_ip 8.8.8.8 || echo n)" "yyn"
  f="$ST_TMP/sample.json"
  printf '%s\n' '{"inbounds":[{"streamSettings":{"realitySettings":{"show":false,' '"target":"a.example:443"}}},' \
    '{"tls":{"reality":{"enabled":true,"handshake":{"server":"b.example","server_port":443}}}}]}' > "$f"
  st_eq "读取 Xray / sing-box 配置" "$(extract_targets "$f" | tr '\t\n' '=;')" "xray=a.example:443;singbox=b.example;"
  printf 'QUOTA_GB=2048 # 注释\nEXEMPT_PORTS="22 2222"  # 注释\n' > "$ST_TMP/c.conf"
  st_eq "读取带注释的配置" "$(QUOTA_GB="" EXEMPT_PORTS=""; kv_load "$ST_TMP/c.conf" "$CONF_KEYS"; echo "$QUOTA_GB|$EXEMPT_PORTS")" "2048|22 2222"

  echo "【3】systemd 单元"
  if command -v systemd-analyze >/dev/null 2>&1; then
    # ExecStart 指向 /bin/true，只检查单元写法，不受临时目录是否 noexec 影响
    if ( BIN_PATH=/bin/true; UNIT_DIR="$ST_TMP/units"; mkdir -p "$UNIT_DIR" && write_units ); then
      out=$(systemd-analyze verify "$ST_TMP/units/$APP.service" "$ST_TMP/units/$APP.timer" "$ST_TMP/units/$APP-save.service" 2>&1)
      if grep -q "$APP" <<< "$out"; then st_res fail "单元文件有问题：$(grep "$APP" <<< "$out" | head -3 | tr '\n' ' ')"
      else st_res ok "单元文件语法检查通过"; fi
    else
      st_res fail "无法生成测试用的单元文件"
    fi
  else
    st_res skip "没有 systemd-analyze，跳过单元语法检查"
  fi

  echo "【4】SSH 端口"
  ports=$(detect_ssh_ports)
  live=$(live_ssh_ports | grep -E '^[0-9]{1,5}$' | sort -un | tr '\n' ' '); live=${live% }
  echo "  识别到的 SSH 端口：$ports    正在使用中的 SSH 连接端口：${live:-无}"
  EXEMPT_PORTS=$ports
  add_current_ssh_port 2>/dev/null
  if [[ -n $live ]]; then st_res ok "正在使用的 SSH 端口都在不限速列表里：$EXEMPT_PORTS"
  else st_res skip "没检测到正在使用的 SSH 连接（不是通过 SSH 运行，或没有 ss 命令）"; fi

  echo "【5】真实限速（1 Mbps，约 15 秒）"
  if [[ -z $IFACE ]] || ! command -v "$TC" >/dev/null 2>&1; then
    skip_tc="缺少网卡或 tc 命令"
  else
    take_lock    # 先拿锁再看网卡现状，避免和正在运行的定时任务撞车
    rq0=$(root_qdisc_of "$IFACE")
    if [[ $rq0 == "htb $QH:" ]]; then skip_tc="本工具正在限速，先执行 $APP pause 再自检"
    elif has_custom_qdisc "$IFACE"; then skip_tc="网卡上有别人加的 tc 队列（$rq0），按设计不会去动它"
    elif ! command -v systemd-run >/dev/null 2>&1; then skip_tc="没有 systemd-run，无法设置自动撤销保险，为安全起见不做真实限速"
    else
      systemctl stop vtg-selftest-rescue.timer vtg-selftest-rescue.service >/dev/null 2>&1
      systemctl reset-failed vtg-selftest-rescue.service >/dev/null 2>&1
      if systemd-run --quiet --on-active=180 --timer-property=AccuracySec=1s --unit=vtg-selftest-rescue /bin/sh -c \
           "tc qdisc show dev $IFACE | grep -q 'htb $QH:' && tc qdisc del dev $IFACE root" >/dev/null 2>&1; then
        ST_RESCUE=1
        echo "  已设置保险：3 分钟后系统会自动撤销测试限速"
      else
        skip_tc="无法设置 3 分钟自动撤销保险（systemd-run 失败），为安全起见不做真实限速"
      fi
    fi
  fi
  if [[ -n $skip_tc ]]; then
    st_res skip "$skip_tc"
  else
    init_state_defaults
    if (( no_speed == 0 )) && command -v curl >/dev/null 2>&1; then
      head -c 10000000 /dev/urandom > "$ST_TMP/payload"
      echo "  测量不限速时的上传速度……"
      tx0=$(<"$SYS_NET/$IFACE/statistics/tx_bytes"); t0=$(date +%s%N)
      st_upload 6
      tx1=$(<"$SYS_NET/$IFACE/statistics/tx_bytes"); t1=$(date +%s%N)
      base=$(( (tx1 - tx0) * 1000000000 / (t1 - t0 + 1) ))
      echo "  不限速：$(fmt_rate "$base")"
    fi
    ST_BUILT=1
    if tc_build 1000; then
      st_eq "根队列换成本工具的 htb $QH:" "$(root_qdisc_of "$IFACE")" "htb $QH:"
      read -ra nports <<< "$EXEMPT_PORTS"
      st_eq "SSH 豁免规则（每个端口 IPv4、IPv6 各 1 条）" \
        "$("$TC" filter show dev "$IFACE" parent "$QH:" 2>/dev/null | grep -c "flowid $QH:10")" "$(( ${#nports[@]} * 2 ))"
      if (( no_speed == 0 )) && command -v curl >/dev/null 2>&1; then
        echo "  测量限速后的上传速度（约 12 秒）……"
        b0=$(class_bytes "$QH:20"); t0=$(date +%s%N)
        st_upload 12
        b1=$(class_bytes "$QH:20"); t1=$(date +%s%N)
        if [[ -z $b0 || -z $b1 ]]; then
          st_res fail "读不到 tc 统计数据"
        else
          meas=$(( (b1 - b0) * 1000000000 / (t1 - t0 + 1) ))
          echo "  限速 1 Mbps：$(fmt_rate "$meas")（理论上限约 125 KB/s）"
          if (( base < 300000 )); then st_res skip "不限速时测速流量太少（连不上 speed.cloudflare.com？），无法判断限速效果"
          elif (( meas > 20000 && meas <= 162500 )); then st_res ok "限速生效：出站速度被压在 1 Mbps 左右"
          else st_res fail "限速效果不对：实测 $(fmt_rate "$meas")"; fi
        fi
      else
        st_res skip "没测速（没有 curl 或加了 --no-speed）"
      fi
      cip=$(awk '{ print $1 }' <<< "${SSH_CONNECTION:-}")
      [[ -n $cip ]] && sdev=$(ip route get "$cip" 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
      if [[ -z $live ]]; then
        st_res skip "不是通过 SSH 运行，跳过 SSH 通道检查"
      elif [[ -n $sdev && $sdev != "$IFACE" ]]; then
        st_res skip "你的 SSH 走的是 $sdev 网卡，不是被测的 $IFACE，跳过 SSH 通道检查"
      else
        s0=$(class_bytes "$QH:10")
        echo "  （这一行和下一行经 SSH 发给你，用来检验 SSH 走不限速通道）"
        echo "  ……"
        sleep 1
        s1=$(class_bytes "$QH:10")
        if (( ${s1:-0} > ${s0:-0} )); then st_res ok "SSH 流量走的是不限速通道（+$(( ${s1:-0} - ${s0:-0} )) 字节）"
        else st_res fail "没看到 SSH 流量进入不限速通道（如果你是经内网或其他网卡登录的，此项可忽略）"; fi
      fi
    else
      st_res fail "建立限速队列失败（见上方 tc 报错）"
    fi
    if selftest_undo; then
      rq1=$(root_qdisc_of "$IFACE")
      if [[ ${rq1#* } == "0:" ]]; then
        st_res ok "撤销后回到系统默认队列（$rq1）"
        [[ ${rq1%% *} != "${rq0%% *}" ]] && echo "  说明：原来是 ${rq0%% *}，现在是系统当前设置的默认队列 ${rq1%% *}，属正常"
      else
        st_res fail "撤销后根队列不对：$rq1"
      fi
    else
      st_res fail "撤销测试限速失败；3 分钟保险仍在，届时系统会再撤销一次"
    fi
  fi

  echo "【6】REALITY 回落目标体检"
  cmd_check | sed 's/^/  /'

  echo
  echo "== 自检结果：通过 $ST_PASS，失败 $ST_FAIL，跳过 $ST_SKIP =="
  if (( ST_FAIL == 0 )); then echo "可以安装：bash $SELF install"; fi
  echo "（把上面整段输出复制发给开发者即可）"
  (( ST_FAIL == 0 ))
}

# ---------------------------------------------------------------- 入口

usage() {
  cat <<EOF
$APP $VERSION：自建代理 VPS 的每日流量额度 + REALITY 回落目标体检

用法：
  bash $APP.sh install       安装（交互式填写套餐流量、重置日、计费方式）
  $APP status         查看本期用量、今日额度、是否在限速
  $APP check          伪装域名体检：REALITY 的 target 是否走 Cloudflare 等 CDN，或是微软、苹果的域名（-v 看详情）
  $APP set-used 123.4 按商家面板校准本期已用流量（GB）
  $APP pause | resume 暂停 / 恢复自动限速（暂停期间仍计数）
  $APP uninstall      卸载，并撤销本工具加的限速
  bash $APP.sh selftest      在本机一键自检（会临时限速约 15 秒；加 --no-speed 不测速）

关端口（可选，安装时也会问一句）：
  $APP ports              列出对公网开放的端口：哪些保留、哪些可以关
  $APP ports close        关掉认得出的高风险端口（数据库、缓存等）；$FW_RESCUE 秒内不确认自动撤销
  $APP ports confirm      确认上一步（非交互时用）
  $APP ports open 6379    重新打开某个端口；$APP ports off 全部打开
  $APP ports restore      按已确认的列表重新加上规则（被别的程序清掉时用）
  SSH、80/443、面板、代理和认不出的程序永远不关；手动指定端口也一样。

install 的参数（不想交互时用）：
  --quota 1000          套餐每月流量（GB）
  --reset-day 5         每月几号重置
  --mode both           计费方式：both=双向 out=仅出站 in=仅入站 max=取大值（默认 both）
  --used 0              本期面板已用（GB）
  --threshold 90        用到套餐百分之多少后不再发额度（默认 90）
  --throttle auto       超额后的限速（kbit/s），auto 自动计算
  --iface eth0          统计的网卡（默认取默认路由所在网卡）
  --exempt-ports "22"   永不限速的端口（默认自动识别 SSH 端口；正在使用中的 SSH 连接端口会自动加入）
  --close-ports         顺便关掉认得出的高风险端口（默认不关；和 --yes 一起用时需在 $FW_RESCUE 秒内运行 $APP ports confirm）
  -y, --yes             不交互
EOF
}

main() {
  local cmd=${1:-help}
  (( $# )) && shift
  case $cmd in
    install)        cmd_install "$@" ;;
    status)         cmd_status ;;
    check)          cmd_check "$@" ;;
    set-used)       cmd_set_used "$@" ;;
    pause)          cmd_pause_resume 1 ;;
    resume)         cmd_pause_resume 0 ;;
    tick)           cmd_tick ;;
    selftest)       cmd_selftest "$@" ;;
    ports)          cmd_ports "$@" ;;
    uninstall)      cmd_uninstall "$@" ;;
    version|-v|--version) echo "$APP $VERSION" ;;
    help|-h|--help) usage ;;
    *)              usage; exit 1 ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
