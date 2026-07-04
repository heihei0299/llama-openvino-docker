#!/bin/bash
# install-gpu-drivers.sh
#
# 从 Intel GitHub Releases 下载并安装 GPU 驱动
# 用法: install-gpu-drivers.sh <IGC_VER> <IGC_FULL> <CR_VER> <CR_FULL> <IGDGMM_VER>

set -eux

IGC_VER=$1
IGC_FULL=$2
CR_VER=$3
CR_FULL=$4
IGDGMM_VER=$5

TMPDIR="$(mktemp -d)"
cd "$TMPDIR"

for url in \
    "https://github.com/intel/intel-graphics-compiler/releases/download/${IGC_VER}/intel-igc-core-${IGC_FULL}_amd64.deb" \
    "https://github.com/intel/intel-graphics-compiler/releases/download/${IGC_VER}/intel-igc-opencl-${IGC_FULL}_amd64.deb" \
    "https://github.com/intel/compute-runtime/releases/download/${CR_VER}/intel-ocloc_${CR_FULL}_amd64.deb" \
    "https://github.com/intel/compute-runtime/releases/download/${CR_VER}/intel-opencl-icd_${CR_FULL}_amd64.deb" \
    "https://github.com/intel/compute-runtime/releases/download/${CR_VER}/libigdgmm12_${IGDGMM_VER}_amd64.deb" \
    "https://github.com/intel/compute-runtime/releases/download/${CR_VER}/libze-intel-gpu1_${CR_FULL}_amd64.deb"
do
    f="$(basename "$url")"
    wget -q -O "$f" "$url"
done

apt-get update
apt-get install -y --no-install-recommends ./*.deb
rm -rf /var/lib/apt/lists/* "$TMPDIR"
