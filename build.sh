#!/bin/bash
set -e

TOOLCHAIN_BIN="/opt/theos/toolchain/linux/iphone/ios-arm64e-clang-toolchain/bin"
CCTOOLS_BIN="/opt/cctools/bin"
SDK="/opt/sdks/iPhoneOS10.3.sdk"
TRIPLE="armv7-apple-ios9.0"

export PATH="$TOOLCHAIN_BIN:$CCTOOLS_BIN:$PATH"
export LD_LIBRARY_PATH=/opt/cctools/lib:$LD_LIBRARY_PATH

CC="clang -target $TRIPLE -isysroot $SDK -miphoneos-version-min=9.0 -marm -O2 -fobjc-arc -D_LIBCPP_DISABLE_AVAILABILITY -Wno-gnu-zero-variadic-macro-arguments"
CXX="clang++ -target $TRIPLE -isysroot $SDK -miphoneos-version-min=9.0 -marm -O2 -stdlib=libc++ -std=c++17 -fobjc-arc -D_LIBCPP_DISABLE_AVAILABILITY -Wno-gnu-zero-variadic-macro-arguments -fno-aligned-allocation"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="/tmp/sendspin_build"
OUT_DIR="$SRC_DIR"
PUB_DIR="/mnt/c/Users/dimak"

mkdir -p "$BUILD_DIR/obj" "$BUILD_DIR/Payload/Sendspin.app"

INCLUDES="-I$SRC_DIR/src/sendspin/include \
          -I$SRC_DIR/src/sendspin \
          -I$SRC_DIR/src/sendspin/host \
          -I$SRC_DIR/src/arduinojson \
          -I$SRC_DIR/src \
          -I$SRC_DIR/src/ixwebsocket \
          -I$SRC_DIR/src/micro-flac/include \
          -I$SRC_DIR/src/micro-flac \
          -I$SRC_DIR/src/micro-opus/include \
          -I$SRC_DIR/src/micro-opus \
          -I$SRC_DIR/src/micro-ogg-demuxer/include \
          -I$SRC_DIR/src/micro-ogg-demuxer \
          -I$SRC_DIR/src/opus/include \
          -I$SRC_DIR/src/opus/celt \
          -I$SRC_DIR/src/opus/silk \
          -I$SRC_DIR/src/opus/silk/fixed \
          -I$SRC_DIR/ios"

DEFINES="-DSENDSPIN_ENABLE_PLAYER=1 \
         -DSENDSPIN_ENABLE_CONTROLLER=1 \
         -DSENDSPIN_ENABLE_METADATA=1 \
         -DSENDSPIN_ENABLE_ARTWORK=1 \
         -DSENDSPIN_ENABLE_COLOR=1 \
         -DSENDSPIN_ENABLE_VISUALIZER=1 \
         -DARDUINOJSON_ENABLE_STD_STRING=1 \
         -DARDUINOJSON_USE_LONG_LONG=1 \
         -DIXWEBSOCKET_USE_APPLE_SSL=1 \
         -DUSE_TLS=0 \
         -DUSE_ZLIB=0"

echo "=== Compiling iOS App Objective-C/C++ sources ==="
$CC -c $INCLUDES $DEFINES $SRC_DIR/ios/main.m -o $BUILD_DIR/obj/main.o
$CXX -c $INCLUDES $DEFINES $SRC_DIR/ios/AppDelegate.mm -o $BUILD_DIR/obj/AppDelegate.o
$CXX -c $INCLUDES $DEFINES $SRC_DIR/ios/ViewController.mm -o $BUILD_DIR/obj/ViewController.o
$CXX -c $INCLUDES $DEFINES $SRC_DIR/ios/AudioEngine.mm -o $BUILD_DIR/obj/AudioEngine.o
$CXX -c $INCLUDES $DEFINES $SRC_DIR/ios/SendspinBridge.mm -o $BUILD_DIR/obj/SendspinBridge.o

cat > $BUILD_DIR/shim.cpp << "EOF"
#include <cstdint>
extern "C" {
    void* __dso_handle = 0;
}
EOF
$CXX -c $INCLUDES $DEFINES -fno-builtin $BUILD_DIR/shim.cpp -o $BUILD_DIR/obj/shim.o

echo "=== Compiling sendspin-cpp sources ==="
for f in $SRC_DIR/src/sendspin/*.cpp $SRC_DIR/src/sendspin/host/*.cpp; do
    [ -f "$f" ] && $CXX -c $INCLUDES $DEFINES "$f" -o "$BUILD_DIR/obj/sendspin_$(basename "$f" .cpp).o"
done

echo "=== Compiling IXWebSocket sources ==="
for f in $SRC_DIR/src/ixwebsocket/*.cpp; do
    [ -f "$f" ] && $CXX -c $INCLUDES $DEFINES "$f" -o "$BUILD_DIR/obj/ix_$(basename "$f" .cpp).o"
done

echo "=== Compiling micro-flac sources ==="
for f in $SRC_DIR/src/micro-flac/*.cpp; do
    [ -f "$f" ] && $CXX -c $INCLUDES $DEFINES "$f" -o "$BUILD_DIR/obj/flac_$(basename "$f" .cpp).o"
done

echo "=== Compiling micro-ogg-demuxer sources ==="
for f in $SRC_DIR/src/micro-ogg-demuxer/*.cpp; do
    [ -f "$f" ] && $CXX -c $INCLUDES $DEFINES "$f" -o "$BUILD_DIR/obj/ogg_$(basename "$f" .cpp).o"
done

echo "=== Compiling micro-opus sources ==="
for f in $SRC_DIR/src/micro-opus/*.cpp; do
    [ -f "$f" ] && $CXX -c $INCLUDES $DEFINES "$f" -o "$BUILD_DIR/obj/opus_$(basename "$f" .cpp).o"
done

echo "=== Compiling libopus C sources ==="
OPUS_DEFINES="-DOPUS_BUILD=1 -DVAR_ARRAYS=1 -DHAVE_LRINTF=1 -DFIXED_POINT=1"
for f in $SRC_DIR/src/opus/src/*.c $SRC_DIR/src/opus/celt/*.c $SRC_DIR/src/opus/silk/*.c $SRC_DIR/src/opus/silk/fixed/*.c; do
    [ -f "$f" ] && $CC -c $INCLUDES $DEFINES $OPUS_DEFINES "$f" -o "$BUILD_DIR/obj/libopus_$(basename "$f" .c).o"
done

echo "=== Creating Static Archive for Engine ==="
/opt/cctools/bin/arm-apple-darwin11-ar rcs $BUILD_DIR/libsendspin_engine.a $BUILD_DIR/obj/*.o

echo "=== Linking Sendspin Binary ==="
/opt/cctools/bin/arm-apple-darwin11-ld -dynamic -arch armv7 -ios_version_min 9.0 \
    -flat_namespace -undefined suppress \
    -F /tmp/stubs/Frameworks \
    -L /tmp/stubs/usr/lib \
    -o $BUILD_DIR/Payload/Sendspin.app/Sendspin \
    $BUILD_DIR/obj/main.o $BUILD_DIR/obj/AppDelegate.o $BUILD_DIR/obj/ViewController.o \
    $BUILD_DIR/obj/AudioEngine.o $BUILD_DIR/obj/SendspinBridge.o $BUILD_DIR/obj/shim.o \
    $BUILD_DIR/libsendspin_engine.a \
    -framework Foundation -framework UIKit -framework CoreGraphics \
    -framework AudioToolbox -framework AVFoundation -framework MediaPlayer \
    -framework Security -framework CFNetwork -framework CoreFoundation \
    -lc++ -lc++abi -lobjc -lSystem

echo "=== Packaging Application ==="
cp $SRC_DIR/ios/Info.plist $BUILD_DIR/Payload/Sendspin.app/Info.plist
cp $SRC_DIR/assets/icons/*.png $BUILD_DIR/Payload/Sendspin.app/

echo "=== Code Signing with ldid ==="
/usr/local/bin/ldid -S$SRC_DIR/ios/Entitlements.plist $BUILD_DIR/Payload/Sendspin.app/Sendspin

echo "=== Creating IPA ==="
cd $BUILD_DIR
rm -f $OUT_DIR/Sendspin-1.0.0.ipa $PUB_DIR/Sendspin.ipa
zip -qr9 $OUT_DIR/Sendspin-1.0.0.ipa Payload
cp $OUT_DIR/Sendspin-1.0.0.ipa $PUB_DIR/Sendspin.ipa

echo "=== Creating DEB Package ==="
rm -rf $BUILD_DIR/deb
mkdir -p $BUILD_DIR/deb/DEBIAN $BUILD_DIR/deb/Applications
cp -r $BUILD_DIR/Payload/Sendspin.app $BUILD_DIR/deb/Applications/
cat << "DEB_EOF" > $BUILD_DIR/deb/DEBIAN/control
Package: com.sendspin.player
Name: Sendspin Player
Version: 1.0.0
Architecture: iphoneos-arm
Description: Sendspin Synchronized Multi-room Audio Player for iOS (Universal iOS 3.0 — 9.3+)
Maintainer: Delliaf <34547169+Delliaf@users.noreply.github.com>
Author: Delliaf
Section: Multimedia
Depends: firmware (>= 3.0)
DEB_EOF

rm -f $OUT_DIR/com.sendspin.player_1.0.0_iphoneos-arm.deb $PUB_DIR/Sendspin.deb
dpkg-deb -Zgzip -b $BUILD_DIR/deb $OUT_DIR/com.sendspin.player_1.0.0_iphoneos-arm.deb
cp $OUT_DIR/com.sendspin.player_1.0.0_iphoneos-arm.deb $PUB_DIR/Sendspin.deb

echo "=== SUCCESS! ==="
ls -lh $PUB_DIR/Sendspin.ipa $PUB_DIR/Sendspin.deb
file $BUILD_DIR/Payload/Sendspin.app/Sendspin
