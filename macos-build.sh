#!/bin/bash
# ============================================================================
#  GitHub Actions（macOS）一键构建：Bottom-x 上滑返回
#  macos clang(Xcode) 才能编出 arm64e 新ABI(B-key)，此脚本在云端 Mac 上运行。
#  原插件素材从 original.deb 解包获取，避免上传大量二进制。
# ============================================================================
set -e
cd "$(dirname "$0")"
echo "=== theos: $THEOS ==="

# ---- 1. 编译 arm64e dylib ----
make clean || true
make

DYLIB=$(find .theos -name 'HomeTapBackSwipe.dylib' 2>/dev/null | head -1)
[ -z "$DYLIB" ] && { echo "ERROR: 无编译产物"; exit 1; }
echo "产物: $DYLIB"; file "$DYLIB" | head -1

# ---- 2. substrate 依赖改为 roothide 的 .jbroot（与原件一致）----
export DYLIB_PATH="$DYLIB"
python3 - <<'PY'
import struct, os
p = os.environ['DYLIB_PATH']
d = bytearray(open(p,'rb').read())
slices = []
if d[:4] == b'\xca\xfe\xba\xbe':
    n = struct.unpack_from('>I', d, 4)[0]
    for i in range(n):
        off=8+i*20
        cp,sub,sl,sz = struct.unpack_from('>IIII', d, off)
        slices.append((sl,sz))
else:
    slices = [(0,len(d))]
old = b'/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate'
new = b'@loader_path/.jbroot/usr/lib/libsubstrate.dylib'
for sl,sz in slices:
    s = bytes(d[sl:sl+sz])
    ncmds,_ = struct.unpack_from('<II', s, 16)
    off = 32; found = 0
    for i in range(ncmds):
        cmd,csz = struct.unpack_from('<II', s, off)
        if cmd == 0xc:
            so = struct.unpack_from('<I', s, off+8)[0]
            end = s[off+so:off+csz].find(b'\x00')
            name = s[off+so:off+so+end]
            if old in name:
                st = off+so
                for j in range(len(new)): d[sl+st+j]=new[j]
                for j in range(len(new),len(old)): d[sl+st+j]=0
                found += 1
        off += csz
    print(f'切片@{sl}: substrate{"已改.jbroot" if found else "无需/未匹配"}')
open(p,'wb').write(bytes(d))
PY

# ---- 3. 从 original.deb 解出原插件素材 ----
echo "=== 解包 original.deb ==="
rm -rf DATA CTL
mkdir -p DATA CTL
ar x original.deb   # -> control.tar.gz data.tar.lzma debian-binary
tar -xf control.tar.gz -C CTL || true
xz -dc data.tar.lzma | tar -xf - -C DATA
ls DATA/Library/MobileSubstrate/DynamicLibraries/

# ---- 4. 覆盖/加入新 dylib 与设置 ----
cp "$DYLIB" DATA/Library/MobileSubstrate/DynamicLibraries/HomeTapBackSwipe.dylib
cp HomeTapBackSwipe.plist DATA/Library/MobileSubstrate/DynamicLibraries/HomeTapBackSwipe.plist
mkdir -p DATA/Library/PreferenceBundles/Bottom-xPrefs.bundle
cp Root.plist DATA/Library/PreferenceBundles/Bottom-xPrefs.bundle/Root.plist
chmod 755 DATA/Library/MobileSubstrate/DynamicLibraries/HomeTapBackSwipe.dylib

# ---- 5. 写 control 并打包 deb ----
cat > CTL/control <<'EOF'
Package: com.colorblack.bottomx
Name: Bottom-x roothide
Description: 点击底部小白条逐级返回。新增左下/右下角上滑返回，含触发区域/灵敏度/二次上滑确认/中间触发后台设置项。GitHub Actions macOS(Xcode) arm64e B-key 编译版。
Maintainer: Color Black
Author: Color Black
Section: Tweaks
Depends: mobilesubstrate | ellekit, preferenceloader, firmware (>= 14.0)
Architecture: iphoneos-arm64e
Version: 0.2.86
Installed-Size: 3080
EOF
echo "2.0" > debian-binary
tar -C CTL -czf control.tar.gz .
tar -C DATA -cf data.tar .
xz -F lzma -f data.tar
OUT="${OUT_DIR:-$PWD}/Bottom-x_0.2.86_上滑返回_Bkey-macOS.deb"
ar rcs "$OUT" debian-binary control.tar.gz data.tar.lzma
rm -f control.tar.gz data.tar debian-binary data.tar.lzma
echo "✅ 打包完成: $OUT"
ls -la "$OUT"
