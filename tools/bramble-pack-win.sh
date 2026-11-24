#!/bin/bash
# Pack a bramble boot image on Windows (Git Bash + Python 3, no Linux tools): ADT -> payload -> shim image
# -> AVB footer. The Windows path of tools/bramble-boot.sh NOBOOT=1.
#
#   bash tools/bramble-pack-win.sh NAME KERNEL [EXTRA BOOT-ARGS...]
#
# Inputs: work/shim-ci/u-probe/kernel (the shim from the `shim` workflow, unpacked), fw-bramble/ (GPU firmware,
# devices/bramble/pull-firmware.sh), research/ipsw-x/d22ap.adt if present (iPhone X /product node; mkadt.py
# warns and leaves /product out without it), downloads/mkbootimg and downloads/avb (AOSP, git clones).
# Output: work/boot/bramble-NAME.img (+ .cmdline). Boot it with: fastboot boot work/boot/bramble-NAME.img
set -euo pipefail
cd "$(dirname "$0")/.."
name=$1 kernel=$2; shift 2
SCRATCH=${MKPAYLOAD_WIN:-$(dirname "$0")/mkpayload-win.py}
P=work/boot
mkdir -p "$P"
[[ -f work/shim-ci/u-probe/kernel ]] || { echo "missing work/shim-ci/u-probe/kernel (download + unpack the shim artifact)"; exit 1; }
for a in "$@"; do
	case $a in sectouch=0) ;; sectouch=*) echo "$a refused (bramble touch is ST FTS: flametouch)" >&2; exit 1 ;; esac
done
base="debug=0xc serial=3 cpus=8 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 ufsrw=1 rootrw=1"
base="$base unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin launchd_unsecure_cache=1"
base="$base wdt=-1 sweetfb_noconsole=1 sweetfb_hz=60 ufslogsecs=2 flamereboot=1800"
base="$base flametouch=1 flametouchdelay=20 sweettouch=0 sweetkeys=1 sweetusb=2 sweetgpu=0 sweetgpufreq=3 sweetgpudelay=0 sweetfb_thread=0 sweetmtl=0 sweetddr=0"
base="$base sweetbattery=1 sectouch=0"
for a in "$@"; do
	k=${a%%=*}
	base=$(printf '%s\n' $base | grep -v -x -e "$k" -e "$k=.*" | tr '\n' ' ')
done
cmdline="${base% }${*:+ $*}"
echo "$cmdline" > "$P/$name.cmdline"
python -I tools/mkadt.py "$P/bramble-hi.adt" --highmem
python -I "$SCRATCH" tools "$kernel" "$P/bramble-hi.adt" "$P/$name.payload" --cmdline "$cmdline" --gpufw fw-bramble >/dev/null
PYTHONPATH=downloads/mkbootimg python downloads/mkbootimg/mkbootimg.py --header_version 3 \
	--kernel work/shim-ci/u-probe/kernel --ramdisk "$P/$name.payload" \
	--os_version 14.0.0 --os_patch_level 2023-11 --cmdline "console=null" -o "$P/bramble-$name.img"
# Windows has no /dev/urandom for avbtool's salt: pass one
python -I downloads/avb/avbtool.py add_hash_footer --image "$P/bramble-$name.img" \
	--partition_size 100663296 --partition_name boot --salt "$(python -c 'import secrets;print(secrets.token_hex(32))')"
ls -l "$P/bramble-$name.img"
echo "boot it (RAM only): fastboot boot $P/bramble-$name.img"
