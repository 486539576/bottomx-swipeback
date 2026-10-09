# ============================================================================
#  Bottom-x 上滑返回 —— theos 构建文件
#  需要已安装 theos 及其 SDK（iOS 14+）。
#
#  用法：
#    export THEOS=/path/to/theos
#    export THEOS_DEVICE_IP=设备IP   # 可选，用于 make install
#    make package         # 打 deb（输出到 packages/）
#    make install         # 安装到设备（需越狱 + SSH + theos 自带 deploy）
# ============================================================================

TARGET := iphone:clang:latest:14.0
# 目标为 arm64e 新 ABI（iOS 14+，A12+ 设备）。该 ABI 只能在 macOS/Xcode 编译，
# 本工程通过 GitHub Actions 云端 Mac 构建（Linux 编不出新 ABI arm64e）。
ARCHS  = arm64e

# 本 dylib 通过 SpringBoard 过滤加载，把"小白条可点击区域"加宽，
# 检测到单击后发原版返回通知，由原版 HomeTapBackApp.dylib 执行返回。
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HomeTapBackSwipe

HomeTapBackSwipe_FILES    = Tweak.xm
HomeTapBackSwipe_CFLAGS   = -fobjc-arc 
HomeTapBackSwipe_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore AudioToolbox
HomeTapBackSwipe_LDFLAGS = -Wl,-no_dead_strip_inits_and_terms -Wl,-install_name,@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/HomeTapBackSwipe.dylib
HomeTapBackSwipe_LIBRARIES  = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
