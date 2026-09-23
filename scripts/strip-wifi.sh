本文件已弃用（保留仅为记录历史）。
# ============================================================
# 旧版用途：把 ath11k / wpad 等无线包从 qualcommax target 的
#           DEFAULT_PACKAGES / DEVICE_PACKAGES 里摘掉，编译"无 WiFi"固件。
#
# 当前版本（NSS + 保留 WiFi）需要无线，scripts/build.sh 不再调用本脚本，
# 并改为反向校验：kmod-ath11k-ahb / kmod-ath11k / ath11k-firmware-ipq8074 /
# ipq-wifi-redmi_ax6 / kmod-mac80211 / kmod-cfg80211 / wpad-mesh-openssl
# 必须全部出现在 .config 里，缺一个就中止编译。
# ============================================================
