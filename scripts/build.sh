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
	# reset 会同时撤销上一轮 strip-wifi.sh 的改动，下面会重新打
	git -C "$SRC_DIR" reset --hard FETCH_HEAD
fi
log "源码版本: $(git -C "$SRC_DIR" log -1 --format='%h %s')"

# ---------------------------------------------------------------
# 2. feeds
# ---------------------------------------------------------------
log "更新 feeds（含 qosmio/nss-packages）"
"${SRC_DIR}/scripts/feeds" update -a
"${SRC_DIR}/scripts/feeds" install -a

# ---------------------------------------------------------------
# 3. 剔除无线包
# ---------------------------------------------------------------
log "从 target 定义里剔除无线包"
REPO_BRANCH="$REPO_BRANCH" bash "${ROOT_DIR}/scripts/strip-wifi.sh" "$SRC_DIR"

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
	find "${SRC_DIR}/files/usr/libexec/rpcd" -type f -exec chmod 755 {} + 2>/dev/null || true
fi

# ---------------------------------------------------------------
# 5. 生成 .config
# ---------------------------------------------------------------
log "展开 .config"
cp "$SEED_FILE" "${SRC_DIR}/.config"
make -C "$SRC_DIR" defconfig

# 校验：设备选中、NSS 在、无线不在
grep -q "^CONFIG_TARGET_${TARGET}_${SUBTARGET}_DEVICE_${DEVICE}=y" "${SRC_DIR}/.config" \
	|| die "设备 ${DEVICE} 未被选中，检查 config/ax6.seed"

for pkg in kmod-qca-nss-drv kmod-qca-nss-ecm kmod-qca-nss-drv-pppoe; do
	grep -q "^CONFIG_PACKAGE_${pkg}=[ym]" "${SRC_DIR}/.config" \
		|| die "NSS 包 ${pkg} 未被选中，PPPoE 硬件卸载不会生效"
done

if grep -qE '^CONFIG_PACKAGE_(kmod-ath11k|ath11k-firmware|ipq-wifi|wpad|kmod-mac80211|kmod-cfg80211)[a-z0-9_-]*=[ym]' "${SRC_DIR}/.config"; then
	grep -E '^CONFIG_PACKAGE_(kmod-ath11k|ath11k-firmware|ipq-wifi|wpad|kmod-mac80211|kmod-cfg80211)[a-z0-9_-]*=[ym]' "${SRC_DIR}/.config"
	die "仍有无线包被选中，见上方列表"
fi

# 中文包是 HIDDEN 符号，由 LUCI_LANG_zh_Hans 间接打开，很容易被 defconfig 悄悄丢掉，
# 所以这里同时校验总开关和它实际展开出的语言包。
grep -q '^CONFIG_LUCI_LANG_zh_Hans=y' "${SRC_DIR}/.config" \
	|| die "中文语言总开关 CONFIG_LUCI_LANG_zh_Hans 未生效，界面不会是中文"

I18N_COUNT="$(grep -cE '^CONFIG_PACKAGE_luci-i18n-[a-z0-9-]+-zh-cn=y' "${SRC_DIR}/.config" || true)"
[ "$I18N_COUNT" -gt 0 ] \
	|| die "没有任何 luci-i18n-*-zh-cn 包被选中，界面不会是中文"

log "校验通过：设备已选中、NSS 已启用、无线包为空、中文语言包 ${I18N_COUNT} 个"

# ---------------------------------------------------------------
# 6. 编译
# ---------------------------------------------------------------
log "下载源码包（-j${JOBS}）"
make -C "$SRC_DIR" download -j"$JOBS"

BUILD_LOG="${ROOT_DIR}/build.log"
ATTEMPTS="${BUILD_ATTEMPTS:-4}"

# 失败重试策略
#
# 在 x86_64 模拟环境（Apple Silicon + Rosetta）下，高并行编译会随机让不相关的
# 包失败：lua、libnftnl、dnsmasq 都出现过，而单独重编每个都能通过，且日志里没有
# 任何编译器报错——并行构建会吞掉子进程的报错。
#
# 所以不做"退回 make -j1 V=s 重编整棵包树"（那会把几分钟的诊断拖成几小时），
# 改为失败后并行度减半重试。已编好的包有戳不会重来，每轮都在前进，
# 最后一轮退化成 -j1，也就是最可靠的那种。仍失败才对失败包跑 V=s 打印真实报错。
log "开始编译（-j${JOBS}），首次约 2-3 小时"

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
log "固件内的 NSS 组件"
grep -E 'nss' "$OUTPUT_DIR"/*.manifest 2>/dev/null || echo "  (manifest 里未找到，请检查)"
