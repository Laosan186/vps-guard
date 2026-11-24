#!/usr/bin/env bash
# 测试用的假 tc：记录每次调用，并为每块网卡用文件模拟根队列（"类型 句柄"）和过滤规则
: "${FAKE_TC_DIR:?}"
echo "$*" >> "$FAKE_TC_DIR/calls.log"
dev="" prev=""
for a in "$@"; do [[ $prev == dev ]] && dev=$a; prev=$a; done
root_file="$FAKE_TC_DIR/root.${dev:-none}"
[[ -f $root_file ]] || echo "fq 0:" > "$root_file"
if [[ -n ${FAKE_TC_FAIL:-} && "$*" == *"$FAKE_TC_FAIL"* ]]; then
  exit 2
fi
if [[ $1 == qdisc && $2 == show ]]; then
  read -r kind handle < "$root_file"
  echo "qdisc $kind $handle root refcnt 2 limit 10000p"
  [[ -f $root_file.extra ]] && cat "$root_file.extra"    # 模拟子队列
  exit 0
fi
if [[ $1 == qdisc && $2 == replace && "$*" =~ " root handle "([0-9a-f]+:)" "([a-z_]+) ]]; then
  echo "${BASH_REMATCH[2]} ${BASH_REMATCH[1]}" > "$root_file"; rm -f "$root_file.extra" "$root_file.filters"; exit 0
fi
if [[ $1 == qdisc && $2 == del && "$*" == *" root"* ]]; then
  echo "fq 0:" > "$root_file"; rm -f "$root_file.extra" "$root_file.filters"; exit 0
fi
if [[ $1 == filter && $2 == add && "$*" =~ flowid\ ([0-9a-f]+:[0-9a-f]+) ]]; then
  echo "filter parent x: u32 chain 0 fh 800::800 flowid ${BASH_REMATCH[1]}" >> "$root_file.filters"; exit 0
fi
if [[ $1 == filter && $2 == show ]]; then
  [[ -f $root_file.filters ]] && cat "$root_file.filters"
  exit 0
fi
exit 0
