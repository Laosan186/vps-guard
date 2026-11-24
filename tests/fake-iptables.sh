#!/usr/bin/env bash
# 测试用的假 iptables / ip6tables（第一个参数是名字）：每条链一个文件，一行一条规则
: "${FAKE_FW_DIR:?}"
name=$1; shift
echo "$name $*" >> "$FAKE_FW_DIR/calls.log"
if [[ -n ${FAKE_IPT_FAIL:-} && "$name $*" == *"$FAKE_IPT_FAIL"* ]]; then
  exit 1
fi
args=()
for a in "$@"; do [[ $a == -w ]] || args+=("$a"); done
set -- "${args[@]}"
op=$1 chain=${2-}
shift 2
f="$FAKE_FW_DIR/$name.$chain"
exists() { [[ $chain == INPUT || -f $f ]]; }
case $op in
  -N) [[ -f $f ]] && exit 1; : > "$f" ;;
  -F) exists || exit 1; : > "$f" ;;
  -X) [[ -f $f ]] || exit 1
      grep -qxF -- "-j $chain" "$FAKE_FW_DIR/$name.INPUT" 2>/dev/null && exit 1    # 还被引用：真 iptables 也会拒绝
      rm -f "$f" ;;
  -A) exists || exit 1; echo "$*" >> "$f" ;;
  -I) exists || exit 1
      [[ ${1-} =~ ^[0-9]+$ ]] && shift
      { echo "$*"; cat "$f" 2>/dev/null; } > "$f.new"; mv -f "$f.new" "$f" ;;
  -C) grep -qxF -- "$*" "$f" 2>/dev/null ;;
  -D) grep -qxF -- "$*" "$f" 2>/dev/null || exit 1
      awk -v r="$*" '!d && $0 == r { d = 1; next } { print }' "$f" > "$f.new"; mv -f "$f.new" "$f" ;;
  -S) exists || exit 1; echo "-N $chain"; sed "s/^/-A $chain /" "$f" 2>/dev/null ;;
  -L) exists || exit 1
      echo "Chain $chain (1 references)"
      echo "    pkts      bytes target     prot opt in     out     source               destination"
      while IFS= read -r r; do echo "  ${FAKE_IPT_HITS:-0}  0 DROP  $r"; done < "$f" ;;
  *)  exit 0 ;;
esac
