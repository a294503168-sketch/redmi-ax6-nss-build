# OpenWrt 源码编译环境
# 本地和 GitHub Actions 用同一个镜像，消除环境差异。
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential clang flex bison g++ gawk \
      gettext git \
      libncurses-dev libssl-dev python3 python3-dev python3-setuptools \
      python3-pyelftools rsync swig unzip zlib1g-dev file wget curl \
      llvm libelf-dev device-tree-compiler libgmp3-dev libmpc-dev \
      ccache perl ca-certificates xz-utils zstd time \
 && if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
      apt-get install -y --no-install-recommends gcc-multilib g++-multilib; \
    fi \
 && rm -rf /var/lib/apt/lists/*

# OpenWrt 拒绝以 root 编译，容器由 docker-build.sh 用宿主 UID 启动，
# 这里不预建用户，避免 UID 冲突。
#
# 预建 /build/openwrt 并放开权限：宿主文件系统大小写不敏感时（macOS APFS），
# docker-build.sh 会把命名卷挂到这个路径上。新建命名卷会继承镜像里该目录的
# 属主与权限，不放开的话以非 root 身份跑就写不进去。
RUN mkdir -p /build/openwrt && chmod 777 /build/openwrt

WORKDIR /build
