#!/usr/bin/env bash
# Runs inside ubuntu:20.04. Mounts: /port (repo, read-only), /build (output).
set -eo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  bc bison build-essential curl flex g++-multilib gcc-multilib \
  git git-lfs gnupg gperf imagemagick lib32ncurses5-dev lib32readline-dev \
  lib32z1-dev liblz4-tool libncurses5 libncurses5-dev libsdl1.2-dev \
  libssl-dev libxml2 libxml2-utils lzop openjdk-8-jdk pngcrush \
  python python3 rsync schedtool squashfs-tools unzip xsltproc zip zlib1g-dev \
  ca-certificates

git lfs install --system
git config --global user.email "blueberry-build@local"
git config --global user.name "Blueberry Builder"

mkdir -p /root/bin /src /build/artifacts
curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o /root/bin/repo
chmod +x /root/bin/repo
export PATH=/root/bin:$PATH

cd /src
repo init -u https://github.com/LineageOS/android.git -b lineage-16.0 --depth=1

mkdir -p .repo/local_manifests
cp /port/blueberry_manifest_lineage16.xml .repo/local_manifests/blueberry.xml

repo sync -c --force-sync --no-clone-bundle --no-tags -j4 --fail-fast

# ---- device / vendor trees ----
rm -rf device/lenovo/blueberry vendor/lenovo/blueberry
mkdir -p device/lenovo vendor/lenovo
cp -a /port/lineage16_seed/device/lenovo/blueberry device/lenovo/
cp -a /port/lineage16_seed/vendor/lenovo/blueberry vendor/lenovo/

# ---- fix: passthrough HALs need an arch attribute ----
BC=device/lenovo/blueberry/BoardConfig.mk
if [ -f "$BC" ] && grep -q '^TARGET_2ND_ARCH' "$BC"; then
  HAL_ARCH="32+64"
elif [ -f "$BC" ] && grep -Eq '^TARGET_ARCH[[:space:]]*:?=[[:space:]]*arm64' "$BC"; then
  HAL_ARCH="64"
else
  HAL_ARCH="32"
fi
echo ">>> Using HAL arch=$HAL_ARCH (derived from BoardConfig.mk; override if wrong)"

for f in $(find device/lenovo/blueberry -name '*manifest*.xml'); do
  if grep -q '<transport>passthrough</transport>' "$f"; then
    sed -i "s|<transport>passthrough</transport>|<transport arch=\"$HAL_ARCH\">passthrough</transport>|g" "$f"
    echo ">>> Patched $f"
    grep -n 'passthrough' "$f"
  fi
done

# ---- environment ----
export ALLOW_MISSING_DEPENDENCIES=true
# envsetup/lunch return non-zero internally, so relax -e around them
set +e
source build/envsetup.sh
lunch lineage_blueberry-userdebug || { echo "lunch failed"; exit 1; }
set -e

PRODUCT_OUT=out/target/product/blueberry

# ---- stage 1: boot image only (fast, this is the flashable boot) ----
mka -j4 bootimage
cp -v "$PRODUCT_OUT/boot.img" /build/artifacts/
echo "boot image built" > /build/artifacts/STATUS.txt

# ---- stage 2: system + vendor (best effort, does not fail the job) ----
set +e
mka -j4 systemimage vendorimage
rc=$?
set -e
echo "system/vendor build exit code: $rc" >> /build/artifacts/STATUS.txt

for f in system.img vendor.img vbmeta.img; do
  [ -f "$PRODUCT_OUT/$f" ] && cp -v "$PRODUCT_OUT/$f" /build/artifacts/ || true
done

ls -lah /build/artifacts
