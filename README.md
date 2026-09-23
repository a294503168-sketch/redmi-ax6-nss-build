# Redmi AX6 OpenWrt 固件（NSS 硬件加速 · 无 WiFi · 中文）

为 Redmi AX6（`qualcommax/ipq807x`，`redmi_ax6`）编译带 **NSS 硬件卸载**的 OpenWrt 固件。
目标是千兆 PPPoE 拨号跑满线速。

## 为什么不用官方 OpenWrt

官方 OpenWrt 不含高通 NSS（Network Subsystem）支持，ipq807x 的转发全靠 4 核 A53 软件跑，
CPU 会成为千兆 PPPoE 的瓶颈。本固件启用 NSS 后把转发交给 SoC 内的两个 NPU 核处理。

实测（本固件，千兆 PPPoE）：**路由器本机多线程下载 891Mbps**，接近 PPPoE 扣除封装开销后的
理论上限（约 940Mbps）。

本项目改用 [`qosmio/openwrt-ipq`](https://github.com/qosmio/openwrt-ipq) 的 **`25.12-nss`** 分支：

- feeds 全部钉在 `openwrt-25.12` **发布分支**（packages / luci / routing / telephony / video），不跟 `main`
- 内核 `6.12`，与官方 `openwrt-25.12` 分支一致
- `target/linux/qualcommax/ipq807x/target.mk` 里 `kmod-qca-nss-drv`、`kmod-qca-nss-ecm` 已是默认包
- 上游支持矩阵中 IPQ807x 的 **PPPoE 卸载为已支持**

保守备选是 `24.10-nss`（上游 README 标注 stable，内核 6.6），改 `config/ax6.conf` 里的 `REPO_BRANCH` 即可。

### 关于版本号里的 SNAPSHOT

固件里显示的是 `OpenWrt 25.12-SNAPSHOT r0-<commit>`。**这不是 main 主干快照**，
OpenWrt 的版本命名分三层：

| 版本串 | 含义 |
| --- | --- |
| `SNAPSHOT` | `main` 主干，滚动开发 |
| `25.12-SNAPSHOT` | **`openwrt-25.12` 发布分支**，位于两个点版本之间 |
| `25.12.5` | 打了 tag 的点版本 |

任何从发布分支 HEAD 编译（而不是 checkout `v25.12.x` tag）的固件都会是第二种。
依据：官方 `openwrt/openwrt` 的 `openwrt-25.12` 分支，其 `include/version.mk` 里的默认值
逐字就是 `25.12-SNAPSHOT`；`downloads.openwrt.org/releases/25.12-SNAPSHOT/` 也是官方
真实存在的发布分支路径，与主干的 `downloads.openwrt.org/snapshots/` 是两回事。

内核版本也能佐证落在 25.12 发布线上：官方 25.12.3 是 6.12.85，25.12.5 是 6.12.94，
本固件是 **6.12.91**，夹在两者之间。

一个副作用：OpenWrt 会把编译时用到的每个 feed 都写进 `/etc/apk/repositories.d/distfeeds.list`，
其中 `nss_packages` 和 `sqm_scripts_nss` 是 qosmio 自己的 feed，官方服务器上并不存在（404），
会让每次 `apk update` 报 `2 unavailable`。首次启动的 uci-defaults 会把这两行注释掉。

还要注意：那些 feed 里的 kmod 与本固件的 vermagic 不匹配，**不要从软件源安装任何内核模块**，
需要什么内核模块应该加进 `config/ax6.seed` 重新编译。

## 特性

- NSS 卸载：`kmod-qca-nss-drv` / `kmod-qca-nss-ecm` / `kmod-qca-nss-drv-pppoe` / `bridge-mgr` / `vlan-mgr`
- **剔除全部无线内容**：`kmod-ath11k-ahb`、`ath11k-firmware-ipq8074`、`wpad-basic-mbedtls`、`ipq-wifi-redmi_ax6`
- 软件包保持官方默认组合（`luci` 元包），不加装多余插件
- 额外软件包：`btop` `htop` `iperf3` `ttyd` `zsh` `luci-app-ttyd`
- LuCI 与上述插件全部安装中文语言包，首次启动自动设为中文，时区 `Asia/Shanghai`
- 首次启动自动关闭 `packet_steering` 与 `flow_offloading`（与 NSS 冲突）
- `zsh` 设为 root 默认 shell，附带精简 `.zshrc`
- LuCI 首页增加「性能监控」面板：CPU 占用率、NSS 核心占用率、温度，1 秒刷新

## 项目结构

```
config/
  ax6.conf          源码仓库、分支、目标设备
  ax6.seed          .config 种子（差异项，由 make defconfig 展开）
docker/
  Dockerfile        统一编译环境，本地与 CI 共用
files/              直接打包进固件的 rootfs 文件
  etc/uci-defaults/99-ax6-custom   首次启动：中文化、关无线、关软件卸载、切 zsh
  root/.zshrc
  usr/libexec/rpcd/luci.sysperf    首页性能面板的后端（ubus 对象 luci.sysperf）
  usr/share/rpcd/acl.d/luci-sysperf.json          上述对象的读权限
  www/luci-static/resources/view/status/include/21_sysperf.js   首页面板前端
scripts/
  docker-build.sh   入口：起容器并调用 build.sh
  build.sh          真正的编译流程（容器内执行）
  strip-wifi.sh     从 target 定义里摘掉无线包
.github/workflows/
  build.yml         GitHub Actions，调用的是同一个 docker-build.sh
```

## 本地编译

只需要 Docker，不需要在宿主上装任何编译依赖：

```bash
./scripts/docker-build.sh
```

产物输出到 `output/`。CI 跑的是同一条命令、同一个镜像，两边环境一致。

调试用交互 shell（源码在容器内 `/build/openwrt`）：

```bash
./scripts/docker-build.sh shell
```

清空源码树重来：

```bash
./scripts/docker-build.sh clean
```

说明：

- 需要约 **40GB** 空闲磁盘
- 编译容器的架构跟随宿主：`x86_64` → `linux/amd64`，`arm64`/`aarch64` → `linux/arm64`。
  OpenWrt 从源码自建工具链，aarch64 宿主直接交叉编译到 `aarch64_cortex-a53`，
  不需要任何 x86 预编译产物，所以 Apple Silicon 上是**原生编译**，不走 Rosetta。
  镜像 tag 和命名卷都带架构后缀，两种架构的源码树可以并存。
- 实测 M4（10 核）原生 arm64 全量编译约 **22 分钟**；同机器强制走 amd64 转译则慢一个数量级，
  且高并行下会随机失败
- 需要强制某个架构时用 `BUILD_PLATFORM=linux/amd64 ./scripts/docker-build.sh`，
  此时才会自动把并行度降到 4（转译层下高并行不稳）

### macOS / Windows：源码树放在 Docker 命名卷里

Linux 内核源码含有只差大小写的同名文件，例如 `net/netfilter/` 下同时有
`xt_DSCP.c`（DSCP target 模块）和 `xt_dscp.c`（DSCP match 模块）。
在大小写不敏感的文件系统（macOS APFS 默认、Windows）上解压内核源码，两者会碰撞合并，
随后 NSS 的 `0600-6-qca-nss-ecm-support-netfilter-DSCPREMARK.patch` 会因内容对不上而失败，
编译在 `target/linux` 阶段中止。

`docker-build.sh` 会自动探测宿主文件系统的大小写敏感性：

- **不敏感** → 源码树放进 Docker 命名卷 `redmi-ax6-openwrt-src-<架构>`（Linux 文件系统），
  只有 `config/` `files/` `scripts/` `output/` 走 bind mount。此时宿主上看不到 `openwrt/` 目录，
  要清空得用 `./scripts/docker-build.sh clean`。顺带绕开了 macOS bind mount 的慢 IO。
- **敏感**（Linux，含 CI） → 维持 bind mount，源码树就在 `openwrt/`

## 首页性能面板

LuCI 首页（状态 → 总览）在「内存」下面多一块「性能监控」，每 **1 秒**刷新：

- **CPU 占用率**：读 `/proc/stat`，后端只回累计 jiffies，占用率由前端两帧求差算。
  逐核数据后端照样送，前端过滤掉了，想看逐核把 `21_sysperf.js` 里 `cpuRows()` 的 filter 去掉即可
- **NSS 核心**：读 `/sys/kernel/debug/qca-nss-drv/stats/cpu_load_ubi` 的 `Avg` 列（驱动统计的 1 秒平均）。
  debugfs 没挂时后端会按需 `mount -t debugfs`
- **NSS 温度 / CPU 温度**：`/sys/class/thermal/thermal_zone*`，按家族归并后取组内平均
  （`nss0` `nss1` `nss-top` 一组，`cpu0-3` `cluster` 一组）。本固件没有无线，
  `wcss-phy*` 那几路传感器直接跳过

实现是三个文件，不额外装任何插件包：后端 rpcd 插件 `luci.sysperf` 暴露一个 `stats` 方法，
配套 ACL 放行读权限，前端是首页 include 目录里的一个 JS（该目录是 LuCI 运行时 `fs.list`
扫描的，放进去就生效）。首页各分区本身是 5 秒轮询，面板另起了自己的 1 秒轮询直接改写表格，
不会连带把整个首页的刷新频率拉高。

同一个文件里的 `Min` / `Max` 两列**没有采用**：真机连采验证过，它们是驱动加载以来的历史
水位，几十秒纹丝不动，挂在实时面板上会像卡住。只有 `Avg` 是活的。

`cpu_load_ubi` 的文本格式在不同驱动版本间不一样，`25.12-nss` 上是核心号与数值分行：

```
Core 0:
Min	Avg	Max
 3%	 3%	 16%
```

解析器写得比较宽松：遇到 `Core <n>` 记下当前核心号，遇到带百分数的行就归给它，
所以把三个数写在同一行的旧格式也认。刷机后如果 NSS 那行显示「不可用」，
先在设备上确认文件本身有没有内容：

```bash
cat /sys/kernel/debug/qca-nss-drv/stats/cpu_load_ubi
ubus call luci.sysperf stats
```

需要注意上游作者的提醒：这个指标只是 UBI32 核心的粗略负载，别当成精确的转发能力水位看。

## 排障

**不要在编译中途 `docker kill`。** 强杀会留下半成品的库，且后续构建不会自动修复。
典型症状是不相关的包接连链接失败（例如 htop 报 `undefined reference to define_key`，
实际是 ncurses 被打断留下了缺符号的 `.so`）。恢复办法是把受影响的包清掉重编：

```bash
./scripts/docker-build.sh shell
make package/libs/ncurses/clean && make package/libs/ncurses/compile
```

**不要在源码树里直接改 `.config` 做实验。** 那会改变内核 prepare 的哈希，
触发在**已打过补丁的旧树**上重跑补丁系列，报错看起来和上面的大小写问题一模一样。
如果已经发生：

```bash
./scripts/docker-build.sh shell
make target/linux/clean
```

**编译失败会自动降并行度重试。** `build.sh` 按 `-j<nproc> → 减半 → … → -j1` 最多试 4 轮，
已编好的包有戳不会重来。四轮都失败才会对失败的那个包单独跑 `V=s` 打印完整报错。
不要退回 `make -j1 V=s` 重编整棵树——那会把几分钟的诊断拖成几小时。

**`zsh` 的并行编译已被关掉。** 它的 Makefile 上游写的是 `PKG_BUILD_PARALLEL:=1`，
但构建系统有竞争，实测在 `-j4` / `-j2` 反复失败。`build.sh` 每轮会把它改成 `0`
（`feeds update` 会冲掉改动，所以每次都要重打）。

## GitHub Actions 编译

三种触发方式：

| 触发 | 行为 |
| --- | --- |
| push 到 `master`（改动 `config/` `files/` `scripts/` `docker/` 或 workflow） | 一定编译 |
| 每天 04:00（北京时间）定时 | **只在上游源码树有新提交时**才编译 |
| 手动运行 | 一定编译；可临时指定源码分支（如 `24.10-nss`），也可勾选「上游没更新也强制编译」 |

工作流分成 `check` 和 `build` 两个 job。`check` 用 `git ls-remote` 取上游分支 HEAD，
再查本仓库有没有 `nss-<上游短 sha>` 这个 tag —— **有就说明这个版本编过，跳过**。

这样做的好处是不需要往仓库里写"上次编到哪个 commit"的状态文件：那种做法要让 CI 回推提交，
既产生噪音提交，又容易触发 push 事件形成回环。tag 本身就是状态。

Release 的 tag 因此是 `nss-<上游短 sha>`，配合 `allowUpdates` —— 本仓库改了配置重新编译时，
上游 commit 没变就覆盖同一个 Release，而不是堆一堆只差本地配置的版本。

Runner 用 `easimon/maximize-build-space` 扩容，作业超时 350 分钟，并发组限制同一分支只跑一份，
避免定时任务和 push 撞车。

## 产物

| 文件 | 用途 |
| --- | --- |
| `*-squashfs-factory.ubi` | 首次从原厂固件刷入 |
| `*-squashfs-sysupgrade.bin` | 已运行 OpenWrt 时升级 |
| `*-initramfs-*.itb` / `.ubi` | 内存启动，用于救砖调试 |

## 刷机注意

**从非 NSS 固件切过来必须不保留配置。** 上游 README 明确警告：`packet_steering` 和
`flow_offloading` 会在 sysupgrade 时从旧固件带过来，与 NSS 的 NPU 数据面冲突，
表现为丢包或吞吐上不去。本固件的 uci-defaults 会主动把它们置 0，但仍建议干净刷机。

另外 **Bridge VLAN filtering 与 NSS 不兼容**，配置里不要出现 `config bridge-vlan`
或 `list ports 'lan1:u*'` 这类 DSA 端口打标语法。

## 怎么正确测速

**别用无线客户端测。** 本固件没有无线，如果客户端是通过另一个 AP / Mesh 接进来的，
测到的是那段无线链路的上限，跟路由器无关——这个坑实际踩过：无线客户端测出 300Mbps，
同一时刻路由器本机跑到 891Mbps。

按可信度排序：

```sh
# 1. 路由器本机多线程下载（最干净，不受客户端影响；注意这条路径不走 NSS 卸载，是下限）
ssh root@192.168.1.1
U="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/24.04/ubuntu-24.04.4-desktop-amd64.iso"
R1=$(cat /sys/class/net/pppoe-wan/statistics/rx_bytes)
for i in 1 2 3 4 5 6; do (wget -q -O /dev/null "$U" &); done
sleep 12; killall wget
R2=$(cat /sys/class/net/pppoe-wan/statistics/rx_bytes)
echo $(( (R2-R1)*8/12/1000000 )) Mbps

# 2. 有线客户端下载，同时在路由器上读 pppoe-wan 计数（测的是走 NSS 的转发路径）
```

确认 NSS 真的在卸载，看加速连接数（应远大于 0）：

```sh
cat /sys/kernel/debug/ecm/ecm_nss_ipv4/accelerated_count
cat /sys/kernel/debug/ecm/front_end_ipv4_stop        # 应为 0
dmesg | grep -i "NSS core"                            # 两个核都应 booted successfully
uci get network.globals.packet_steering               # 应为 0
nft list ruleset | grep -c flowtable                  # 应为 0
```

## 修改配置

- 换源码分支：改 `config/ax6.conf` 的 `REPO_BRANCH`
- 增删软件包：改 `config/ax6.seed`，写 `CONFIG_PACKAGE_xxx=y` 或 `# CONFIG_PACKAGE_xxx is not set`
- 增加开机默认设置：往 `files/etc/uci-defaults/` 里加脚本，或直接在 `files/` 下按绝对路径放文件

`build.sh` 在 `make defconfig` 之后会校验四件事，任一不满足直接中止，不会白编一场：

1. 目标设备已选中
2. `kmod-qca-nss-drv` / `kmod-qca-nss-ecm` / `kmod-qca-nss-drv-pppoe` 都在
3. 无线包为空
4. `CONFIG_LUCI_LANG_zh_Hans=y` 且实际展开出了 `luci-i18n-*-zh-cn` 包

第 4 条是踩过坑加的：`luci-i18n-*` 在 `luci.mk` 里是 `HIDDEN:=1`、由
`DEFAULT:=LUCI_LANG_$(lang)` 间接打开，直接在 seed 里写 `CONFIG_PACKAGE_luci-i18n-xxx-zh-cn=y`
会被 `make defconfig` **静默丢弃**，固件编出来一个中文都没有还不报错。

## 默认信息

- 管理地址：`http://192.168.1.1`
- 用户名 `root`，首次登录无密码，请立即设置
- 终端：LuCI → 服务 → 终端（ttyd）
