#!/usr/bin/env bash
#
# 在统一的 Docker 环境里编译固件。本地和 GitHub Actions 都用这个入口，
# 保证两边环境一致。
#
# 用法：
#   ./scripts/docker-build.sh              # 完整编译
#   ./scripts/docker-build.sh shell        # 进容器交互调试
#   ./scripts/docker-build.sh clean        # 删掉源码树（含命名卷）重新开始
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME_DIR="${ROOT_DIR}/.dockerhome"

# 默认用宿主原生架构编译。OpenWrt 从源码自建工具链，宿主是 aarch64 时
# 它会编 aarch64→aarch64 的交叉链，不需要任何 x86 预编译产物，
# 所以 Apple Silicon 上直接跑 arm64 容器即可，不必走 Rosetta 转译。
# 需要强制某个架构时用 BUILD_PLATFORM=linux/amd64 覆盖。
case "$(uname -m)" in
	x86_64|amd64)  NATIVE_PLATFORM="linux/amd64" ;;
	arm64|aarch64) NATIVE_PLATFORM="linux/arm64" ;;
	*)             NATIVE_PLATFORM="linux/amd64" ;;
esac
PLATFORM="${BUILD_PLATFORM:-$NATIVE_PLATFORM}"
PLATFORM_ARCH="${PLATFORM##*/}"

# 工具链与 staging_dir 里的宿主二进制是按架构编的，两种架构不能共用一棵源码树
IMAGE_TAG="redmi-ax6-openwrt-builder:${PLATFORM_ARCH}"
VOLUME_NAME="redmi-ax6-openwrt-src-${PLATFORM_ARCH}"

log()  { printf '\n\033[32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m提示:\033[0m %s\n' "$*"; }
die()  { printf '\033[31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || die "未找到 docker"
docker info >/dev/null 2>&1 || die "docker 守护进程未运行"

# ---------------------------------------------------------------
# 宿主文件系统大小写敏感性探测
#
# Linux 内核源码里存在只差大小写的同名文件，最典型的是
#   net/netfilter/xt_DSCP.c  （DSCP target 模块）
#   net/netfilter/xt_dscp.c  （DSCP match  模块）
# 在大小写不敏感的文件系统（macOS APFS 默认、Windows）上解压内核源码，
# 两者会碰撞合并成一个，随后 NSS 的
#   0600-6-qca-nss-ecm-support-netfilter-DSCPREMARK.patch
# 会因为找不到预期内容而失败，编译在 target/linux 阶段直接中止。
#
# 因此：宿主大小写不敏感时，把源码树放进 Docker 命名卷（卷在 Linux
# 文件系统上，大小写敏感），只有 config/files/scripts/output 走 bind mount。
# 副作用是绕开了 macOS bind mount 的慢 IO，编译还更快。
# ---------------------------------------------------------------
case_insensitive() {
	local probe="${ROOT_DIR}/.case-probe"
	rm -rf "$probe"
	mkdir -p "$probe"
	: > "${probe}/aA"
	local result=1
	if [ -e "${probe}/Aa" ]; then result=0; fi
	rm -rf "$probe"
	return $result
}

if [ "${1:-}" = "clean" ]; then
	log "清理源码树"
	# 两种架构的卷都清掉，免得切换架构后还留着占几十 GB
	for v in "redmi-ax6-openwrt-src-amd64" "redmi-ax6-openwrt-src-arm64" "redmi-ax6-openwrt-src"; do
		docker volume rm "$v" >/dev/null 2>&1 && echo "  已删除命名卷 ${v}" || true
	done
	rm -rf "${ROOT_DIR}/openwrt" "$HOME_DIR"
	echo "  已删除 openwrt/ 与 .dockerhome/"
	exit 0
fi

# 只有被显式要求跑非原生架构时才会走模拟。模拟层下高并行会让不相关的包
# 随机编译失败（实测 lua / libnftnl / dnsmasq），所以那种情况默认降并行度。
EMULATED=0
if [ "$PLATFORM" != "$NATIVE_PLATFORM" ]; then
	EMULATED=1
	warn "指定平台 ${PLATFORM} 与宿主架构不同，将走模拟，编译明显变慢"
	warn "并行度默认降到 ${BUILD_JOBS:-4}（模拟层下高并行会随机失败），可用 BUILD_JOBS 覆盖"
fi

log "构建编译镜像 ${IMAGE_TAG}（平台 ${PLATFORM}）"
docker build --platform "$PLATFORM" -t "$IMAGE_TAG" "${ROOT_DIR}/docker"

mkdir -p "$HOME_DIR"

RUN_ARGS=(
	--rm
	--platform "$PLATFORM"
	-v "${ROOT_DIR}:/build"
	-w /build
	-u "$(id -u):$(id -g)"
	-e "HOME=/build/.dockerhome"
	-e "FORCE_UNSAFE_CONFIGURE=1"
)

if [ "$EMULATED" -eq 1 ]; then
	RUN_ARGS+=(-e "BUILD_JOBS=${BUILD_JOBS:-4}")
elif [ -n "${BUILD_JOBS:-}" ]; then
	RUN_ARGS+=(-e "BUILD_JOBS=${BUILD_JOBS}")
fi

if case_insensitive; then
	warn "宿主文件系统大小写不敏感，源码树改用 Docker 命名卷 ${VOLUME_NAME}"
	warn "（内核源码含 xt_DSCP.c / xt_dscp.c 这类同名文件，直接挂宿主目录会碰撞）"
	warn "源码不在 ${ROOT_DIR}/openwrt，要清空请跑 ./scripts/docker-build.sh clean"
	# 宿主上那个目录只是挂载点，留着会误导
	rm -rf "${ROOT_DIR}/openwrt"
	RUN_ARGS+=(-v "${VOLUME_NAME}:/build/openwrt")
fi

if [ "${1:-}" = "shell" ]; then
	log "进入容器（源码在 /build/openwrt）"
	exec docker run -it "${RUN_ARGS[@]}" "$IMAGE_TAG" bash
fi

log "开始编译"
exec docker run "${RUN_ARGS[@]}" "$IMAGE_TAG" ./scripts/build.sh "$@"
