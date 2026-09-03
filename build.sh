#!/bin/bash
set -e

TOOLCHAIN_BIN="/opt/theos/toolchain/linux/iphone/ios-arm64e-clang-toolchain/bin"
SDK="/opt/sdks/iPhoneOS10.3.sdk"
TRIPLE="armv7-apple-ios9.0"

export PATH="$TOOLCHAIN_BIN:$PATH"

CC="clang -target $TRIPLE -isysroot $SDK -miphoneos-version-min=9.0 -marm -O2 -fobjc-arc -D_LIBCPP_DISABLE_AVAILABILITY -Wno-gnu-zero-variadic-macro-arguments"
CXX="clang++ -target $TRIPLE -isysroot $SDK -miphoneos-version-min=9.0 -marm -O2 -stdlib=libc++ -std=c++17 -fobjc-arc -D_LIBCPP_DISABLE_AVAILABILITY -Wno-gnu-zero-variadic-macro-arguments -fno-aligned-allocation"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="/tmp/sendspin_build"
rm -rf "$BUILD_DIR"
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

echo "=== Compiling sendspin-cpp sources ==="
for f in $SRC_DIR/src/sendspin/*.cpp; do
    name=$(basename "$f" .cpp)
    $CXX -c $INCLUDES $DEFINES "$f" -o "$BUILD_DIR/obj/sendspin_${name}.o"
done

for f in $SRC_DIR/src/sendspin/host/*.cpp; do
    name=$(basename "$f" .cpp)
    $CXX -c $INCLUDES $DEFINES "$f" -o "$BUILD_DIR/obj/sendspin_host_${name}.o"
done

echo "=== Compiling IXWebSocket sources ==="
for f in $SRC_DIR/src/ixwebsocket/*.cpp; do
    name=$(basename "$f" .cpp)
    $CXX -c $INCLUDES $DEFINES "$f" -o "$BUILD_DIR/obj/ix_${name}.o"
done

echo "=== Compiling micro-flac sources ==="
for f in $SRC_DIR/src/micro-flac/*.cpp; do
    name=$(basename "$f" .cpp)
    $CXX -c $INCLUDES $DEFINES "$f" -o "$BUILD_DIR/obj/flac_${name}.o"
done

echo "=== Compiling micro-ogg-demuxer sources ==="
for f in $SRC_DIR/src/micro-ogg-demuxer/*.cpp; do
    name=$(basename "$f" .cpp)
    $CXX -c $INCLUDES $DEFINES "$f" -o "$BUILD_DIR/obj/ogg_${name}.o"
done

echo "=== Compiling micro-opus sources ==="
for f in $SRC_DIR/src/micro-opus/*.cpp; do
    name=$(basename "$f" .cpp)
    $CXX -c $INCLUDES $DEFINES "$f" -o "$BUILD_DIR/obj/opus_${name}.o"
done

echo "=== Compiling libopus C sources ==="
OPUS_DEFINES="-DUSE_ALLOCA=1 -DHAVE_LRINT=1 -DHAVE_LRINTF=1 -DFIXED_POINT=1 -DOPUS_BUILD=1"
for f in $SRC_DIR/src/opus/src/opus.c \
         $SRC_DIR/src/opus/src/opus_decoder.c \
         $SRC_DIR/src/opus/src/opus_encoder.c \
         $SRC_DIR/src/opus/src/opus_multistream.c \
         $SRC_DIR/src/opus/src/opus_multistream_decoder.c \
         $SRC_DIR/src/opus/src/opus_multistream_encoder.c \
         $SRC_DIR/src/opus/src/repacketizer.c \
         $SRC_DIR/src/opus/src/mapping_matrix.c \
         $SRC_DIR/src/opus/celt/bands.c \
         $SRC_DIR/src/opus/celt/celt.c \
         $SRC_DIR/src/opus/celt/celt_decoder.c \
         $SRC_DIR/src/opus/celt/celt_encoder.c \
         $SRC_DIR/src/opus/celt/celt_lpc.c \
         $SRC_DIR/src/opus/celt/cwrs.c \
         $SRC_DIR/src/opus/celt/entcode.c \
         $SRC_DIR/src/opus/celt/entdec.c \
         $SRC_DIR/src/opus/celt/entenc.c \
         $SRC_DIR/src/opus/celt/kiss_fft.c \
         $SRC_DIR/src/opus/celt/laplace.c \
         $SRC_DIR/src/opus/celt/mathops.c \
         $SRC_DIR/src/opus/celt/mdct.c \
         $SRC_DIR/src/opus/celt/modes.c \
         $SRC_DIR/src/opus/celt/pitch.c \
         $SRC_DIR/src/opus/celt/quant_bands.c \
         $SRC_DIR/src/opus/celt/rate.c \
         $SRC_DIR/src/opus/celt/vq.c \
         $SRC_DIR/src/opus/silk/*.c \
         $SRC_DIR/src/opus/silk/fixed/*.c; do
    name=$(basename "$f" .c)
    $CC -c $INCLUDES $DEFINES $OPUS_DEFINES "$f" -o "$BUILD_DIR/obj/libopus_${name}.o"
done

echo "=== Linking Sendspin Binary ==="
FRAMEWORKS="-framework Foundation \
            -framework UIKit \
            -framework CoreGraphics \
            -framework AudioToolbox \
            -framework AVFoundation \
            -framework MediaPlayer \
            -framework Security \
            -framework CFNetwork \
            -framework CoreFoundation \
            -lc++ \
            -lc++abi \
            -Wl,-undefined,dynamic_lookup"

$CXX $BUILD_DIR/obj/*.o $FRAMEWORKS -o $BUILD_DIR/Payload/Sendspin.app/Sendspin

echo "=== Packaging Application ==="
cp $SRC_DIR/ios/Info.plist $BUILD_DIR/Payload/Sendspin.app/Info.plist

echo "=== Code Signing with ldid ==="
ldid -S$SRC_DIR/ios/Entitlements.plist $BUILD_DIR/Payload/Sendspin.app/Sendspin

echo "=== Creating IPA ==="
cd $BUILD_DIR
zip -qr9 $SRC_DIR/Sendspin-1.0.0.ipa Payload

echo "=== Creating DEB Package ==="
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

dpkg-deb -Zgzip -b $BUILD_DIR/deb $SRC_DIR/com.sendspin.player_1.0.0_iphoneos-arm.deb

echo "=== SUCCESS! ==="
ls -lh $SRC_DIR/Sendspin-1.0.0.ipa $SRC_DIR/com.sendspin.player_1.0.0_iphoneos-arm.deb
