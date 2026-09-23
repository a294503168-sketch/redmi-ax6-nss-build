#!/usr/bin/env bash
#
# 把无线相关包从 qualcommax target 的 DEFAULT_PACKAGES / DEVICE_PACKAGES 里摘掉。
#
# 为什么不能只靠 .config：DEFAULT_PACKAGES 和 DEVICE_PACKAGES 是 Makefile 变量，
# 会被直接拼进镜像的安装列表，光在 .config 里写 "is not set" 不保险。
#
# 用法： strip-wifi.sh <openwrt 源码目录>
#
set -euo pipefail

SRC_DIR="${1:?用法: strip-wifi.sh <openwrt 源码目录>}"

log() { printf '\033[32m    -\033[0m %s\n' "$*"; }
die() { printf '\033[31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

# 从 Makefile 变量里删掉一个包名。找不到就报错退出——
# 上游改了结构却静默跳过，会导致无线包偷偷回到固件里。
drop_pkg() {
	local file="$1" pkg="$2"
	[ -f "$file" ] || die "找不到文件 ${file}"
	grep -qE "(^|[[:space:]])${pkg}([[:space:]]|\\\\|$)" "$file" \
		|| die "在 ${file##*/} 里找不到 ${pkg}，上游结构可能已变更，请检查 ${REPO_BRANCH:-分支} 后更新本脚本"
	sed -i -E "s/(^|[[:space:]])${pkg}([[:space:]]|$)/\1/g" "$file"
	log "已从 ${file##*/} 移除 ${pkg}"
}

MAKEFILE="${SRC_DIR}/target/linux/qualcommax/Makefile"
TARGET_MK="${SRC_DIR}/target/linux/qualcommax/ipq807x/target.mk"
IMAGE_MK="${SRC_DIR}/target/linux/qualcommax/image/ipq807x.mk"

# qualcommax 通用默认包：ath11k 驱动 + wpad
drop_pkg "$MAKEFILE" "kmod-ath11k-ahb"
drop_pkg "$MAKEFILE" "wpad-basic-mbedtls"

# ipq807x 子平台默认包：ath11k 固件
drop_pkg "$TARGET_MK" "ath11k-firmware-ipq8074"

# redmi_ax6 设备包：板级射频校准数据
#
# 注意：这里必须"置空"而不是"删行"。Device/redmi_ax6 开头有
# $(call Device/xiaomi_ax3600)，而 xiaomi_ax3600 自己设了
#   DEVICE_PACKAGES := ipq-wifi-xiaomi_ax3600 kmod-ath10k-smallbuffers ath10k-firmware-qca9887
# 直接删掉 redmi_ax6 的赋值行，继承来的那串 ath10k 反而会留下来。
[ -f "$IMAGE_MK" ] || die "找不到 ${IMAGE_MK}"
grep -q 'ipq-wifi-redmi_ax6' "$IMAGE_MK" \
	|| die "在 ipq807x.mk 里找不到 ipq-wifi-redmi_ax6，上游结构可能已变更"
sed -i '/^define Device\/redmi_ax6$/,/^endef$/{s/^\([[:space:]]*\)DEVICE_PACKAGES[[:space:]]*:=.*$/\1DEVICE_PACKAGES :=/}' "$IMAGE_MK"

DEV_PKGS="$(sed -n '/^define Device\/redmi_ax6$/,/^endef$/p' "$IMAGE_MK" | grep 'DEVICE_PACKAGES' || true)"
[ -n "$DEV_PKGS" ] || die "Device/redmi_ax6 里没有 DEVICE_PACKAGES 赋值，无法覆盖 xiaomi_ax3600 继承来的无线包"
if echo "$DEV_PKGS" | grep -qE 'ath|wifi'; then
	die "Device/redmi_ax6 的 DEVICE_PACKAGES 仍含无线包: ${DEV_PKGS}"
fi
log "已把 Device/redmi_ax6 的 DEVICE_PACKAGES 置空（覆盖 xiaomi_ax3600 继承的 ath10k）"

echo "无线包剔除完成"
