#!/bin/bash
# Build the iOS 16.7.16 (iPhone X, 20H392) root image for the Pixel 4a 5G (bramble) port ON A MAC, and
# optionally write it to the phone from the Mac. The macOS version of tools/redfin-mkroot-wsl.sh +
# tools/mkiosroot.sh: same files, same layout, same tweaks; macOS tools instead of apfs-fuse/mkfs.hfsplus.
#
#   bash tools/bramble-mkroot-mac.sh check     tools and free space (changes nothing)
#   bash tools/bramble-mkroot-mac.sh fetch     download the IPSW parts from Apple (~6-7 GB, resumable)
#   bash tools/bramble-mkroot-mac.sh build     make iosroot.img (16 GiB HFS+) + tweaks + d22ap.adt + checksums
#   bash tools/bramble-mkroot-mac.sh install   write iosroot.img to the phone's userdata (phone in TWRP, ERASES it)
#   bash tools/bramble-mkroot-mac.sh verify    compare the phone's userdata with the image, per GiB
#   bash tools/bramble-mkroot-mac.sh all       check + fetch + build
#
# Needs: macOS with python3 (Xcode Command Line Tools: `xcode-select --install`), Homebrew rsync
# (`brew install rsync`: macOS's own openrsync lacks a reliable -H), ~40 GB free. For install/verify:
# adb (`brew install android-platform-tools`) and the phone in TWRP (fastboot boot twrp-3.7.0_11-0-redfin.img;
# on bramble its screen stays on the splash, adb root works).
# Work files: ~/bramble-work (override with BRAMBLE_WORK). Outputs there: iosroot.img (raw, filesystem at
# offset 0), iosroot.gib.sha256, d22ap.adt. Copy d22ap.adt to the PC's research/ipsw-x/ for tools/mkadt.py.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
W=${BRAMBLE_WORK:-$HOME/bramble-work}
DEV=iPhone10,3 BUILD=20H392
PARTS=(087-86698-044.dmg 087-86593-047.dmg 087-86715-047.dmg DeviceTree.d22ap.im4p)
SIZE_G=16
mkdir -p "$W/ipsw"

RSYNC=$(command -v /opt/homebrew/bin/rsync || command -v /usr/local/bin/rsync || true)

check() {
	[[ $(uname) == Darwin ]] || { echo "this script is for macOS"; exit 1; }
	sw_vers
	for t in python3 hdiutil diskutil compression_tool fsck_hfs; do
		printf '  %-16s %s\n' "$t" "$(command -v "$t" || echo MISSING)"
	done
	printf '  %-16s %s\n' rsync "${RSYNC:-MISSING (brew install rsync)}"
	printf '  %-16s %s\n' adb "$(command -v adb || echo 'missing (only for install: brew install android-platform-tools)')"
	echo "== space in $W"; df -h "$W" | tail -1
	echo "  need ~40 GB free (6-7 GB IPSW parts + 16 GiB image + 16 GiB raw copy)"
}

fetch() {
	local url
	url=$(curl -sfL "https://api.ipsw.me/v4/device/$DEV?type=ipsw" |
		python3 -c "import json,sys; print(next(f['url'] for f in json.load(sys.stdin)['firmwares'] if f['buildid']=='$BUILD'))")
	echo "IPSW: $url"
	echo "$url" > "$W/ipsw/URL"
	for p in "${PARTS[@]}"; do
		python3 -I "$REPO/tools/remotezip.py" "$url" "$p" "$W/ipsw"
	done
	ls -l "$W/ipsw"
}

find_part() { find "$W/ipsw" -name "$1" | head -1; }

# Attach an IPSW image read-only, print its mount point. The OS image is UDIF; the cryptexes are raw APFS.
attach() {
	local img=$1 out mp
	out=$(hdiutil attach -readonly -nobrowse -noverify -noautoopen -owners on "$img" 2>/dev/null ||
		hdiutil attach -readonly -nobrowse -noverify -noautoopen -owners on \
			-imagekey diskimage-class=CRawDiskImage "$img")
	mp=$(echo "$out" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)
	[[ -n $mp && -d $mp ]] || { echo "could not mount $img:"; echo "$out"; exit 1; }
	echo "$mp"
}

build() {
	[[ -n $RSYNC ]] || { echo "need Homebrew rsync: brew install rsync"; exit 1; }
	local os sysos appos dmg="$W/iosroot.dmg" raw="$W/iosroot.img"
	os=$(find_part "${PARTS[0]}"); sysos=$(find_part "${PARTS[1]}"); appos=$(find_part "${PARTS[2]}")
	[[ -f $os && -f $sysos && -f $appos ]] || { echo "IPSW parts missing under $W/ipsw: run fetch"; exit 1; }
	[[ ! -e $raw ]] || { echo "$raw exists: move it away to rebuild"; exit 1; }
	rm -f "$dmg"

	local mos msys mapp root dev
	mos=$(attach "$os"); msys=$(attach "$sysos"); mapp=$(attach "$appos")
	echo "mounted: $mos | $msys | $mapp"

	# One case-sensitive journaled HFS+ volume, no partition map (the filesystem starts at byte 0, as
	# mkfs.hfsplus on a plain file does on Linux): rd=ufsroot0 reads userdata as that filesystem.
	hdiutil create -size ${SIZE_G}g -fs "Case-sensitive Journaled HFS+" -volname iOSRoot -layout NONE \
		-type UDIF "$dmg"
	local out; out=$(hdiutil attach -nobrowse -noverify -noautoopen -owners on "$dmg")
	root=$(echo "$out" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)
	dev=$(echo "$out" | awk '/\/Volumes\//{print $1}' | tail -1)
	sudo diskutil enableOwnership "$root"
	echo "image: $dev at $root"

	copy() {
		echo "copying $1 -> ${2#"$root"}"
		sudo mkdir -p "$2"
		# -H hard links, numeric owners; macOS reads the LZBITMAP-compressed APFS files decompressed and
		# rsync writes them uncompressed (no decmpfs on the port); no xattrs, as on Linux (apfs-fuse).
		sudo "$RSYNC" -aH --numeric-ids "$1/" "$2/"
	}
	copy "$mos" "$root"
	copy "$msys" "$root/private/preboot/Cryptexes/OS"
	copy "$mapp" "$root/private/preboot/Cryptexes/App"
	hdiutil detach "$mapp" >/dev/null; hdiutil detach "$msys" >/dev/null; hdiutil detach "$mos" >/dev/null

	# The rest is tools/mkiosroot.sh, unchanged in meaning.
	local dsc=private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
	sudo mkdir -p "$root/System/Library/Caches/com.apple.dyld"
	for f in "$root/$dsc"/*; do sudo ln "$f" "$root/System/Library/Caches/com.apple.dyld/${f##*/}"; done
	for c in OS App; do
		(cd "$root/private/preboot/Cryptexes/$c" && sudo find . ! -type d ! -path './System/Library/Caches/com.apple.dyld/*') |
		while IFS= read -r f; do
			f=${f#./}
			if ! sudo test -e "$root/$f" && ! sudo test -L "$root/$f"; then
				sudo mkdir -p "$root/$(dirname "$f")"
				local src="$root/private/preboot/Cryptexes/$c/$f"
				if sudo test -L "$src"; then sudo cp -P "$src" "$root/$f"; else sudo ln "$src" "$root/$f"; fi
				echo "linked $c:/$f"
			fi
		done
	done
	own() { sudo python3 -c 'import os, sys; u = int(sys.argv[1]); [os.chown(p, u, u) for p in sys.argv[2:]]' "$@"; }
	local db="$root/private/var/db"
	sudo mkdir -p "$db/diagnostics/timesync" "$db/uuidtext"
	sudo chmod 0751 "$db/diagnostics"
	sudo chmod 0755 "$db/uuidtext" "$db/diagnostics/timesync"
	for d in diagnostics uuidtext diagnostics/timesync; do
		sudo touch "$db/$d/.migrated"; sudo chmod 0644 "$db/$d/.migrated"; own 272 "$db/$d" "$db/$d/.migrated"
	done
	sudo mkdir -p "$root/private/var/keybags"; sudo chmod 0700 "$root/private/var/keybags"; own 0 "$root/private/var/keybags"
	printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' |
		sudo tee "$root/private/var/keybags/systembag.kb" >/dev/null
	sudo chmod 0600 "$root/private/var/keybags/systembag.kb"; own 0 "$root/private/var/keybags/systembag.kb"

	echo "== tweaks (tools/sweet-root-tweaks.py)"
	sudo python3 -I "$REPO/tools/sweet-root-tweaks.py" "$root"
	df -h "$root"
	hdiutil detach "$dev"
	echo "== fsck_hfs"
	local fdev; fdev=$(hdiutil attach -nomount -noverify "$dmg" | awk 'NR==1{print $1}')
	sudo fsck_hfs -f -y "$fdev" || true
	sudo fsck_hfs -f -n "$fdev" || echo "warning: fsck_hfs still reports issues; continuing"
	hdiutil detach "$fdev" >/dev/null

	echo "== raw image (filesystem at offset 0)"
	hdiutil convert "$dmg" -format UDTO -o "$W/iosroot.tmp"
	mv "$W/iosroot.tmp.cdr" "$raw"
	rm -f "$dmg"
	python3 - "$raw" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read(1026)
sig = b[1024:1026]
print('HFS+ signature at 1024:', sig, '(want H+ or HX)')
if sig not in (b'H+', b'HX'):
    raise SystemExit('the image does not start with an HFS+ volume header')
PY
	finish
}

finish() {
	local raw="$W/iosroot.img" im4p adt="$W/d22ap.adt"
	echo "== d22ap.adt (iPhone X device tree, /product node for mkadt.py)"
	im4p=$(find_part DeviceTree.d22ap.im4p)
	[[ -n $im4p ]] || { echo "DeviceTree.d22ap.im4p not found: run fetch"; exit 1; }
	python3 - "$im4p" "$adt" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
def tlv(o):
    t = b[o]; l = b[o + 1]; o += 2
    if l & 0x80:
        n = l & 0x7f; l = int.from_bytes(b[o:o + n], 'big'); o += n
    return t, o, l
t, o, l = tlv(0); assert t == 0x30
end = o + l
while o < end:
    t, vo, vl = tlv(o)
    if t == 0x04:
        data = b[vo:vo + vl]
        out = sys.argv[2] + ('.lzfse' if data[:4] == b'bvx2' else '')
        open(out, 'wb').write(data); print(f'{out}: {len(data)} bytes'); break
    o = vo + vl
else:
    raise SystemExit('no payload in IM4P')
PY
	if [[ -f $adt.lzfse ]]; then compression_tool -decode -a lzfse -i "$adt.lzfse" -o "$adt"; rm -f "$adt.lzfse"; fi
	python3 -I "$REPO/tools/adt.py" dump "$adt" 2>/dev/null | grep -q product && echo "d22ap.adt parses, /product present" ||
		echo "warning: d22ap.adt did not parse with tools/adt.py"
	echo "== per-GiB SHA-256"
	python3 - "$raw" "$W/iosroot.gib.sha256" <<'PY'
import hashlib, sys
with open(sys.argv[1], 'rb') as f, open(sys.argv[2], 'w') as o:
    i = 0
    while True:
        h = hashlib.sha256(); n = 0
        while n < 1 << 30:
            c = f.read(1 << 22)
            if not c: break
            h.update(c); n += len(c)
        if not n: break
        o.write(f'{i} {h.hexdigest()}\n'); i += 1
print(f'{sys.argv[2]}: {i} GiB')
PY
	ls -l "$raw" "$W/iosroot.gib.sha256" "$adt"
	echo "build: done. Next: phone in TWRP on this Mac, then: bash tools/bramble-mkroot-mac.sh install"
}

phone_userdata() {
	command -v adb >/dev/null || { echo "need adb: brew install android-platform-tools"; exit 1; }
	[[ $(adb get-state 2>/dev/null) == recovery ]] || { echo "phone is not in TWRP (adb state: $(adb get-state 2>&1))"; exit 1; }
	[[ $(adb shell getprop ro.boot.hardware.platform 2>/dev/null | tr -d '\r') == sm7250 ]] || { echo "not an SM7250 phone"; exit 1; }
	adb shell readlink -f /dev/block/by-name/userdata | tr -d '\r'
}

install() {
	local raw="$W/iosroot.img" part size psize
	[[ -f $raw && -f $W/iosroot.gib.sha256 ]] || { echo "need $raw and its checksums: run build"; exit 1; }
	part=$(phone_userdata)
	size=$(stat -f %z "$raw")
	psize=$(adb shell blockdev --getsize64 "$part" | tr -d '\r')
	echo "phone userdata: $part, $psize bytes; image: $size bytes"
	(( psize >= size )) || { echo "userdata is smaller than the image"; exit 1; }
	echo "THIS ERASES ANDROID'S USER DATA on the phone (Android itself is not touched)."
	read -r -p "Type ERASE to write the iOS root to $part: " ok
	[[ $ok == ERASE ]] || { echo "not written"; exit 1; }
	# HANDOFF.md: write from TWRP with dd, never `fastboot flash userdata` (ABL hangs on the last chunk)
	adb exec-in "dd of=$part bs=4194304" < "$raw"
	adb shell sync
	verify
}

verify() {
	local part i want got bad=0
	part=$(phone_userdata)
	while read -r i want; do
		got=$(adb shell "dd if=$part bs=4194304 skip=$((i * 256)) count=256 2>/dev/null | sha256sum" </dev/null | awk '{print $1}')
		if [[ $got == "$want" ]]; then echo "GiB $i ok"; else echo "GiB $i DIFFERS"; bad=1; fi
	done < "$W/iosroot.gib.sha256"
	[[ $bad == 0 ]] && echo "verify: the phone holds the image" || { echo "verify: differences"; exit 1; }
}

case "${1:-}" in
check) check ;;
fetch) fetch ;;
build) build ;;
finish) finish ;;
install) install ;;
verify) verify ;;
all) check; fetch; build ;;
*) sed -n 2,20p "$0"; exit 2 ;;
esac
