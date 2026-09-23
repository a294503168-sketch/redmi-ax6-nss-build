# Redmi AX6 OpenWrt 固件（NSS 硬件加速 · 保留 WiFi · 中文）

为 Redmi AX6（`qualcommax/ipq807x`，`redmi_ax6`）编译带 **NSS 硬件卸载**的 OpenWrt 固件。
目标是千兆 PPPoE 拨号跑满线速，同时保留板载无线与常用插件。

## 为什么不用官方 OpenWrt

官方 OpenWrt 不含高通 NSS（Network Subsystem）支持，ipq807x 的转发全靠 4 核 A53 软件跑，
CPU 会成为千兆 PPPoE 的瓶颈。本固件启用 NSS 后把转发交给 SoC 内的两个 NPU 核处理。

源码用 [`qosmio/openwrt-ipq`](https://github.com/qosmio/openwrt-ipq) 的 **`24.10-nss`** 分支：

- 内核 `6.6`，与官方 `openwrt-24.10` 同期
- feeds 钉在 `openwrt-24.10` 发布分支，不跟 `main`
- `target/linux/qualcommax/ipq807x/target.mk` 里 `kmod-qca-nss-drv`、`kmod-qca-nss-ecm` 已是默认包
- 包管理器是 **opkg**（25.12 起才换成 apk，两者的 feeds / uci-defaults 写法不通用）

需要跟到 `25.12-nss`（内核 6.12）时，改 `config/ax6.conf` 的 `REPO_BRANCH` 即可，
但要额外注意 apk 与 opkg 的差异（`files/etc/uci-defaults/99-ax6-custom` 已经两个路径都处理了）。

## 特性

| 分类 | 内容 |
| --- | --- |
| NSS 卸载 | `kmod-qca-nss-drv` / `kmod-qca-nss-ecm` / `kmod-qca-nss-drv-pppoe` / `bridge-mgr` / `vlan-mgr` |
| NSS WiFi 卸载 | `CONFIG_ATH11K_NSS_SUPPORT` / `ATH11K_NSS_MESH_SUPPORT` / `MAC80211_NSS_SUPPORT` / `kmod-qca-nss-drv-wifi-meshmgr` / `kmod-qca-mcs` |
| 无线 | ath11k（IPQ8074）+ `ath11k-firmware-ipq8074` + 板级校准 `ipq-wifi-redmi_ax6` |
| 漫游 / Mesh | `wpad-mesh-openssl`（含 802.11k/v/r 与 Mesh，替换默认的 `wpad-basic-mbedtls`） |
| 科学上网 | `luci-app-openclash`（第三方 feed `vernesong/OpenClash`） |
| DNS 过滤 | `adguardhome`（官方 packages feed，自带 Web 管理界面） |
| 异地组网 | `tailscale` / `zerotier` |
| 基础 | `dnsmasq-full`（OpenClash 的 ipset/nftset 依赖）/ `kmod-tun` / `luci-compat` |
| 工具 | `btop` / `htop` / `iperf3` / `ttyd` + `luci-app-ttyd` / `zsh` / `curl` / `nano` |
| USB | `kmod-usb-storage` / `kmod-usb-storage-uas` / `kmod-fs-ext4` / `kmod-fs-vfat` / `block-mount` |
| 中文化 | 首选启动脚本设 `zh_cn` + `Asia/Shanghai` |
| 首次启动 | 关 `packet_steering` 与 `flow_offloading`（与 NSS 冲突）、注释掉不存在的 feed 源、zsh 设为 root shell |

## 项目结构

```
config/
  ax6.conf          源码仓库、分支、目标设备
  ax6.seed          .config 种子（差异项，由 make defconfig 展开）
docker/
  Dockerfile        统一编译环境，本地与 CI 共用
files/              直接打包进固件的 rootfs 文件
  etc/uci-defaults/99-ax6-custom   首次启动：中文化、关 NSS 冲突项、切 zsh
  usr/libexec/rpcd/luci.sysperf    首页性能面板的后端（ubus 对象 luci.sysperf）
  usr/share/rpcd/acl.d/luci-sysperf.json          上述对象的读权限
  www/luci-static/resources/view/status/include/21_sysperf.js   首页面板前端
patches/            本地补丁覆盖层，按相对路径覆盖上游源码树里的同名文件
  target/linux/qualcommax/patches-6.6/0600-4-...patch   NSS ECM bonding 补丁的上下文修正版
scripts/
  docker-build.sh   入口：起容器并调用 build.sh
  build.sh          真正的编译流程（容器内执行）
  strip-wifi.sh     已弃用（本版本保留无线，build.sh 改为反向校验）
.github/workflows/
  build.yml         GitHub Actions，调用的是同一个 docker-build.sh
```

## 编译

### GitHub Actions（本机不需要 Linux）

push 到 `master`（改动 `config/` `files/` `scripts/` `docker/` `patches/` 或 workflow）会自动编译，
产物直接挂在 Release 上。也支持定时（上游有新提交才编）与手动触发。

工作流分 `check` 和 `build` 两个 job。`check` 用 `git ls-remote` 取上游分支 HEAD，
再查本仓库有没有 `nss-<上游短 sha>` 这个 tag —— 有就说明这个版本编过，跳过。
tag 本身就是状态，不需要往仓库里写"上次编到哪"的文件。

### 本地编译

只需要 Docker：

```bash
./scripts/docker-build.sh
```

产物输出到 `output/`。需要约 40GB 空闲磁盘（源码树 + 产物）。

调试用交互 shell、清空重来：

```bash
./scripts/docker-build.sh shell
./scripts/docker-build.sh clean
```

Windows / macOS 上源码树会自动放进 Docker 命名卷：内核源码里有
`xt_DSCP.c` 与 `xt_dscp.c` 这类只差大小写的同名文件，在大小写不敏感的文件系统上会碰撞，
导致 NSS 的 DSCPREMARK 补丁失败。

## 编译期校验

`scripts/build.sh` 在 `make defconfig` 之后逐项校验，任一不满足直接中止，不会白编一场：

1. 目标设备已选中
2. NSS 卸载链完整（`drv` / `ecm` / `pppoe` / `bridge-mgr` / `vlan-mgr`）
3. **无线包齐全**（`kmod-ath11k-ahb` / `kmod-ath11k` / `ath11k-firmware-ipq8074` / `ipq-wifi-redmi_ax6` / `kmod-mac80211` / `kmod-cfg80211` / `wpad-mesh-openssl`）
4. NSS WiFi 卸载开关生效（`CONFIG_ATH11K_NSS_SUPPORT` / `CONFIG_PACKAGE_MAC80211_NSS_SUPPORT`）
5. 中文：`CONFIG_LUCI_LANG_zh_Hans=y` 且实际展开出了 `luci-i18n-*-zh-cn` 包
6. 功能包在（`luci-app-openclash` / `adguardhome` / `tailscale` / `zerotier` / `dnsmasq-full` / `kmod-tun`），且默认 `dnsmasq` 确实被顶掉

第 5 条踩过坑：`luci-i18n-*` 在 `luci.mk` 里是 `HIDDEN:=1`、由 `DEFAULT:=LUCI_LANG_$(lang)` 间接打开，
直接在 seed 里写 `CONFIG_PACKAGE_luci-i18n-xxx-zh-cn=y` 会被 `make defconfig` **静默丢弃**，
固件编出来一个中文都没有还不报错。

编译结束后脚本还会读 `*.manifest` 核对关键组件是否真的进了固件（编译成功 ≠ 包被编进去）。

## 产物

| 文件 | 用途 |
| --- | --- |
| `*-squashfs-factory.ubi` | 首次从原厂 / 第三方固件刷入 |
| `*-squashfs-sysupgrade.bin` | 已运行 OpenWrt 时升级 |
| `*-initramfs-*.itb` / `.ubi` | 内存启动，用于救砖调试 |
| `*.manifest` | 固化清单，核对包是否真的编进去 |
| `config.buildinfo` | 最终 `.config`，核对开关是否生效 |

## 刷机

### 从 ImmortalWrt / 官方 OpenWrt 切过来

**必须不保留配置。** 上游明确警告：`packet_steering` 与 `flow_offloading` 会在 sysupgrade 时
从旧固件带过来，与 NSS 的 NPU 数据面冲突，表现为丢包或吞吐上不去。首次启动脚本会主动把它们置 0，
但仍建议干净刷：

```sh
# 固件放到 /tmp 后
sysupgrade -n /tmp/openwrt-*-redmi_ax6-squashfs-sysupgrade.bin
```

### 从原厂固件第一次刷

用 `*-squashfs-factory.ubi`，经已解锁的 U-Boot 写入。刷完后如果无线 / 有线异常，
先用 `*-initramfs-*.itb` 内存启动确认固件本身没问题，再写回 NAND。

### 空间

AX6 的 NAND 是 128MB，`ipq8071-ax6.dts` 里 `rootfs`（ubi）分区约 **82MiB**（`0x2dc0000` 起）。
本固件含无线固件 + AdGuardHome + Tailscale 这些体积较大的组件，squashfs 压缩后仍会占掉相当一部分，
**留给 overlay 的可写空间会明显小于纯路由固件**。刷机后在设备上确认：

```sh
df -h /overlay          # 可写空间
ubinfo -a | head -20     # ubi 卷与可用空间
```

overlay 紧张时的选择（任选）：

- 把 AdGuardHome / Tailscale 从 seed 里去掉，刷完用 `opkg install` 装到外接 USB 盘上
- 外接 USB 盘做 extroot，把 overlay 整体挪到 U 盘
- 用第三方 U-Boot 的大分区布局重新分区（本项目默认走官方 DTS 分区定义）

## 刷完后的首次配置

固件只装插件、不替用户接管 DNS 与代理配置 —— `dnsmasq` / `AdGuardHome` / `Clash` 三者都想拿 53 端口，
自动生成配置极易把 DNS 链配错导致整网断网。建议顺序：

1. 设 root 密码，配好 LAN/WAN 与 PPPoE 拨号，确认能上网
2. 配 WiFi（两根天线频段在 LuCI → 网络 → 无线，默认 SSID 未设、无线处于关闭状态）
3. 开 AdGuard Home（LuCI 里对应的服务页，或在设备上 `service adguardhome enable && service adguardhome start`，
   然后访问 `http://192.168.1.1:3000` 走它的初始化向导）
4. 最后接 OpenClash：在 LuCI → 服务 → OpenClash 里上传 / 订阅配置，并把 dnsmasq 的 DNS 指向 Clash 的监听端口
   （或改用 fake-ip 模式让 Clash 接管 53）

Tailscale / ZeroTier 直接用命令行接入：

```sh
tailscale up        # 或 tailscale up --advertise-routes=192.168.1.0/24
zerotier-cli join <network_id>
```

## 验证 NSS 真的在工作

```sh
cat /sys/kernel/debug/ecm/ecm_nss_ipv4/accelerated_count   # 应远大于 0
cat /sys/kernel/debug/ecm/front_end_ipv4_stop              # 应为 0
dmesg | grep -i "NSS core"                                  # 两个核都应 booted successfully
uci get network.globals.packet_steering                     # 应为 0
nft list ruleset | grep -c flowtable                        # 应为 0
cat /sys/kernel/debug/qca-nss-drv/stats/cpu_load_ubi        # NSS 核负载
```

## 已知约束

- **Bridge VLAN filtering 与 NSS 不兼容**：配置里不要出现 `config bridge-vlan` 或
  `list ports 'lan1:u*'` 这类 DSA 端口打标语法
- **不要从软件源安装内核模块**：feed 里的 kmod 与本固件的 vermagic 不匹配，
  需要什么内核模块要加进 `config/ax6.seed` 重新编译
- **AP VLAN 在 ath11k 下不正常**（上游已知问题），无线侧不要做 VLAN 打标
- `nss_packages` / `sqm_scripts_nss` 是 qosmio 自己的 feed，官方服务器上没有，
  首次启动脚本会把这两行源注释掉

## 排障

**不要在编译中途 `docker kill`。** 强杀会留下半成品的库，后续构建不会自动修复，
典型症状是不相关的包接连链接失败。恢复办法是把受影响的包清掉重编：

```bash
./scripts/docker-build.sh shell
make package/libs/ncurses/clean && make package/libs/ncurses/compile
```

**编译失败会自动降并行度重试**（`-j<nproc>` → 减半 → … → `-j1`，最多 4 轮），
已编好的包有戳不会重来。四轮都失败才会对失败的那个包单独跑 `V=s`。

**`zsh` 的并行编译已被关掉**：它的 Makefile 写了 `PKG_BUILD_PARALLEL:=1`，
但构建系统有竞争，`-j4` / `-j2` 会反复失败。`build.sh` 每轮会把它改成 `0`。

**上游内核补丁与新内核不兼容时，走 `patches/` 覆盖层。** 上游 `24.10-nss` 的
`0600-4-qca-nss-ecm-support-net-bonding-over-LAG-interface.patch` 是按旧 `6.6.x` 写的，
内核升到 `6.6.141` 后 `bond_3ad.c` 的 `ad_enable_collecting_distributing()` 改了形状、
`bond_main.c` 的 `__bond_start_xmit()` switch 重排过，直接打会 `Hunk #3 FAILED` /
`Hunk #13 FAILED`。本仓库 `patches/` 下是上下文修正版，`build.sh` 在 `make` 之前把它
覆盖回源码树（上游 `reset --hard` 每轮都会冲掉，所以每轮重打是必须的）。
**上游若更新了这个补丁，本仓库这份要重新对齐。**

## 默认信息

- 管理地址：`http://192.168.1.1`
- 用户名 `root`，首次登录无密码，请立即设置
- 终端：LuCI → 服务 → 终端（ttyd）
