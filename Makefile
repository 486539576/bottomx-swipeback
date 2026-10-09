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

# 本 dylib 通过 SpringBoard 过滤加载，用于拦截并重解释系统底部上滑手势；
# "返回上一级"仍复用 App 侧的 HomeTapBackApp.dylib（需已安装）。
# install 目标进程仅用于方便调试，实际 deb 安装到 DynamicLibraries。
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HomeTapBackSwipe SwipeBackApp

HomeTapBackSwipe_FILES    = Tweak.xm
HomeTapBackSwipe_CFLAGS   = -fobjc-arc 
HomeTapBackSwipe_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore AudioToolbox
HomeTapBackSwipe_LDFLAGS = -Wl,-no_dead_strip_inits_and_terms -Wl,-install_name,@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/HomeTapBackSwipe.dylib
HomeTapBackSwipe_LIBRARIES  = substrate

SwipeBackApp_FILES    = TweakApp.xm
SwipeBackApp_CFLAGS   = -fobjc-arc
SwipeBackApp_FRAMEWORKS = UIKit Foundation
SwipeBackApp_LDFLAGS = -Wl,-no_dead_strip_inits_and_terms -Wl,-install_name,@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/SwipeBackApp.dylib
SwipeBackApp_LIBRARIES  = substrate
# 真 ld64（cctools）能自行处理 -arch/-platform_version 等，无需额外 LDFLAGS

include $(THEOS_MAKE_PATH)/tweak.mk
