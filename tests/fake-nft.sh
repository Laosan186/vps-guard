#!/usr/bin/env bash
# 测试用的假 nft：记录每次调用；只模拟本工具那张表（文件存在 = 表存在）
: "${FAKE_FW_DIR:?}"
echo "nft $*" >> "$FAKE_FW_DIR/calls.log"
T="$FAKE_FW_DIR/nft.table"
if [[ -n ${FAKE_NFT_FAIL:-} && "nft $*" == *"$FAKE_NFT_FAIL"* ]]; then
  exit 1
fi
case "$*" in
  "list tables")
    [[ -n ${FAKE_NFT_NOKERNEL:-} ]] && exit 1
    [[ -f $T ]] && echo "table inet vps_traffic_guard"
    exit 0 ;;
  "list table inet vps_traffic_guard")
    [[ -f $T ]] || { echo "Error: No such file or directory" >&2; exit 1; }
    cat "$T"; exit 0 ;;
  "delete table inet vps_traffic_guard")
    [[ -f $T ]] || exit 1
    rm -f "$T"; exit 0 ;;
  "-c -f -")
    cat > "$FAKE_FW_DIR/nft.checked"
    [[ -n ${FAKE_NFT_CHECK_FAIL:-} ]] && exit 1
    exit 0 ;;
  "-f -")
    in=$(cat)
    # 只接受“先建、再删、再建”的原子替换写法
    [[ $in == "table inet vps_traffic_guard"$'\n'"delete table inet vps_traffic_guard"$'\n'* ]] || exit 1
    printf '%s\n' "$in" | sed -n '3,$p' | sed "s/counter drop/counter packets ${FAKE_NFT_HITS:-0} bytes 0 drop/" > "$T"
    exit 0 ;;
esac
exit 0
