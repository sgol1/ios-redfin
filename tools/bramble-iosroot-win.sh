#!/bin/bash
# Windows side of the iosroot workflow (Git Bash: openssl + gzip ship with Git for Windows; no WSL).
#
#   bash tools/bramble-iosroot-win.sh fetch RUN_ID   download the encrypted parts, check them, delete the artifact
#   bash tools/bramble-iosroot-win.sh decrypt        -> work/iosroot/iosroot.img (16 GiB) + research/ipsw-x/d22ap.adt,
#                                                     then the per-GiB SHA-256 check
#   bash tools/bramble-iosroot-win.sh install        write iosroot.img to the phone's userdata from TWRP (ERASES it),
#                                                     then verify
#   bash tools/bramble-iosroot-win.sh verify         compare the phone's userdata with the image, per GiB
#
# The key is ../iosroot.key (outside the repo), the same value as the IOSROOT_KEY repository secret.
# gh must be signed in to the account that owns the fork (REPO, default sgol1/ios-redfin).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=${REPO:-sgol1/ios-redfin}
D=work/iosroot
KEYFILE=${KEYFILE:-../iosroot.key}
mkdir -p "$D"

dec() { ROOTKEY=$(cat "$KEYFILE") openssl enc -d -aes-256-ctr -pbkdf2 -iter 200000 -md sha256 -pass env:ROOTKEY; }

fetch() {
	local run=$1
	rm -rf "$D/enc"; mkdir -p "$D/enc"
	gh run download "$run" -R "$REPO" -n iosroot-encrypted -D "$D/enc"
	(cd "$D/enc" && sha256sum -c PARTS.sha256)
	cp "$D/enc/iosroot.gib.sha256" "$D/"
	# the parts are on this PC and checked: remove the artifact from GitHub now
	local aid
	aid=$(gh api "repos/$REPO/actions/runs/$run/artifacts" --jq '.artifacts[]|select(.name=="iosroot-encrypted")|.id')
	[[ -n $aid ]] && gh api -X DELETE "repos/$REPO/actions/artifacts/$aid" && echo "artifact $aid deleted from GitHub"
}

gibcheck() {
	python -I - "$D/iosroot.img" "$D/iosroot.gib.sha256" <<'PY'
import hashlib, sys
want = dict(l.split() for l in open(sys.argv[2]))
bad = 0
with open(sys.argv[1], 'rb') as f:
    i = 0
    while True:
        h = hashlib.sha256(); n = 0
        while n < 1 << 30:
            c = f.read(1 << 22)
            if not c: break
            h.update(c); n += len(c)
        if not n: break
        ok = want.get(str(i)) == h.hexdigest()
        bad += not ok
        print(f'GiB {i} {"ok" if ok else "DIFFERS"}'); i += 1
print('image matches the build' if bad == 0 and i == len(want) else 'MISMATCH'); sys.exit(bad != 0 or i != len(want))
PY
}

decrypt() {
	[[ -f $KEYFILE ]] || { echo "no key at $KEYFILE"; exit 1; }
	cat "$D"/enc/iosroot.img.gz.enc.* | dec | gzip -dc > "$D/iosroot.img.partial"
	mv "$D/iosroot.img.partial" "$D/iosroot.img"
	mkdir -p research/ipsw-x
	dec < "$D/enc/d22ap.tar.enc" | tar -xf - -C research/ipsw-x
	ls -l "$D/iosroot.img" research/ipsw-x/d22ap.adt
	gibcheck
}

phone_userdata() {
	[[ $(adb get-state 2>/dev/null | tr -d '\r') == recovery ]] || { echo "phone is not in TWRP (recovery)"; exit 1; }
	[[ $(adb shell getprop ro.boot.hardware.platform </dev/null | tr -d '\r') == sm7250 ]] || { echo "not an SM7250 phone"; exit 1; }
	MSYS_NO_PATHCONV=1 adb shell readlink -f /dev/block/by-name/userdata </dev/null | tr -d '\r'
}

install() {
	local img="$D/iosroot.img" part size psize ok
	[[ -f $img ]] || { echo "no $img: run decrypt"; exit 1; }
	part=$(phone_userdata)
	size=$(stat -c %s "$img")
	psize=$(MSYS_NO_PATHCONV=1 adb shell blockdev --getsize64 "$part" </dev/null | tr -d '\r')
	echo "phone userdata: $part ($psize bytes); image $size bytes"
	(( psize >= size )) || { echo "userdata is smaller than the image"; exit 1; }
	if [[ ${ERASE:-} != yes ]]; then
		read -r -p "This ERASES Android's user data on the phone. Type ERASE: " ok
		[[ $ok == ERASE ]] || { echo "not written"; exit 1; }
	fi
	# cmd's redirect keeps the bytes binary; dd from TWRP (never fastboot flash userdata: ABL hangs)
	cmd //c "adb exec-in \"dd of=$part bs=4194304\" < \"$(cygpath -w "$img")\""
	MSYS_NO_PATHCONV=1 adb shell sync </dev/null
	verify
}

verify() {
	local part i want got bad=0
	part=$(phone_userdata)
	while read -r i want; do
		got=$(MSYS_NO_PATHCONV=1 adb shell "dd if=$part bs=4194304 skip=$((i * 256)) count=256 2>/dev/null | sha256sum" </dev/null | awk '{print $1}')
		if [[ $got == "$want" ]]; then echo "GiB $i ok"; else echo "GiB $i DIFFERS"; bad=1; fi
	done < "$D/iosroot.gib.sha256"
	[[ $bad == 0 ]] && echo "verify: the phone holds the iOS root image" || { echo "verify: differences"; exit 1; }
}

case "${1:-}" in
fetch) fetch "${2:?run id}" ;;
decrypt) decrypt ;;
install) install ;;
verify) verify ;;
*) sed -n 2,13p "$0"; exit 2 ;;
esac
