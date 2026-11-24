#!/usr/bin/env bash
# 离线逻辑测试：用假的网卡计数、假的 tc、假的时间驱动脚本，不需要 root，也不会动真实网络。
# 注意：假 tc 不校验命令语法，tc 和 systemd 的真实效果需要在 Linux VPS 上另行验证。
# 用法：bash tests/run-tests.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../vps-traffic-guard.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export TZ=UTC
export VTG_SKIP_ROOT=1
export VTG_CONF="$WORK/etc/vps-traffic-guard.conf"
export VTG_STATE_DIR="$WORK/var/vps-traffic-guard"
export VTG_SYS_NET="$WORK/sys"
export VTG_TC="$HERE/fake-tc.sh"
export VTG_LOCK="$WORK/lock"
export VTG_BIN="$WORK/bin/vps-traffic-guard"
export VTG_UNIT_DIR="$WORK/systemd"
export FAKE_TC_DIR="$WORK/tc"
export VTG_PORTS_FILE="$WORK/etc/vps-traffic-guard.ports"
export VTG_NFT="$HERE/fake-nft.sh"
export VTG_IPT="$WORK/fw/iptables"
export VTG_IP6T="$WORK/fw/ip6tables"
export FAKE_FW_DIR="$WORK/fwstate"
unset SSH_CONNECTION
chmod +x "$VTG_TC" "$VTG_NFT" "$HERE/fake-iptables.sh" 2>/dev/null
mkdir -p "$WORK/etc" "$VTG_SYS_NET/eth0/statistics" "$VTG_SYS_NET/eth1/statistics" "$FAKE_TC_DIR" "$WORK/fw" "$FAKE_FW_DIR"
for t in iptables ip6tables; do
  printf '#!/usr/bin/env bash\nexec bash "%s/fake-iptables.sh" %s "$@"\n' "$HERE" "$t" > "$WORK/fw/$t"
  chmod +x "$WORK/fw/$t"
done
echo 0 > "$VTG_SYS_NET/eth1/statistics/rx_bytes"; echo 0 > "$VTG_SYS_NET/eth1/statistics/tx_bytes"

# shellcheck source=../vps-traffic-guard.sh
source "$SCRIPT"
set +e

PASS=0 FAIL=0
ok() { # 描述 命令...
  local d=$1; shift
  if "$@"; then PASS=$((PASS + 1)); echo "ok   - $d"; else FAIL=$((FAIL + 1)); echo "FAIL - $d"; fi
}
eq() { [[ "$1" == "$2" ]] || { echo "       期望 [$2] 实际 [$1]" >&2; return 1; }; }
st() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" "$VTG_STATE_DIR/state"; }
at() { VTG_NOW=$(date -d "$1" +%s); export VTG_NOW; }
cnt() { echo "$1" > "$VTG_SYS_NET/eth0/statistics/rx_bytes"; echo "$2" > "$VTG_SYS_NET/eth0/statistics/tx_bytes"; }
root() { cat "$FAKE_TC_DIR/root.${1:-eth0}" 2>/dev/null || echo "fq 0:"; }
setroot() { echo "$2" > "$FAKE_TC_DIR/root.$1"; }
calls() { local n; n=$(grep -c -- "$1" "$FAKE_TC_DIR/calls.log" 2>/dev/null); echo "${n:-0}"; }
tick() { ( cmd_tick ) >/dev/null 2>&1; }
G=1000000000
OURS="htb 7e5d:"

write_conf() { # 套餐 重置日 计费方式 不限速端口 网卡
  cat > "$VTG_CONF" <<EOF
IFACE="${5:-eth0}"
QUOTA_GB="${1:-1000}"
RESET_DAY="${2:-1}"
COUNT_MODE="${3:-both}"
THRESHOLD="90"
THROTTLE_KBIT="auto"
EXEMPT_PORTS="${4:-22 2222}"
EOF
}
fresh() { rm -rf "$VTG_STATE_DIR" "$FAKE_TC_DIR"; mkdir -p "$FAKE_TC_DIR"; }
throttle_now() { # 从零开始，让 eth0 进入“今日额度用完”的限速状态（11-05，额度约 34.6G）
  fresh; write_conf "$@"
  at "2026-11-05 00:00:30"; cnt 0 0; tick
  at "2026-11-05 01:00"; cnt $((20*G)) $((20*G)); tick
}

echo "## 账期计算"
RESET_DAY=31
cycle_bounds "$(date -d '2026-02-15 12:00' +%s)"
ok "31 号重置，2 月取月底：起点 1-31" eq "$(fmt_day "$CB_START")" 2026-01-31
ok "31 号重置，2 月取月底：终点 2-28" eq "$(fmt_day "$CB_NEXT")" 2026-02-28
cycle_bounds "$(date -d '2026-02-28 00:00:00' +%s)"
ok "正好在重置时刻：进入新账期" eq "$(fmt_day "$CB_START")~$(fmt_day "$CB_NEXT")" "2026-02-28~2026-03-31"
RESET_DAY=1
cycle_bounds "$(date -d '2026-12-31 23:59' +%s)"
ok "跨年：12-01 ~ 次年 01-01" eq "$(fmt_day "$CB_START")~$(fmt_day "$CB_NEXT")" "2026-12-01~2027-01-01"
RESET_DAY=15
cycle_bounds "$(date -d '2026-01-10' +%s)"
ok "跨年往前：2025-12-15 ~ 2026-01-15" eq "$(fmt_day "$CB_START")~$(fmt_day "$CB_NEXT")" "2025-12-15~2026-01-15"

echo "## 0 点切换夏令时的时区（Git Bash 的 date 不认 TZ，这里用假 date 模拟“当天 0 点不存在”）"
no_midnight() { date() { if [[ "$*" == *"2026-09-06 00:00:00"* ]]; then echo "date: invalid date" >&2; return 1; fi; command date "$@"; }; }
dst=$( no_midnight; RESET_DAY=1; t=$(date -d '2026-09-06 12:00' +%s); cycle_bounds "$t"; days_left "$t" )
ok "当天没有 0 点也能算出剩余天数（9-06 到 10-01 共 25 天）" eq "$dst" 25
dst=$( no_midnight; RESET_DAY=6; cycle_bounds "$(date -d '2026-09-10 12:00' +%s)"; fmt_day "$CB_START" )
ok "重置日正好是切换日：账期起点仍正确" eq "$dst" 2026-09-06
dst=$( no_midnight; date -d '2026-09-06 00:00:00' +%s 2>/dev/null; echo "rc=$?" )
ok "假 date 确实让 0 点失败（测试本身有效）" eq "$dst" "rc=1"

echo "## 换算"
ok "123.4 GB 换成字节" eq "$(gb_to_bytes 123.4)" 123400000000
ok "拒绝非数字" bash -c "source '$SCRIPT'; ! gb_to_bytes abc"
QUOTA_GB=1000 THRESHOLD=90 THROTTLE_KBIT=auto COUNT_MODE=both RESET_DAY=1
cycle_bounds "$(date -d '2026-11-10' +%s)"
ok "自动限速：1000G 双向 30 天 = 1388 kbit" eq "$(throttle_cap_kbit)" 1388
COUNT_MODE=out
ok "自动限速：1000G 单向 30 天 = 2777 kbit" eq "$(throttle_cap_kbit)" 2777
COUNT_MODE=both

echo "## Cloudflare 网段判断"
for ip in 104.16.1.1 172.64.0.1 172.71.255.255 131.0.72.5 2606:4700::6810:1 2a06:98c7::1 2400:cb00:2048:1::1 ::ffff:104.16.1.1; do
  ok "$ip 属于 Cloudflare" is_cf_ip "$ip"
done
for ip in 8.8.8.8 172.72.0.1 104.32.0.1 2a06:98c8::1 2001:db8::1 2606:4701::1 1.1.1.1; do
  ok "$ip 不属于 Cloudflare 列表" bash -c "source '$SCRIPT'; ! is_cf_ip '$ip'"
done

echo "## target 解析"
ok "域名带端口" eq "$(parse_target_host www.example.com:443)" www.example.com
ok "IPv4 带端口" eq "$(parse_target_host 1.2.3.4:443)" 1.2.3.4
ok "IPv6 带括号" eq "$(parse_target_host '[2606:4700::1]:443')" 2606:4700::1
ok "只有端口 = 本机" eq "$(parse_target_host 8443)" local
ok "unix socket = 本机" eq "$(parse_target_host /dev/shm/a.sock)" local
ok "127.0.0.1 判为本机" is_local_host 127.0.0.1

cat > "$WORK/xray.json" <<'EOF'
{
  "inbounds": [{
    "port": 443, "protocol": "vless",
    "settings": { "fallbacks": [{ "dest": 8080 }] },
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {
        "show": false,
        "target": "www.cf-site.example:443",
        "serverNames": ["www.cf-site.example"],
        "privateKey": "x", "shortIds": [""]
      }
    }
  }, {
    "port": 8443, "protocol": "vless",
    "streamSettings": { "security": "reality",
      "realitySettings": { "dest": "127.0.0.1:8001", "serverNames": ["a.example"] } }
  }]
}
EOF
cat > "$WORK/sb.json" <<'EOF'
{"inbounds":[{"type":"vless","tls":{"enabled":true,"server_name":"www.apple.com",
 "reality":{"enabled":true,"handshake":{"server":"www.apple.com","server_port":443},"private_key":"x"}}}]}
EOF
printf 'junk\000\000{\\"network\\": \\"tcp\\", \\"security\\": \\"reality\\", \\"realitySettings\\": {\\"show\\": false, \\"dest\\": \\"yahoo.com:443\\"}}' > "$WORK/x-ui.db"
ok "Xray 配置：取到两个 target" eq "$(extract_targets "$WORK/xray.json" | tr '\t\n' '=;')" "xray=www.cf-site.example:443;xray=127.0.0.1:8001;"
ok "sing-box 配置：取到 handshake.server" eq "$(extract_targets "$WORK/sb.json" | tr '\t\n' '=;')" "singbox=www.apple.com;"
ok "3x-ui 数据库（转义 JSON）：取到 dest" eq "$(extract_targets "$WORK/x-ui.db" | tr '\t\n' '=;')" "xray=yahoo.com:443;"
CHECK_BAD=0; check_one xray "104.16.1.1:443" >/dev/null
ok "check_one：CF IP 记为危险" eq "$CHECK_BAD" 1
CHECK_BAD=0; check_one xray "[2606:4700::1]:443" >/dev/null
ok "check_one：CF IPv6 记为危险" eq "$CHECK_BAD" 1
CHECK_BAD=0; check_one xray "127.0.0.1:8001" >/dev/null
ok "check_one：本机回落不算危险" eq "$CHECK_BAD" 0

echo "## 配置解析"
cat > "$WORK/evil.conf" <<EOF
IFACE=\$(touch $WORK/pwned)
QUOTA_GB="1000"; touch $WORK/pwned2
RESET_DAY="1"
EOF
( init_conf_defaults; kv_load "$WORK/evil.conf" "$CONF_KEYS"; echo "$IFACE|$QUOTA_GB|$RESET_DAY" ) > "$WORK/evil.out"
ok "恶意配置不会被执行" bash -c "[[ ! -e '$WORK/pwned' && ! -e '$WORK/pwned2' ]]"
ok "恶意行被忽略，正常行保留" eq "$(cat "$WORK/evil.out")" "||1"
cat > "$WORK/comment.conf" <<'EOF'
IFACE=eth0
QUOTA_GB=1000 # 套餐
RESET_DAY="5"   # 重置日
EXEMPT_PORTS="22 2222"  # ssh
EOF
( init_conf_defaults; kv_load "$WORK/comment.conf" "$CONF_KEYS"; echo "$QUOTA_GB|$RESET_DAY|$EXEMPT_PORTS" ) > "$WORK/comment.out"
ok "行尾注释也能正确读取" eq "$(cat "$WORK/comment.out")" "1000|5|22 2222"

echo "## 每日额度：1000G 双向，每月 1 号重置"
fresh; write_conf 1000 1 both
at "2026-11-01 00:00:30"; cnt $((5*G)) $((5*G)); tick
ok "首次运行：取基准，不计已有计数" eq "$(st CYCLE_RX)/$(st CYCLE_TX)" "0/0"
ok "首日额度 = 900G / 30 天 = 30G" eq "$(st DAY_BUDGET)" $((30*G))
at "2026-11-01 01:00"; cnt $((15*G)) $((15*G)); tick
ok "用了 20G（进出各 10G）：仍满速" eq "$(st STATUS)" normal
at "2026-11-01 02:00"; cnt $((21*G)) $((21*G)); tick
ok "用到 32G：超过 30G 额度，开始限速" eq "$(st STATUS)" throttled
ok "限速速率 = 自动值 1388 kbit" eq "$(st APPLIED_KBIT)" 1388
ok "根队列换成本工具的 htb 7e5d:" eq "$(root)" "$OURS"
ok "SSH 端口 22 加了 IPv4 豁免" eq "$(calls 'match ip sport 22 0xffff')" 1
ok "端口 2222 加了 IPv6 豁免" eq "$(calls 'match ip6 sport 2222 0xffff')" 1
at "2026-11-01 03:00"; cnt $((21*G+1000)) $((21*G+1000)); tick
ok "继续限速时不重复建队列" eq "$(calls 'qdisc replace')" 1
at "2026-11-02 00:00:30"; cnt $((22*G)) $((22*G)); tick
ok "次日 0 点：恢复满速" eq "$(st STATUS)" normal
ok "次日 0 点：撤掉 htb，回到系统默认队列" eq "$(root)" "fq 0:"
ok "次日额度 = (900-34)/29 天" eq "$(st DAY_BUDGET)" $(( (900*G - 34*G) / 29 ))

echo "## 重启（计数器归零）"
at "2026-11-02 01:00"; cnt $((1*G)) $((1*G)); tick
ok "归零后按新计数累加：入站 17G+1G" eq "$(st CYCLE_RX)" $((18*G))
at "2026-11-02 02:00"; cnt $((16*G)) $((16*G)); tick
ok "当天用超：限速" eq "$(st STATUS)" throttled
setroot eth0 "fq 0:"     # 模拟重启后 tc 规则消失
at "2026-11-02 02:05"; cnt $((G/2)) $((G/2)); tick
ok "重启后自动重新加上限速" eq "$(root)" "$OURS"
ok "重建队列（第 3 次 replace）" eq "$(calls 'qdisc replace')" 3

echo "## 面板校准 / 触发线"
at "2026-11-02 03:00"; ( cmd_set_used 905 ) >/dev/null 2>&1
ok "校准后本期已用 = 905G" eq "$( ( load_all; billed ) )" $((905*G))
ok "超过 900G 触发线：今日额度为 0" eq "$(st DAY_BUDGET)" 0
ok "到触发线：限速" eq "$(st STATUS)" throttled
# 剩余 980-905=75G，到 12-01 还有 29 天 - 3 小时，双向：75e9/(2*2494800)=15031 B/s → 120 kbit
ok "速率自动压低，按到月底不超 98% 计算" eq "$(st APPLIED_KBIT)" 120

echo "## 暂停 / 恢复"
( cmd_pause_resume 1 ) >/dev/null 2>&1
ok "暂停：撤掉限速" eq "$(st STATUS)/$(root)" "paused/fq 0:"
( cmd_pause_resume 0 ) >/dev/null 2>&1
ok "恢复：重新限速" eq "$(st STATUS)/$(root)" "throttled/$OURS"

echo "## 新账期"
at "2026-12-01 00:00:30"; cnt $((G/2 + G)) $((G/2 + G)); tick
ok "12-01：计数清零后只算新增" eq "$(st CYCLE_RX)/$(st CYCLE_OFFSET)" "$G/0"
ok "12-01：恢复满速" eq "$(st STATUS)" normal
ok "12 月额度 = 900G / 31 天" eq "$(st DAY_BUDGET)" $(( (900*G - 2*G) / 31 ))
ok "事件记录了新账期" grep -q "新账期开始" "$VTG_STATE_DIR/events.log"

echo "## 改重置日不清零"
write_conf 1000 15 both
at "2026-12-01 01:00"; cnt $((2*G + G/2)) $((2*G + G/2)); tick
ok "改成 15 号：账期对齐到 11-15，计数保留" eq "$(fmt_day "$(st CYCLE_START)")/$(st CYCLE_RX)" "2026-11-15/$((2*G))"

echo "## 状态文件和实际规则对不上时，仍能撤掉限速"
throttle_now
ok "前提：已限速" eq "$(st STATUS)/$(root)" "throttled/$OURS"
sed -i 's/^APPLIED=.*/APPLIED="0"/' "$VTG_STATE_DIR/state"
at "2026-11-06 00:00:30"; tick
ok "状态写着未限速，次日照样撤掉本工具的 htb" eq "$(st STATUS)/$(root)" "normal/fq 0:"
throttle_now
rm -f "$VTG_STATE_DIR/state"
at "2026-11-05 01:01"; tick
ok "状态文件丢失：重新计数，满速并撤掉限速" eq "$(st STATUS)/$(root)" "normal/fq 0:"

echo "## 限速中修改不限速端口"
throttle_now 1000 1 both "22"
write_conf 1000 1 both "22 2200"
at "2026-11-05 01:01"; tick
ok "新端口 2200 立即加上豁免" eq "$(calls 'match ip sport 2200 0xffff')" 1
ok "仍在限速" eq "$(st STATUS)/$(root)" "throttled/$OURS"

echo "## 限速中换网卡"
throttle_now
write_conf 1000 1 both "22" eth1
at "2026-11-05 01:01"; tick
ok "旧网卡 eth0 上的限速被撤掉" eq "$(root eth0)" "fq 0:"
ok "新网卡 eth1 接着限速" eq "$(root eth1)" "$OURS"
setroot eth1 "fq 0:"

echo "## 换网卡时旧网卡撤销失败：之后每分钟重试"
throttle_now
write_conf 1000 1 both "22" eth1
at "2026-11-05 01:01"; FAKE_TC_FAIL="qdisc del dev eth0" tick
ok "撤销失败：旧网卡仍有限速，记下待清理" eq "$(root eth0)/$(st CLEANUP_IFACE)" "$OURS/eth0"
at "2026-11-05 01:02"; tick
ok "下一分钟重试成功：旧网卡恢复，待清理清空" eq "$(root eth0)/$(st CLEANUP_IFACE)" "fq 0:/"
setroot eth1 "fq 0:"

echo "## 网卡名写错时撤掉限速"
throttle_now
write_conf 1000 1 both "22" eth9
at "2026-11-05 01:01"; tick
ok "读不到 eth9 计数：撤掉 eth0 上本工具的限速" eq "$(root eth0)" "fq 0:"

echo "## 配置写坏时撤掉限速"
throttle_now
sed -i 's/^QUOTA_GB=.*/QUOTA_GB="abc"/' "$VTG_CONF"
at "2026-11-05 01:01"; tick
ok "配置无效：tick 撤掉所有网卡上本工具的限速" eq "$(root eth0)" "fq 0:"

echo "## 不碰别人的 tc 规则"
fresh; write_conf 1000 1 both
setroot eth0 "htb 1:"
at "2026-11-05 00:00:30"; cnt 0 0; tick
at "2026-11-05 01:00"; cnt $((20*G)) $((20*G)); tick
ok "别人的 htb 1:：不替换，状态为 error" eq "$(st STATUS)/$(root)" "error/htb 1:"
ok "事件里说明了原因" grep -q "已有别人加的 tc 队列" "$VTG_STATE_DIR/events.log"
at "2026-11-06 00:00:30"; tick
ok "次日也不会删别人的 htb 1:" eq "$(root)" "htb 1:"
( cmd_pause_resume 1 ) >/dev/null 2>&1
ok "暂停也不会删别人的 htb 1:" eq "$(root)" "htb 1:"
ok "全程没有执行 qdisc del" eq "$(calls 'qdisc del')" 0
fresh; write_conf 1000 1 both
setroot eth0 "fq 8001:"
at "2026-11-05 00:00:30"; cnt 0 0; tick
at "2026-11-05 01:00"; cnt $((20*G)) $((20*G)); tick
ok "手动加的 fq 8001:（句柄非 0）：不替换" eq "$(st STATUS)/$(root)" "error/fq 8001:"
setroot eth0 "mq 0:"
echo "qdisc fq 8001: parent :1 limit 10000p" > "$FAKE_TC_DIR/root.eth0.extra"
at "2026-11-05 01:01"; tick
ok "默认 mq 0: 下有人手动挂了 fq 8001:：不替换" eq "$(st STATUS)/$(root)" "error/mq 0:"
echo "qdisc fq 0: parent :1 limit 10000p" > "$FAKE_TC_DIR/root.eth0.extra"
at "2026-11-05 01:02"; tick
ok "系统默认的 mq 0:（子队列也是 0:）：可以替换" eq "$(st STATUS)/$(root)" "throttled/$OURS"

echo "## tc 失败时回滚"
fresh; write_conf 1000 1 both
at "2026-11-05 00:00:30"; cnt 0 0; tick
at "2026-11-05 01:00"; cnt $((20*G)) $((20*G))
FAKE_TC_FAIL="classid 7e5d:20" tick
ok "建分类失败：撤回半成品队列" eq "$(st STATUS)/$(root)/$(st APPLIED)" "error/fq 0:/0"

echo "## 单向计费"
fresh; write_conf 1000 1 out
at "2026-11-01 00:00:30"; cnt 0 0; tick
at "2026-11-01 05:00"; cnt $((40*G)) $((29*G)); tick
ok "只算出站：出 29G < 30G，满速" eq "$(st STATUS)" normal

echo "## SSH 端口识别"
# 用假 ss 顶替真实命令，避免在真机上读到本机真实的连接、干扰断言。
# 输出来自 ss.listen（ss -tulnp）和 ss.estab（ss -tn / -tnp），默认都是空的
mkdir -p "$WORK/shim"
: > "$WORK/ss.listen"; : > "$WORK/ss.estab"
cat > "$WORK/shim/ss" <<EOF
#!/usr/bin/env bash
case "\$*" in
  -tulnp) cat "$WORK/ss.listen" ;;
  -tn|-tnp) cat "$WORK/ss.estab" ;;
esac
exit 0
EOF
printf '%s\n' '#!/usr/bin/env bash' 'echo "Status: ${FAKE_UFW:-inactive}"' > "$WORK/shim/ufw"
chmod +x "$WORK/shim/ss" "$WORK/shim/ufw"
PATH="$WORK/shim:$PATH"
r=$( SSH_CONNECTION="1.2.3.4 5555 10.0.0.2 2222"; detect_ssh_ports )
ok "从当前 SSH 会话识别出 2222（结果：$r）" bash -c '[[ " $1 " == *" 2222 "* ]]' _ "$r"
r=$( EXEMPT_PORTS="22"; SSH_CONNECTION="1.2.3.4 5555 10.0.0.2 2222"; add_current_ssh_port 2>/dev/null; echo "$EXEMPT_PORTS" )
ok "当前会话端口不在列表里时自动加入" eq "$r" "22 2222"

echo "## install / uninstall（假 systemctl / ip）"
fresh; rm -f "$VTG_CONF"
mkdir -p "$WORK/shim"
# 假 systemctl：记录调用；is-active 只对 FAKE_ACTIVE 里列出的单元返回“运行中”；
# show -p SubState：FAKE_ACTIVE 里的单元报 FAKE_SUBSTATE（默认 waiting），其他报 dead
cat > "$WORK/shim/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$WORK/systemctl.log"
if [[ \$1 == is-active ]]; then [[ " \${FAKE_ACTIVE:-} " == *" \${*: -1} "* ]]; exit \$?; fi
if [[ \$1 == show ]]; then
  if [[ " \${FAKE_ACTIVE:-} " == *" \${*: -1} "* ]]; then echo "SubState=\${FAKE_SUBSTATE:-waiting}"; else echo "SubState=dead"; fi
fi
exit 0
EOF
cat > "$WORK/shim/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *addr*) echo "2: eth0    inet 10.0.0.2/24 brd 10.0.0.255 scope global eth0"
          echo "2: eth0    inet6 2001:db8::2/64 scope global" ;;
  *)      echo "default via 10.0.0.1 dev eth0 proto static" ;;
esac
EOF
chmod +x "$WORK/shim/"*
at "2026-11-10 12:00"; cnt $((3*G)) $((3*G))
out=$(SSH_CONNECTION="1.2.3.4 5555 10.0.0.2 2222" PATH="$WORK/shim:$PATH" cmd_install --quota 1000 --reset-day 1 --used 300 --exempt-ports 22 --yes </dev/null 2>&1)
ok "安装成功" bash -c "[[ -x '$VTG_BIN' && -f '$VTG_UNIT_DIR/vps-traffic-guard.timer' ]]"
ok "启用了定时器" grep -q "enable --now vps-traffic-guard.timer" "$WORK/systemctl.log"
ok "配置里写入了网卡 eth0" grep -q 'IFACE="eth0"' "$VTG_CONF"
ok "当前 SSH 会话端口 2222 自动加入豁免" grep -q 'EXEMPT_PORTS="22 2222"' "$VTG_CONF"
ok "按面板校准：已用 300G" eq "$( ( load_all; billed ) )" $((300*G))
# (900-300)/21 天（11-10 到 12-01）
ok "今日额度 = 600G / 21 天" eq "$(st DAY_BUDGET)" $(( 600*G / 21 ))
ok "安装输出包含状态" bash -c 'grep -q "今日额度" <<< "$1"' _ "$out"
setroot eth0 "$OURS"; setroot eth1 "htb 1:"
( PATH="$WORK/shim:$PATH" cmd_uninstall --yes ) >/dev/null 2>&1
ok "卸载：删除程序、配置、状态、单元" bash -c "[[ ! -e '$VTG_BIN' && ! -e '$VTG_CONF' && ! -e '$VTG_STATE_DIR' && ! -e '$VTG_UNIT_DIR/vps-traffic-guard.timer' ]]"
ok "卸载：撤掉本工具的限速" eq "$(root eth0)" "fq 0:"
ok "卸载：不碰别人的 htb 1:" eq "$(root eth1)" "htb 1:"

echo "## selftest（假 tc，不测速）"
fresh
printf '#!/usr/bin/env bash\necho "$*" >> "%s/systemd-run.log"\nexit ${FAKE_SDRUN_RC:-0}\n' "$WORK" > "$WORK/shim/systemd-run"
chmod +x "$WORK/shim/systemd-run"
out=$( PATH="$WORK/shim:$PATH" cmd_selftest --no-speed 2>&1 ); rc=$?
ok "selftest 跑完并给出结果" bash -c 'grep -q "自检结果" <<< "$1"' _ "$out"
ok "selftest 没有失败项（rc=$rc）" eq "$rc" 0
ok "selftest 先设置了 3 分钟保险" grep -q "on-active=180" "$WORK/systemd-run.log"
ok "selftest 中建立过本工具的队列" grep -q "root handle 7e5d: htb" "$FAKE_TC_DIR/calls.log"
ok "selftest 结束后撤销了测试限速" eq "$(root eth0)" "fq 0:"
ok "selftest 撤销成功后取消了保险" grep -q "stop vtg-selftest-rescue.timer" "$WORK/systemctl.log"
ok "selftest 清理了临时目录" bash -c '! ls -d /tmp/vtg-selftest.* >/dev/null 2>&1'

fresh; : > "$FAKE_TC_DIR/calls.log"
out=$( FAKE_SDRUN_RC=1 PATH="$WORK/shim:$PATH" cmd_selftest --no-speed 2>&1 ); rc=$?
ok "保险设置失败：跳过真实限速" bash -c 'grep -q "无法设置 3 分钟自动撤销保险" <<< "$1"' _ "$out"
ok "保险设置失败：完全没碰网卡队列" bash -c '! grep -q "root handle 7e5d:" "$1"' _ "$FAKE_TC_DIR/calls.log"

fresh; setroot eth0 "$OURS"; : > "$FAKE_TC_DIR/calls.log"
out=$( PATH="$WORK/shim:$PATH" cmd_selftest --no-speed 2>&1 ); rc=$?
ok "已安装且正在限速：selftest 跳过真实限速" bash -c 'grep -q "本工具正在限速" <<< "$1"' _ "$out"
ok "已安装且正在限速：selftest 不撤销正式限速" eq "$(root eth0)" "$OURS"
setroot eth0 "fq 0:"
[[ $rc == 0 ]] || echo "$out" | grep -E '失败|错误' | sed 's/^/       /'

# ---------------------------------------------------------------- 关端口（假 ss / nft / iptables / systemd-run）
export FAKE_ACTIVE="vtg-ports-rescue.timer"   # 假 systemctl：撤销保险在倒计时（试用中）
has() { grep -q -- "$2" <<< "$1" || { echo "       没找到 [$2]" >&2; return 1; }; }
hasnt() { ! grep -q -- "$2" <<< "$1" || { echo "       不该有 [$2]" >&2; return 1; }; }
fwcalls() { cat "$FAKE_FW_DIR/calls.log" 2>/dev/null; }
PF="$VTG_PORTS_FILE"
PEND="$VTG_STATE_DIR/ports.pending"
PUNIT="$VTG_UNIT_DIR/vps-traffic-guard-ports.service"
TABLE="$FAKE_FW_DIR/nft.table"
fwfresh() {
  rm -rf "$FAKE_FW_DIR"; mkdir -p "$FAKE_FW_DIR"
  rm -f "$PF" "$PUNIT" "$PEND"
  : > "$WORK/systemctl.log"; : > "$WORK/systemd-run.log"
}
install_base() { # 先装好限流（不关端口）
  fresh; fwfresh; rm -f "$VTG_CONF"
  at "2026-11-10 12:00"; cnt $((3*G)) $((3*G))
  cmd_install --quota 1000 --reset-day 1 --used 300 --exempt-ports "22 2222" --yes "$@" </dev/null 2>&1
}

cat > "$WORK/ss.listen" <<'EOF'
Netid State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
udp   UNCONN 0      0      127.0.0.53%lo:53         0.0.0.0:*     users:(("systemd-resolve",pid=600,fd=13))
udp   UNCONN 0      0      10.0.0.2%eth0:68         0.0.0.0:*     users:(("systemd-network",pid=500,fd=20))
udp   UNCONN 0      0      0.0.0.0:111              0.0.0.0:*     users:(("rpcbind",pid=700,fd=5))
udp   UNCONN 0      0      *:51820                  *:*
udp   UNCONN 0      0      0.0.0.0:11211            0.0.0.0:*     users:(("memcached",pid=710,fd=27))
udp   UNCONN 0      0      [fe80::1%eth0]:546       [::]:*        users:(("systemd-network",pid=500,fd=21))
udp   UNCONN 0      0      *:443                    *:*           users:(("hysteria",pid=720,fd=8))
tcp   LISTEN 0      4096   0.0.0.0:22               0.0.0.0:*     users:(("sshd",pid=800,fd=3))
tcp   LISTEN 0      4096   [::]:22                  [::]:*        users:(("sshd",pid=800,fd=4))
tcp   LISTEN 0      4096   0.0.0.0:111              0.0.0.0:*     users:(("rpcbind",pid=700,fd=4))
tcp   LISTEN 0      511    0.0.0.0:80               0.0.0.0:*     users:(("nginx",pid=900,fd=7),("nginx",pid=901,fd=7))
tcp   LISTEN 0      4096   *:443                    *:*           users:(("xray",pid=1000,fd=3))
tcp   LISTEN 0      4096   *:2053                   *:*           users:(("xray-linux-amd6",pid=1001,fd=9))
tcp   LISTEN 0      4096   *:54321                  *:*           users:(("x-ui",pid=1002,fd=8))
tcp   LISTEN 0      511    0.0.0.0:6379             0.0.0.0:*     users:(("redis-server",pid=1100,fd=6))
tcp   LISTEN 0      511    [::]:6379                [::]:*        users:(("redis-server",pid=1100,fd=7))
tcp   LISTEN 0      151    127.0.0.1:3306           0.0.0.0:*     users:(("mysqld",pid=1200,fd=20))
tcp   LISTEN 0      151    0.0.0.0:3307             0.0.0.0:*     users:(("mysqld",pid=1201,fd=20))
tcp   LISTEN 0      4096   172.17.0.1:5432          0.0.0.0:*     users:(("postgres",pid=1300,fd=5))
tcp   LISTEN 0      4096   0.0.0.0:27017            0.0.0.0:*     users:(("mongod",pid=1400,fd=11))
tcp   LISTEN 0      4096   0.0.0.0:8080             0.0.0.0:*     users:(("docker-proxy",pid=1500,fd=4))
tcp   LISTEN 0      4096   10.0.0.2:11211           0.0.0.0:*     users:(("memcached",pid=710,fd=26))
tcp   LISTEN 0      4096   0.0.0.0:2375             0.0.0.0:*     users:(("dockerd",pid=1600,fd=3),("python3",pid=1601,fd=3))
tcp   LISTEN 0      4096   0.0.0.0:33060            0.0.0.0:*     users:(("mysqld",pid=1201,fd=21))
tcp   LISTEN 0      4096   [::]:33060               [::]:*        users:(("haproxy",pid=1700,fd=5))
EOF
cat > "$WORK/ss.estab" <<'EOF'
State Recv-Q Send-Q Local Address:Port Peer Address:Port Process
ESTAB 0      0      10.0.0.2:22        1.2.3.4:5555      users:(("sshd",pid=2000,fd=4))
ESTAB 0      0      10.0.0.2:27017     5.6.7.8:40000     users:(("mongod",pid=1400,fd=30))
ESTAB 0      0      127.0.0.1:6379     127.0.0.1:50000   users:(("redis-server",pid=1100,fd=9))
EOF
CANDS="111/tcp 111/udp 6379/tcp 11211/tcp 11211/udp"

echo "## 关端口：扫描与分类"
scan=$( IFACE=eth0 EXEMPT_PORTS="22 2222"; ports_scan )
ok "可关闭的只有程序名和端口都对得上的高风险服务" eq "$(awk '$1 == "close" { printf "%s ", $2 }' <<< "$scan")" "$CANDS "
ok "只听 127.0.0.1 的 3306 不列出" hasnt "$scan" " 3306/tcp "
ok "只听 docker0 地址的 5432 不列出" hasnt "$scan" " 5432/tcp "
ok "只听本网卡地址的 11211/tcp 算对外开放" has "$scan" "^close 11211/tcp memcached"
ok "面板 x-ui 保留" has "$scan" "^keep 54321/tcp x-ui"
ok "xray 节点端口保留" has "$scan" "^keep 2053/tcp xray-linux-amd6"
ok "mysqld 用了非默认端口 3307：认不准，保留" has "$scan" "^keep 3307/tcp mysqld"
ok "mongod 正有外部连接：算在用，保留" has "$scan" "^keep 27017/tcp mongod 正在有外部连接"
ok "只有本机连着的 redis 仍可关" has "$scan" "^close 6379/tcp redis-server"
ok "同一个 socket 上还有认不出的程序（dockerd + python3）：保留" has "$scan" "^keep 2375/tcp dockerd,python3"
ok "同一个 socket 上的多个同名进程只记一次" has "$scan" "^keep 80/tcp nginx 网站"
ok "同一端口上还有认不出的程序：保留" has "$scan" "^keep 33060/tcp mysqld,haproxy"
ok "docker-proxy 保留" has "$scan" "^keep 8080/tcp docker-proxy"
ok "读不到程序名的 51820/udp（WireGuard）保留" has "$scan" "^keep 51820/udp -"
ok "443/udp（hysteria）保留" has "$scan" "^keep 443/udp hysteria"
ok "SSH 22 标为 SSH" has "$scan" "^keep 22/tcp sshd SSH"
ok "IPv4、IPv6 两个 redis 监听合并成一行" eq "$(grep -c ' 6379/tcp ' <<< "$scan")" 1
ok "表格里显示“关闭 / 保留”" has "$(ports_print_table "" <<< "$scan")" "关闭  6379/tcp"
ok "已关闭的显示“已关”" has "$(ports_print_table "6379/tcp" <<< "$scan")" "已关  6379/tcp"
ok "没有程序名时显示为系统内核或未知程序" has "$(ports_print_table "" <<< "$scan")" "51820/udp  系统内核或未知程序"
ok "最后一道过滤：去掉 SSH、不限速端口和 80/443" \
  eq "$( EXEMPT_PORTS="22 2222"; ports_protect "22/tcp 2222/udp 80/tcp 443/udp 6379/tcp 6379/tcp" )" "6379/tcp"
ok "端口写法：6379 = tcp+udp" eq "$(ports_parse 6379 111/udp)" "6379/tcp 6379/udp 111/udp"
ok "端口写法：拒绝 70000、abc、111/sctp" bash -c "source '$SCRIPT'; ! ports_parse 70000 && ! ports_parse abc && ! ports_parse 111/sctp"
printf 'PORTS_IFACE="eth0"\nCLOSED_PORTS="6379/tcp 99999/tcp abc 111/sctp 06379/tcp"\n' > "$WORK/bad.ports"
ok "端口文件里的坏条目被忽略" eq "$( VTG_PORTS_FILE="$WORK/bad.ports"; PORTS_FILE="$WORK/bad.ports"; load_ports; echo "$CLOSED_PORTS" )" "6379/tcp"
printf 'PORTS_IFACE="eth0"\nCLOSED_PORTS="6379/tcp"; touch %s/pwned3\n' "$WORK" > "$WORK/evil.ports"
( PORTS_FILE="$WORK/evil.ports"; load_ports ) >/dev/null 2>&1
ok "恶意端口文件不会被执行" bash -c "[[ ! -e '$WORK/pwned3' ]]"
nft_rules=$(fw_nft_rules eth0 "6379/tcp 111/udp 11211/tcp")
ok "nft 脚本：同一事务里先建、再删、再建（原子替换）" eq "$(head -3 <<< "$nft_rules" | tr '\n' ';')" \
  "table inet vps_traffic_guard;delete table inet vps_traffic_guard;table inet vps_traffic_guard {;"
ok "nft 脚本：只挡外网网卡进来的 TCP SYN" has "$nft_rules" 'iifname "eth0" tcp dport { 6379, 11211 } tcp flags & (syn | ack) == syn counter drop'
ok "nft 脚本：UDP 端口" has "$nft_rules" 'iifname "eth0" udp dport { 111 } counter drop'
ok "nft 脚本：挂在 input、默认放行" has "$nft_rules" "type filter hook input priority 0; policy accept;"
ok "nft 脚本：只有 TCP 时不出现 UDP 规则" hasnt "$(fw_nft_rules eth0 "6379/tcp")" "udp dport"

echo "## 关端口：不选就完全不碰防火墙"
out=$(install_base)
ok "安装（没加 --close-ports）：限流照常装好" bash -c "[[ -x '$VTG_BIN' && -f '$VTG_UNIT_DIR/vps-traffic-guard.timer' ]]"
ok "安装（没加 --close-ports）：没调用过 nft / iptables" eq "$(fwcalls)" ""
ok "安装（没加 --close-ports）：没设置撤销保险" bash -c "! grep -q vtg-ports-rescue '$WORK/systemd-run.log'"
ok "安装（没加 --close-ports）：没有端口文件和端口单元" bash -c "[[ ! -e '$PF' && ! -e '$PUNIT' ]]"
ok "安装（没加 --close-ports）：配置文件里没有端口相关的新键" bash -c "! grep -q 'CLOSED_PORTS\|PORTS_IFACE' '$VTG_CONF'"
ok "状态里提示关端口未开启" has "$out" "关闭端口：未开启"
at "2026-11-10 12:05"; tick
ok "每分钟的定时任务不碰防火墙" eq "$(fwcalls)" ""
out=$( ( load_all; take_lock; ports_offer 1 0 ) <<< "n" 2>&1 )
ok "交互时列出可关闭的端口" has "$out" "关闭  6379/tcp"
ok "交互选“不关”：没调用 nft / iptables" eq "$(fwcalls)" ""
ok "交互选“不关”：没设置保险、没写文件" bash -c "[[ ! -s '$WORK/systemd-run.log' && ! -e '$PF' && ! -e '$PEND' ]]"
ok "交互选“不关”：提示以后怎么关" has "$out" "以后想关"
out=$( ( load_all; take_lock; ports_offer 1 0 ) <<< "" 2>&1 )
ok "直接回车 = 不关" eq "$(fwcalls)" ""

echo "## 关端口：--yes --close-ports 先试用，确认后才保存"
out=$(FAKE_NFT_HITS=7 install_base --close-ports)
ok "先设置了 180 秒自动撤销保险" grep -q -- "--on-active=180 --timer-property=AccuracySec=1s --unit=vtg-ports-rescue" "$WORK/systemd-run.log"
ok "保险只删本工具的表和链，再按已确认的列表恢复" bash -c 'grep -q "nft delete table inet vps_traffic_guard" "$1" && grep -q "ports restore" "$1" && ! grep -q flush "$1"' _ "$WORK/systemd-run.log"
ok "nft 先预检、后生效" eq "$(fwcalls | grep -E '^nft -(c -)?f -$' | tr '\n' ';')" "nft -c -f -;nft -f -;"
ok "规则：TCP 端口" grep -qF 'iifname "eth0" tcp dport { 111, 6379, 11211 } tcp flags & (syn | ack) == syn counter' "$TABLE"
ok "规则：UDP 端口" grep -qF 'iifname "eth0" udp dport { 111, 11211 } counter' "$TABLE"
ok "规则里没有 SSH、80、443、面板" bash -c "! grep -qE '[{ ,](22|80|443|54321|2053)[,} ]' '$TABLE'"
ok "试用中：还没写端口文件、没启用开机恢复" bash -c "[[ ! -e '$PF' ]] && ! grep -q 'enable vps-traffic-guard-ports' '$WORK/systemctl.log'"
ok "试用中：记下了待确认的改动" grep -q "CLOSED_PORTS=\"$CANDS\"" "$PEND"
ok "输出提示 180 秒内运行 ports confirm" has "$out" "180 秒内运行：vps-traffic-guard ports confirm"
ok "状态显示试用中" has "$out" "关闭端口：试用中"
out=$( ( cmd_ports close --yes ) 2>&1 ); rc=$?
ok "试用中再次关端口：拒绝" bash -c '[[ $1 != 0 ]] && grep -q "还在等确认" <<< "$2"' _ "$rc" "$out"
out=$( ( cmd_ports confirm ) 2>&1 ); rc=$?
ok "确认成功（rc=$rc）" eq "$rc" 0
ok "确认后：写入端口文件" grep -q "CLOSED_PORTS=\"$CANDS\"" "$PF"
ok "确认后：写入并启用开机恢复单元" bash -c "grep -q 'ExecStart=$VTG_BIN ports restore' '$PUNIT' && grep -q 'enable vps-traffic-guard-ports.service' '$WORK/systemctl.log'"
ok "确认后：取消了保险" grep -q "stop vtg-ports-rescue.timer" "$WORK/systemctl.log"
ok "确认后：待确认文件已删除" bash -c "[[ ! -e '$PEND' ]]"
out=$( ( cmd_status ) 2>&1 )
ok "状态：列出关闭的端口和拦截数" has "$out" "关闭端口：$CANDS（已拦下 14 个连接请求）"
n0=$(fwcalls | wc -l); at "2026-11-10 12:10"; tick; n1=$(fwcalls | wc -l)
ok "已关端口时，定时任务照样不碰防火墙" eq "$n1" "$n0"
out=$( ( cmd_ports show ) 2>&1 )
ok "ports show：已关的端口标“已关”" has "$out" "已关  6379/tcp"
ok "ports show：没有可再关的就不提示 close" hasnt "$out" "ports close"

echo "## 关端口：开机恢复"
"$VTG_NFT" delete table inet vps_traffic_guard
( cmd_ports restore ) >/dev/null 2>&1
ok "开机恢复：按端口文件重新下规则" grep -qF "tcp dport { 111, 6379, 11211 }" "$TABLE"
printf 'PORTS_IFACE="eth0"\nCLOSED_PORTS="6379/tcp 22/tcp 2222/tcp 443/udp 80/tcp"\n' > "$PF"
( cmd_ports restore ) >/dev/null 2>&1
ok "开机恢复：文件里混进 SSH / 80 / 443 也不会关" bash -c 'grep -qF "tcp dport { 6379 }" "$1" && ! grep -q "udp dport" "$1"' _ "$TABLE"
printf 'PORTS_IFACE="eth0"\nCLOSED_PORTS="%s"\n' "$CANDS" > "$PF"
( cmd_ports restore ) >/dev/null 2>&1
out=$( ( cmd_status ) 2>&1 )
ok "开机恢复后状态正常" has "$out" "关闭端口：$CANDS（已拦下"
"$VTG_NFT" delete table inet vps_traffic_guard
out=$( ( cmd_status ) 2>&1 )
ok "规则被别的程序清掉时，状态里提示恢复办法" has "$out" "规则现在不在"

echo "## 关端口：重新打开"
( cmd_ports restore ) >/dev/null 2>&1
out=$( ( cmd_ports open 6379 ) 2>&1 )
ok "open 6379：规则里去掉 6379" bash -c "grep -qF 'tcp dport { 111, 11211 }' '$TABLE' && ! grep -q 6379 '$TABLE'"
ok "open 6379：端口文件同步更新" grep -q 'CLOSED_PORTS="111/tcp 111/udp 11211/tcp 11211/udp"' "$PF"
out=$( ( cmd_ports open 9999 ) 2>&1 )
ok "open 别人的端口：提示不是本工具关的" has "$out" "不是本工具关的"
: > "$WORK/systemctl.log"
out=$( ( cmd_ports off ) 2>&1 )
ok "off：删掉本工具的表" bash -c "[[ ! -e '$TABLE' ]]"
ok "off：删掉端口文件、停用开机恢复" bash -c "[[ ! -e '$PF' && ! -e '$PUNIT' ]] && grep -q 'disable vps-traffic-guard-ports.service' '$WORK/systemctl.log'"
out=$( ( cmd_ports off ) 2>&1 )
ok "再次 off：说明没有关任何端口" has "$out" "没有关闭任何端口"

echo "## 关端口：交互试用"
fwfresh
out=$( ( load_all; take_lock; ports_offer 1 0 ) <<< $'y\ny' 2>&1 )
ok "交互 y + 确认 y：保存" grep -q "CLOSED_PORTS=\"$CANDS\"" "$PF"
ok "交互 y + 确认 y：取消保险、启用开机恢复" bash -c 'grep -q "stop vtg-ports-rescue.timer" "$1" && grep -q "enable vps-traffic-guard-ports.service" "$1"' _ "$WORK/systemctl.log"
( cmd_ports off ) >/dev/null 2>&1; fwfresh
out=$( ( load_all; take_lock; ports_offer 1 0 ) <<< $'y\nn' 2>&1 )
ok "确认时输入 n：撤销规则" bash -c "[[ ! -e '$TABLE' ]]"
ok "确认时输入 n：不保存、取消保险" bash -c "[[ ! -e '$PF' && ! -e '$PEND' ]] && grep -q 'stop vtg-ports-rescue.timer' '$WORK/systemctl.log'"
ok "确认时输入 n：告诉用户已恢复原样" has "$out" "已撤销，端口恢复原样"
fwfresh
out=$( ( load_all; take_lock; ports_offer 1 0 ) <<< "y" 2>&1 )
ok "等确认时断线 / 超时（没有输入）：撤销" bash -c "[[ ! -e '$TABLE' && ! -e '$PF' && ! -e '$PEND' ]]"
fwfresh
printf 'PORTS_IFACE="eth0"\nCLOSED_PORTS="6379/tcp"\n' > "$PF"
( cmd_ports restore ) >/dev/null 2>&1
out=$( ( load_all; take_lock; ports_offer 1 0 ) <<< $'y\nn' 2>&1 )
ok "已有确认过的端口时撤销：回到原来那份规则" bash -c "grep -qF 'tcp dport { 6379 }' '$TABLE' && ! grep -q 'udp dport' '$TABLE'"
ok "已有确认过的端口时撤销：端口文件不变" grep -q 'CLOSED_PORTS="6379/tcp"' "$PF"
ok "已确认的端口在表格里显示“已关”" has "$out" "已关  6379/tcp"
printf 'PORTS_IFACE="eth0"\nCLOSED_PORTS="22/tcp 2222/tcp 443/udp 6379/tcp"\n' > "$PF"
out=$( ( load_all; take_lock; ports_offer 1 0 ) <<< $'y\nn' 2>&1 )
ok "端口文件被改成含 SSH / 443：试用时也不会关" bash -c '! grep -qE "[{ ,](22|2222|443)[,} ]" "$1/nft.checked"' _ "$FAKE_FW_DIR"

echo "## 关端口：超时自动撤销"
( cmd_ports off ) >/dev/null 2>&1; fwfresh
( cmd_ports close --yes ) >/dev/null 2>&1
ok "非交互 ports close --yes：进入试用" bash -c "[[ -e '$PEND' && -e '$TABLE' ]]"
"$VTG_NFT" delete table inet vps_traffic_guard; ( cmd_ports restore ) >/dev/null 2>&1   # 保险到点：删表，再按已确认的列表恢复
ok "超时后：待确认文件删除，规则保持撤销" bash -c "[[ ! -e '$PEND' && ! -e '$TABLE' ]]"
ok "超时后：事件里记下自动撤销" grep -q "没有确认，已自动撤销" "$VTG_STATE_DIR/events.log"
out=$( ( cmd_ports confirm ) 2>&1 ); rc=$?
ok "超时后再确认：提示没有待确认的改动" bash -c '[[ $1 != 0 ]] && grep -q "没有等待确认的改动" <<< "$2"' _ "$rc" "$out"
( cmd_ports close --yes ) >/dev/null 2>&1
"$VTG_NFT" delete table inet vps_traffic_guard      # 保险删了表，但恢复那一步没跑成
out=$( ( cmd_ports confirm ) 2>&1 ); rc=$?
ok "规则已被撤销时确认：拒绝，不保存" bash -c '[[ $1 != 0 && ! -e $2 ]] && grep -q "已经被自动撤销" <<< "$3"' _ "$rc" "$PF" "$out"
ok "规则已被撤销时确认：作废这次试用，不会卡住" bash -c "[[ ! -e '$PEND' ]]"
( cmd_ports close --yes ) >/dev/null 2>&1
"$VTG_NFT" delete table inet vps_traffic_guard      # 模拟试用中途重启：规则和保险都没了，试用文件还在
out=$( ( FAKE_ACTIVE=""; cmd_status ) 2>&1 )
ok "保险已不在的旧试用：状态不再显示“试用中”" hasnt "$out" "试用中"
out=$( ( FAKE_ACTIVE=""; cmd_ports close --yes ) 2>&1 )
ok "保险已不在的旧试用：作废后可以重新关" bash -c "[[ -e '$PEND' && -e '$TABLE' ]] && grep -q '已作废' '$VTG_STATE_DIR/events.log'"
( cmd_ports confirm ) >/dev/null 2>&1; ( cmd_ports off ) >/dev/null 2>&1
( cmd_ports close --yes ) >/dev/null 2>&1
"$VTG_NFT" delete table inet vps_traffic_guard      # 保险触发了、恢复那步却失败：临时定时器还挂着“active (elapsed)”
out=$( ( export FAKE_SUBSTATE=elapsed; cmd_status ) 2>&1 )
ok "保险已触发（定时器停在 elapsed）：状态不显示“试用中”" hasnt "$out" "试用中"
out=$( ( export FAKE_SUBSTATE=elapsed; cmd_ports close --yes 6379 ) 2>&1 )
ok "保险已触发（定时器停在 elapsed）：旧试用作废，可以重新关" grep -q 'CLOSED_PORTS="6379/tcp 6379/udp"' "$PEND"
( cmd_ports confirm ) >/dev/null 2>&1; ( cmd_ports off ) >/dev/null 2>&1
out=$( ( cmd_ports close --yes 6379 22 ) 2>&1 )
ok "指定端口关闭：SSH 端口被自动去掉" bash -c "grep -q 'CLOSED_PORTS=\"6379/tcp 6379/udp\"' '$PEND'"
( cmd_ports confirm ) >/dev/null 2>&1
ok "指定端口关闭：确认后保存" grep -q 'CLOSED_PORTS="6379/tcp 6379/udp"' "$PF"
( cmd_ports off ) >/dev/null 2>&1
out=$( ( cmd_ports close --yes 54321 2053 27017 ) 2>&1 )
ok "指定端口：面板、节点、正有外网连接的端口一律不关" bash -c '[[ ! -e $1 ]] && grep -q "不关 54321/tcp：正被 x-ui 使用" <<< "$2" && grep -q "不关 2053/tcp" <<< "$2" && grep -q "不关 27017/tcp：正被 mongod 使用（正在有外部连接" <<< "$2"' _ "$PEND" "$out"
out=$( ( cmd_ports close --yes 3307/tcp ) 2>&1 )
ok "指定端口：改了端口的 mysqld（3307）可以手动关" grep -q 'CLOSED_PORTS="3307/tcp"' "$PEND"
( cmd_ports confirm ) >/dev/null 2>&1; ( cmd_ports off ) >/dev/null 2>&1
cp "$WORK/ss.estab" "$WORK/ss.estab.bak"
echo 'ESTAB 0      0      10.0.0.2:3307      5.6.7.9:41000     users:(("mysqld",pid=1201,fd=31))' >> "$WORK/ss.estab"
out=$( ( cmd_ports close --yes 3307 ) 2>&1 )
ok "指定端口：改了端口的 mysqld 正有外网连接，也不关" bash -c '[[ ! -e $1 ]] && grep -q "不关 3307/tcp：正被 mysqld 使用（正在有外部连接" <<< "$2"' _ "$PEND" "$out"
mv "$WORK/ss.estab.bak" "$WORK/ss.estab"
out=$( ( cmd_ports close --yes 6379 54321 ) 2>&1 )
ok "指定端口：在用的端口号整个跳过（54321 的 UDP 也不关），其余照关" grep -q 'CLOSED_PORTS="6379/tcp 6379/udp"' "$PEND"
( cmd_ports confirm ) >/dev/null 2>&1; ( cmd_ports off ) >/dev/null 2>&1
out=$( ( cmd_ports close 6379 ) </dev/null 2>&1 )
ok "非终端里不带 --yes：提示加 --yes，不改" bash -c 'grep -q "加 --yes" <<< "$1" && [[ ! -e $2 ]]' _ "$out" "$PEND"

echo "## 关端口：不适合改防火墙时跳过"
fwfresh
out=$( ( load_all; FAKE_UFW=active ports_offer 0 1 ) 2>&1 )
ok "ufw 已启用：跳过并提示用 ufw" has "$out" "ufw 防火墙已启用"
ok "ufw 已启用：没碰 nft / iptables、没设置保险" bash -c "[[ ! -s '$FAKE_FW_DIR/calls.log' && ! -s '$WORK/systemd-run.log' ]]"
out=$( ( load_all; FAKE_ACTIVE=firewalld ports_offer 0 1 ) 2>&1 )
ok "firewalld 已启用：跳过" bash -c 'grep -q "firewalld 防火墙已启用" <<< "$1" && [[ ! -s $2 ]]' _ "$out" "$FAKE_FW_DIR/calls.log"
mv "$WORK/shim/systemd-run" "$WORK/shim/systemd-run.off"
out=$( ( load_all; ports_offer 0 1 ) 2>&1 )
mv "$WORK/shim/systemd-run.off" "$WORK/shim/systemd-run"
ok "没有 systemd-run：跳过" bash -c 'grep -q "没有 systemd-run" <<< "$1" && [[ ! -e $2 ]]' _ "$out" "$TABLE"
out=$( ( load_all; take_lock; FAKE_SDRUN_RC=1 ports_offer 0 1 ) 2>&1 )
ok "保险设置失败：不改防火墙" bash -c 'grep -q "没能设置" <<< "$1" && ! grep -q "^nft -f -" "$2" && [[ ! -e $3 ]]' _ "$out" "$FAKE_FW_DIR/calls.log" "$PEND"
fwfresh
out=$( ( load_all; take_lock; FAKE_NFT_CHECK_FAIL=1 ports_offer 0 1 ) 2>&1 )
ok "nft 预检没通过（容器型 VPS）：不改，撤掉保险" bash -c 'grep -q "预检没通过" <<< "$1" && [[ ! -e $2 && ! -e $3 ]] && grep -q "stop vtg-ports-rescue.timer" "$4"' _ "$out" "$TABLE" "$PEND" "$WORK/systemctl.log"
ok "nft 预检没通过：没执行真正的 nft -f" bash -c '! grep -qx "nft -f -" "$1"' _ "$FAKE_FW_DIR/calls.log"
: > "$FAKE_FW_DIR/calls.log"
mv "$WORK/ss.listen" "$WORK/ss.listen.bak"; : > "$WORK/ss.listen"
out=$( ( load_all; ports_offer 1 0 ) <<< "y" 2>&1 )
mv -f "$WORK/ss.listen.bak" "$WORK/ss.listen"
ok "没有可关的端口：不问，直接说明" bash -c 'grep -q "没发现多余的对外端口" <<< "$1" && [[ ! -s $2 ]]' _ "$out" "$FAKE_FW_DIR/calls.log"

echo "## 关端口：没有 nft 时用 iptables / ip6tables"
fwfresh
NFT="$WORK/no-such-nft"
echo "-p tcp --dport 8080 -j ACCEPT" > "$FAKE_FW_DIR/iptables.INPUT"
( load_all; take_lock; ports_offer 0 1 ) >/dev/null 2>&1
( cmd_ports confirm ) >/dev/null 2>&1
ok "iptables：本工具链里只丢 SYN" grep -qx -- "-i eth0 -p tcp --dport 6379 --syn -j DROP" "$FAKE_FW_DIR/iptables.VTG_PORTS"
ok "iptables：UDP 端口" grep -qx -- "-i eth0 -p udp --dport 11211 -j DROP" "$FAKE_FW_DIR/iptables.VTG_PORTS"
ok "ip6tables：IPv6 同样有" grep -qx -- "-i eth0 -p tcp --dport 6379 --syn -j DROP" "$FAKE_FW_DIR/ip6tables.VTG_PORTS"
ok "iptables：INPUT 第一条跳到本工具的链，原有规则保留" eq "$(tr '\n' ';' < "$FAKE_FW_DIR/iptables.INPUT")" "-j VTG_PORTS;-p tcp --dport 8080 -j ACCEPT;"
ok "iptables：确认后保存" grep -q "CLOSED_PORTS=\"$CANDS\"" "$PF"
out=$( ( FAKE_IPT_HITS=3 cmd_status ) 2>&1 )
ok "iptables：状态里显示拦截数（v4+v6）" has "$out" "已拦下 30 个连接请求"
( cmd_ports open 111 ) >/dev/null 2>&1
ok "iptables：open 111 后链里没有 111" bash -c "! grep -q 'dport 111 ' '$FAKE_FW_DIR/iptables.VTG_PORTS' && grep -q 'dport 6379 ' '$FAKE_FW_DIR/iptables.VTG_PORTS'"
ok "iptables：重建后跳转规则只有一条" eq "$(grep -c VTG_PORTS "$FAKE_FW_DIR/iptables.INPUT")" 1
NFT="$VTG_NFT"      # 之后装上了 nftables：再改端口时规则搬到 nft 表，旧的 iptables 链要清掉
( cmd_ports open 11211 ) >/dev/null 2>&1
ok "换成 nft 后再改：旧的 iptables / ip6tables 链清掉，原有规则保留" bash -c "[[ ! -e '$FAKE_FW_DIR/iptables.VTG_PORTS' && ! -e '$FAKE_FW_DIR/ip6tables.VTG_PORTS' ]] && [[ \$(cat '$FAKE_FW_DIR/iptables.INPUT') == '-p tcp --dport 8080 -j ACCEPT' ]]"
ok "换成 nft 后再改：剩下的端口由 nft 表挡，打开的 11211 不在里面" bash -c "grep -q 6379 '$TABLE' && ! grep -q 11211 '$TABLE'"
( cmd_ports off ) >/dev/null 2>&1
ok "iptables：off 后删掉本工具的链，原有规则保留" bash -c "[[ ! -e '$FAKE_FW_DIR/iptables.VTG_PORTS' && ! -e '$FAKE_FW_DIR/ip6tables.VTG_PORTS' ]] && [[ \$(cat '$FAKE_FW_DIR/iptables.INPUT') == '-p tcp --dport 8080 -j ACCEPT' ]]"
NFT="$VTG_NFT"

echo "## 关端口：卸载只删本工具的规则"
fwfresh
( load_all; take_lock; ports_offer 0 1 ) >/dev/null 2>&1; ( cmd_ports confirm ) >/dev/null 2>&1
echo "-p tcp --dport 8080 -j ACCEPT" > "$FAKE_FW_DIR/iptables.INPUT"
ok "前提：已关端口" bash -c "[[ -e '$TABLE' && -e '$PF' && -e '$PUNIT' ]]"
( cmd_uninstall --yes ) >/dev/null 2>&1
ok "卸载：删掉本工具的 nft 表" bash -c "[[ ! -e '$TABLE' ]]"
ok "卸载：删掉端口文件和开机恢复单元" bash -c "[[ ! -e '$PF' && ! -e '$PUNIT' ]]"
ok "卸载：停用开机恢复、取消可能还在的保险" bash -c 'grep -q "vps-traffic-guard-ports.service" "$1" && grep -q "stop vtg-ports-rescue.timer" "$1"' _ "$WORK/systemctl.log"
ok "卸载：只动过本工具的表，别人的 iptables 规则保留" bash -c '! grep -E "^nft (delete|flush)" "$1" | grep -qv "inet vps_traffic_guard" && [[ $(cat "$2") == "-p tcp --dport 8080 -j ACCEPT" ]]' _ "$FAKE_FW_DIR/calls.log" "$FAKE_FW_DIR/iptables.INPUT"

# ---------------------------------------------------------------- 短安装入口 i（假 curl：按地址复制本地文件）
echo "## 短安装入口 i"
B="$WORK/boot"; mkdir -p "$B/fake" "$B/bin"
cat > "$B/fake/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while (( $# )); do case $1 in -o) out=$2; shift ;; -*) ;; *) url=$1 ;; esac; shift; done
[[ -f $url ]] || exit 22
cp "$url" "$out"
EOF
chmod +x "$B/fake/curl"
printf '%s\n' '#!/usr/bin/env bash' 'VERSION="t"' 'main() { echo "RAN ARGS:$*"; }' \
  'if [[ ${BASH_SOURCE[0]} == "$0" ]]; then' '  main "$@"' 'fi' > "$B/good.sh"
printf '<html><body>blocked</body></html>\n' > "$B/html.sh"
head -n "$(grep -n '^main() {' "$HERE/../vps-traffic-guard.sh" | cut -d: -f1)" "$HERE/../vps-traffic-guard.sh" | head -n -1 > "$B/cut.sh"
boot() { # 下载源文件 [参数...]：用替身地址、临时安装路径、跳过 root 检查运行 i
  local src=$1; shift
  sed -e "s#local url=.*#local url=\"$B/$src\"#" -e "s#local bin=\"/usr/local/bin/vps-traffic-guard\" tmp#local bin=\"$B/bin/vtg\" tmp#" \
      -e 's#^  \[\[ \$(id -u) == 0 \]\].*#  : 跳过 root 检查#' "$HERE/../i" > "$B/i.$src"
  PATH="$B/fake:$PATH" bash "$B/i.$src" "$@" </dev/null 2>&1
}
ok "主脚本最后两行是 main 调用（i 靠它判断下载完整）" eq "$(tail -n 2 "$HERE/../vps-traffic-guard.sh")" $'  main "$@"\nfi'
ok "截在函数之间的半截主脚本，bash -n 照样通过（所以 i 要另查结尾）" bash -n "$B/cut.sh"
echo OLD > "$B/bin/vtg"
out=$(boot good.sh --yes --quota 500); rc=$?
ok "i：下载正常就安装，参数原样传给 install" bash -c '[[ $1 == 0 ]] && grep -q "RAN ARGS:install --yes --quota 500" <<< "$2" && [[ -x $3 ]] && cmp -s "$3" "$4"' _ "$rc" "$out" "$B/bin/vtg" "$B/good.sh"
for bad in html.sh cut.sh missing.sh; do
  echo OLD > "$B/bin/vtg"
  out=$(boot "$bad"); rc=$?
  ok "i：下载到 $bad 时停下，不覆盖已装的版本" bash -c '[[ $1 != 0 && $(cat "$2") == OLD ]] && ! grep -q "RAN ARGS" <<< "$3"' _ "$rc" "$B/bin/vtg" "$out"
done
for n in -1 25; do   # 只差最后一行 main "$@" / 截在函数中间（用跳过 root 检查的替身版，真执行了就会打印“正在下载”）
  head -n "$n" "$B/i.good.sh" > "$B/i.half"
  out=$(PATH="$B/fake:$PATH" bash "$B/i.half" </dev/null 2>&1)
  ok "i 自己没收完整（head -n $n）：什么都不执行" bash -c '! grep -q "正在下载" <<< "$1" && [[ $(cat "$2") == OLD ]]' _ "$out" "$B/bin/vtg"
done

echo
echo "通过 $PASS，失败 $FAIL"
(( FAIL == 0 ))
