#!/bin/bash
# ============================================================================
#  macOS 一键构建脚本（产出可在 iOS 16 arm64e / RootHide 上加载的 .deb）
#  在装有 theos + Xcode 的 Mac 上运行，或在 GitHub Actions 的 macOS 运行器上运行。
#  macos clang（Xcode）才能编出 arm64e 需要的 B-key PAC（retab/blraa），
#  这是本插件能在 iOS 16 arm64e 设备上被 dyld 接受的关键。
# ============================================================================
set -e
cd "$(dirname "$0")"

# ---- 1. 环境检查 ----
export THEOS="${THEOS:?请先 export THEOS=/path/to/theos}"
export THEOS_DEVICE_IP=""
echo "theos 目录: $THEOS"

# ---- 2. 编译（仅 arm64e，B-key；仅编 dylib，不依赖 dpkg）----
make clean || true
make

# 取到刚编好的 dylib
DYLIB=$(find .theos -name 'HomeTapBackSwipe.dylib' 2>/dev/null | head -1)
if [ -z "$DYLIB" ]; then
  echo "ERROR: 找不到编译产物 HomeTapBackSwipe.dylib" >&2; exit 1
fi
echo "产物: $DYLIB"
file "$DYLIB" | head -1

# ---- 3. 把 substrate 依赖路径改成 roothide 的 .jbroot（与原件一致）----
python3 - <<PYEOF
import struct, sys
p = "$DYLIB"
d = bytearray(open(p,'rb').read())
# 处理 fat 头：若为 FAT 需逐切片处理
if d[:4] == b'\xca\xfe\xba\xbe':
    n = struct.unpack_from('>I', d, 4)[0]
    slices=[]
    for i in range(n):
        off=8+i*20
        cp,sub,sl,sz=struct.unpack_from('>IIII',d,off)
        slices.append((sl,sz))
else:
    slices=[(0,len(d))]
for sl,sz in slices:
    s = bytes(d[sl:sl+sz])
    ncmds,sizeofcmds = struct.unpack_from('<II', s, 16)
    off = 32
    old_s = b'/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate'
    new_s = b'@loader_path/.jbroot/usr/lib/libsubstrate.dylib'
    found=0
    for i in range(ncmds):
        cmd, csz = struct.unpack_from('<II', s, off)
        if cmd == 0xc:
            so = struct.unpack_from('<I', s, off+8)[0]
            end = s[off+so:off+csz].find(b'\x00')
            name = s[off+so:off+so+end]
            if old_s in name:
                st = off+so
                for j in range(len(new_s)): d[sl+st+j]=new_s[j]
                for j in range(len(new_s), len(old_s)): d[sl+st+j]=0
                found+=1
                print('切片@%d substrate路径已改 .jbroot' % sl)
        off += csz
    if not found:
        print('警告: 切片@%d 未找到 CydiaSubstrate 路径（可能已是 .jbroot 或用了其他 lib）' % sl)
open(p,'wb').write(bytes(d))
PYEOF

# ---- 4. 组装 roothide deb（复制原插件素材 + 新 dylib + 设置）----
STAGE=$(mktemp -d)
mkdir -p "$STAGE/data" "$STAGE/control"
# 素材统一取自工程内的 deb_data/（含原插件 dylib/plist 与已改好的设置）
cp -r deb_data/* "$STAGE/data/"
# 覆盖为本次新编译的 dylib（B-key arm64e）
cp "$DYLIB" "$STAGE/data/Library/MobileSubstrate/DynamicLibraries/HomeTapBackSwipe.dylib"
chmod 755 "$STAGE/data/Library/MobileSubstrate/DynamicLibraries/HomeTapBackSwipe.dylib"

cat > "$STAGE/control/control" <<'EOF'
Package: com.colorblack.bottomx
Name: Bottom-x roothide
Description: 点击底部小白条逐级返回。新增左下/右下角上滑返回，含触发区域/灵敏度/二次上滑确认/中间触发后台设置项。macOS(Xcode) B-key arm64e 编译版。
Maintainer: Color Black
Author: Color Black
Section: Tweaks
Depends: mobilesubstrate | ellekit, preferenceloader, firmware (>= 14.0)
Architecture: iphoneos-arm64e
Version: 1.0.0
Installed-Size: 3080
EOF
echo "2.0" > "$STAGE/debian-binary"
# 用 dpkg-deb 打包（brew 已装 dpkg，产出标准 deb，Linux 可直接解）
mkdir -p "$STAGE/pkg/DEBIAN"
cp "$STAGE/control/control" "$STAGE/pkg/DEBIAN/control"
cp -r "$STAGE/data/." "$STAGE/pkg/"
OUT="${OUT_DIR:-$PWD}/Bottom-x_1.0.0_上滑返回_Bkey-macOS.deb"
dpkg-deb --build --root-owner-group "$STAGE/pkg" "$OUT"
rm -rf "$STAGE"
echo "✅ 打包完成: $OUT"
echo "   把它装到你的 iPhone（Sileo/Filza）即可。"
