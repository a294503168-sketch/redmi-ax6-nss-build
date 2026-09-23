#!/usr/bin/env bash
#
# 从 NSS 源码树编译 Redmi AX6 固件。
#
# 这个脚本假定依赖已就位（Linux + 编译工具链）。正常入口是
# scripts/docker-build.sh，它会在统一的容器里调用本脚本。
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF_FILE="${ROOT_DIR}/config/ax6.conf"
SEED_FILE="${ROOT_DIR}/config/ax6.seed"
FILES_DIR="${ROOT_DIR}/files"
SRC_DIR="${ROOT_DIR}/openwrt"
OUTPUT_DIR="${ROOT_DIR}/output"

log() { printf '\n\033[32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

# OpenWrt 拒绝以 root 编译
[ "$(id -u)" -ne 0 ] || die "不能用 root 编译 OpenWrt，请用 scripts/docker-build.sh"

[ -f "$CONF_FILE" ] || die "找不到 ${CONF_FILE}"
[ -f "$SEED_FILE" ] || die "找不到 ${SEED_FILE}"

# ax6.conf 里也有 BUILD_JOBS，source 会把环境变量覆盖掉，所以先存下来。
# 优先级：环境变量 > 配置文件 > nproc
BUILD_JOBS_ENV="${BUILD_JOBS:-}"

# shellcheck source=/dev/null
source "$CONF_FILE"

REPO_URL="${REPO_URL:?未设置 REPO_URL}"
REPO_BRANCH="${REPO_BRANCH:?未设置 REPO_BRANCH}"
TARGET="${TARGET:?未设置 TARGET}"
SUBTARGET="${SUBTARGET:?未设置 SUBTARGET}"
DEVICE="${DEVICE:?未设置 DEVICE}"
JOBS="${BUILD_JOBS_ENV:-${BUILD_JOBS:-$(nproc)}}"

# 仓库挂进容器后属主 UID 可能对不上 git 的认知
git config --global --add safe.directory '*' 2>/dev/null || true

# ---------------------------------------------------------------
# 1. 拉取 / 更新源码树
# ---------------------------------------------------------------
if [ ! -d "${SRC_DIR}/.git" ]; then
	log "克隆 ${REPO_URL} (${REPO_BRANCH})"
	git clone --depth 1 --single-branch --branch "$REPO_BRANCH" "$REPO_URL" "$SRC_DIR"
else
	log "更新已有源码树到 ${REPO_BRANCH} 最新提交"
	git -C "$SRC_DIR" fetch --depth 1 origin "$REPO_BRANCH"
	git -C "$SRC_DIR" reset --hard FETCH_HEAD
fi
log "源码版本: $(git -C "$SRC_DIR" log -1 --format='%h %s')"

# ---------------------------------------------------------------
# 2. 追加第三方 feed
#
# OpenClash 不在官方 feed 里，从上游仓库拉 luci-app-openclash。
# feeds.conf.default 是源码树里的文件，上面 reset --hard 会把它还原，
# 所以每轮都要重新追加（幂等，重复跑不会写两遍）。
# ---------------------------------------------------------------
FEEDS_CONF="${SRC_DIR}/feeds.conf.default"

add_feed() {
	local name="$1" line="$2"
	if grep -qE "^src-git(-full)?[[:space:]]+${name}([[:space:]]|$)" "$FEEDS_CONF"; then
		log "feed ${name} 已存在，跳过"
	else
		printf '%s\n' "$line" >> "$FEEDS_CONF"
		log "已追加 feed: ${line}"
	fi
}

add_feed openclash "src-git openclash https://github.com/vernesong/OpenClash.git;master"

# ---------------------------------------------------------------
# 3. feeds
# ---------------------------------------------------------------
log "更新 feeds（含 openclash）"
"${SRC_DIR}/scripts/feeds" update -a
"${SRC_DIR}/scripts/feeds" install -a

# 确认 OpenClash 前端真的进了 package 树，否则 defconfig 会静默丢掉它
[ -d "${SRC_DIR}/package/feeds/openclash/luci-app-openclash" ] \
	|| die "luci-app-openclash 未被 feeds 安装，检查 openclash feed 与上游仓库结构"

# ---------------------------------------------------------------
# 3.5 关闭已知有并行竞争的包的并行编译
#
# zsh 的 Makefile 显式设了 PKG_BUILD_PARALLEL:=1，但它的构建系统在高并行下
# 会随机失败（本项目多次构建中它在 -j4 / -j2 反复挂掉，-j1 才过）。
# feeds update 每轮会把改动冲掉，所以每次编译前重新打。
# ---------------------------------------------------------------
ZSH_MK="${SRC_DIR}/feeds/packages/utils/zsh/Makefile"
if [ -f "$ZSH_MK" ] && grep -q '^PKG_BUILD_PARALLEL:=1' "$ZSH_MK"; then
	sed -i 's/^PKG_BUILD_PARALLEL:=1/PKG_BUILD_PARALLEL:=0/' "$ZSH_MK"
	log "已关闭 zsh 的并行编译（其构建系统存在竞争）"
fi

# ---------------------------------------------------------------
# 4. rootfs 覆盖层
# ---------------------------------------------------------------
log "安装自定义文件覆盖层"
rm -rf "${SRC_DIR}/files"
if [ -d "$FILES_DIR" ]; then
	cp -a "$FILES_DIR" "${SRC_DIR}/files"
	find "${SRC_DIR}/files/etc/uci-defaults" -type f -exec chmod 755 {} + 2>/dev/null || true
	find "${SRC_DIR}/files/etc/init.d" -type f -exec chmod 755 {} + 2>/dev/null || true
fi

# ---------------------------------------------------------------
# 5. 生成 .config
# ---------------------------------------------------------------
log "展开 .config"
cp "$SEED_FILE" "${SRC_DIR}/.config"
make -C "$SRC_DIR" defconfig

# ---- 校验 1：设备选中 ----
grep -q "^CONFIG_TARGET_${TARGET}_${SUBTARGET}_DEVICE_${DEVICE}=y" "${SRC_DIR}/.config" \
	|| die "设备 ${DEVICE} 未被选中，检查 config/ax6.seed"
log "校验通过：设备 ${DEVICE} 已选中"

# ---- 校验 2：NSS 卸载链完整 ----
for pkg in kmod-qca-nss-drv kmod-qca-nss-ecm kmod-qca-nss-drv-pppoe \
           kmod-qca-nss-drv-bridge-mgr kmod-qca-nss-drv-vlan-mgr; do
	grep -q "^CONFIG_PACKAGE_${pkg}=[ym]" "${SRC_DIR}/.config" \
		|| die "NSS 包 ${pkg} 未被选中，硬件卸载链不完整"
done
log "校验通过：NSS 驱动 / ECM / PPPoE / bridge / vlan 卸载均在"

# ---- 校验 3：无线必须在（与旧版剔除无线的做法相反）----
for pkg in kmod-ath11k-ahb kmod-ath11k ath11k-firmware-ipq8074 \
           ipq-wifi-redmi_ax6 kmod-mac80211 kmod-cfg80211; do
	grep -q "^CONFIG_PACKAGE_${pkg}=[ym]" "${SRC_DIR}/.config" \
		|| die "无线包 ${pkg} 不在 .config 里，WiFi 将不可用"
done
grep -q "^CONFIG_PACKAGE_wpad-mesh-openssl=[ym]" "${SRC_DIR}/.config" \
	|| die "wpad-mesh-openssl 未被选中，802.11k/v/r 与 Mesh 不可用"
log "校验通过：ath11k 驱动 / 固件 / 板级校准数据 / wpad-mesh 均在"

# ---- 校验 4：NSS WiFi 卸载开关 ----
for sym in CONFIG_ATH11K_NSS_SUPPORT CONFIG_PACKAGE_MAC80211_NSS_SUPPORT; do
	grep -q "^${sym}=y" "${SRC_DIR}/.config" \
		|| die "NSS WiFi 卸载开关 ${sym} 未生效"
done
log "校验通过：NSS WiFi 卸载已启用"

# ---- 校验 5：中文（HIDDEN 符号，容易静默丢失）----
grep -q '^CONFIG_LUCI_LANG_zh_Hans=y' "${SRC_DIR}/.config" \
	|| die "中文语言总开关 CONFIG_LUCI_LANG_zh_Hans 未生效，界面不会是中文"

I18N_COUNT="$(grep -cE '^CONFIG_PACKAGE_luci-i18n-[a-z0-9-]+-zh-cn=y' "${SRC_DIR}/.config" || true)"
[ "$I18N_COUNT" -gt 0 ] \
	|| die "没有任何 luci-i18n-*-zh-cn 包被选中，界面不会是中文"
log "校验通过：中文语言包 ${I18N_COUNT} 个"

# ---- 校验 6：功能包 ----
for pkg in luci-app-openclash adguardhome tailscale zerotier dnsmasq-full kmod-tun; do
	grep -q "^CONFIG_PACKAGE_${pkg}=[ym]" "${SRC_DIR}/.config" \
		|| die "功能包 ${pkg} 未被选中，defconfig 可能丢弃了它（检查包名是否随上游变更）"
done
grep -q '^# CONFIG_PACKAGE_dnsmasq is not set' "${SRC_DIR}/.config" \
	|| die "默认 dnsmasq 没有被 dnsmasq-full 顶掉，OpenClash 的 ipset/nftset 会失效"
log "校验通过：OpenClash / AdGuard Home / Tailscale / ZeroTier / dnsmasq-full 均在"

# ---------------------------------------------------------------
# 5.5 本地补丁覆盖层
#
# 上游 24.10-nss 的 0600-4（NSS ECM bonding over LAG）是按旧 6.6.x 写的，
# 内核升到 6.6.141 后 bond_3ad.c / bond_main.c 的上下文漂移，直接打会
# Hunk #3 FAILED / Hunk #13 FAILED。本仓库 patches/ 下放修正版，按相对路径
# 覆盖回源码树；上游 reset --hard 每轮都会把改动冲掉，所以每轮都必须重打。
# 覆盖发生在 make 之前（内核补丁是在 make 里才应用的）。
# ---------------------------------------------------------------
PATCHES_DIR="${ROOT_DIR}/patches"
if [ -d "$PATCHES_DIR" ]; then
	log "应用本地补丁覆盖层"
	OVERLAY_LIST="$(cd "$PATCHES_DIR" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)"
	while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		[ -f "${SRC_DIR}/${rel}" ] \
			|| die "覆盖层文件 ${rel} 在源码树里不存在，上游可能改名或删除了它"
		cp -f "${PATCHES_DIR}/${rel}" "${SRC_DIR}/${rel}"
		log "  覆盖 ${rel}"
	done <<< "$OVERLAY_LIST"
else
	log "没有 patches/ 覆盖层，跳过"
fi

# ---------------------------------------------------------------
# 6. 编译
# ---------------------------------------------------------------
log "下载源码包（-j${JOBS}）"
make -C "$SRC_DIR" download -j"$JOBS"

BUILD_LOG="${ROOT_DIR}/build.log"
ATTEMPTS="${BUILD_ATTEMPTS:-4}"

# 失败重试策略：失败后并行度减半重试。
# 高并行下部分包会随机失败，已编好的包有戳不会重来，每轮都在前进，
# 最后一轮退化成 -j1，也就是最可靠的那种。仍失败才对失败包跑 V=s 打印真实报错。
log "开始编译（-j${JOBS}），首次约 3-5 小时"

attempt=1
while true; do
	if make -C "$SRC_DIR" -j"$JOBS" 2>&1 | tee "$BUILD_LOG"; then
		break
	fi

	FAILED_PKG="$(grep -oE 'ERROR: [^ ]+ failed to build' "$BUILD_LOG" | head -1 | awk '{print $2}' || true)"

	if [ "$attempt" -ge "$ATTEMPTS" ]; then
		if [ -n "$FAILED_PKG" ]; then
			log "已重试 ${ATTEMPTS} 次仍失败，单独用 V=s 重编 ${FAILED_PKG} 以获取完整报错"
			make -C "$SRC_DIR" "${FAILED_PKG}/compile" V=s -j1 || true
			die "${FAILED_PKG} 编译失败，完整报错见上方"
		fi
		die "编译失败，日志见 ${BUILD_LOG}"
	fi

	JOBS=$(( JOBS > 2 ? JOBS / 2 : 1 ))
	attempt=$(( attempt + 1 ))
	log "第 $(( attempt - 1 )) 次失败${FAILED_PKG:+（${FAILED_PKG}）}，降并行度到 -j${JOBS} 重试（第 ${attempt}/${ATTEMPTS} 次）"
done

# ---------------------------------------------------------------
# 7. 收集产物
# ---------------------------------------------------------------
BIN_DIR="${SRC_DIR}/bin/targets/${TARGET}/${SUBTARGET}"
[ -d "$BIN_DIR" ] || die "找不到产物目录 ${BIN_DIR}"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
find "$BIN_DIR" -maxdepth 1 -type f \
	\( -name "*${DEVICE}*" -o -name '*.manifest' -o -name 'sha256sums' -o -name 'config.buildinfo' \) \
	-exec cp {} "$OUTPUT_DIR/" \;

log "编译完成，产物位于 ${OUTPUT_DIR}"
ls -lh "$OUTPUT_DIR"

echo
log "固化清单核对（关键组件是否真的编进固件）"
MANIFEST="$(find "$OUTPUT_DIR" -maxdepth 1 -name '*.manifest' | head -1)"
if [ -n "$MANIFEST" ]; then
	grep -E 'kmod-qca-nss|kmod-ath11k|ath11k-firmware|ipq-wifi|wpad|kmod-qca-mcs|openclash|adguardhome|tailscale|zerotier' "$MANIFEST" \
		|| echo "  (未匹配到关键组件，请检查)"
else
	echo "  (没找到 manifest，无法核对)"
fi

echo
log "squashfs 镜像大小（AX6 的 ubi 分区约 82MiB，需留出 overlay 空间）"
ls -lh "$BIN_DIR"/*squashfs-sysupgrade.bin 2>/dev/null || true
