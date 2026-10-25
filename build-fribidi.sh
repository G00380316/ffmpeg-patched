#!/bin/sh
#
# Builds GPlayerFriBidiBinary.xcframework from GNU FriBidi 1.0.16, unmodified:
# one dynamic GPlayerFriBidiBinary.framework per platform variant,
# interface-compatible with the framework an app ships, so it can replace that
# framework inside the app (see README.md). The app's libass framework loads
# it by its install name.
#
# What a replacement has to keep, and this script reproduces:
#   - the framework and binary name, GPlayerFriBidiBinary;
#   - the install name, @rpath/GPlayerFriBidiBinary.framework/GPlayerFriBidiBinary
#     (macOS: @rpath/GPlayerFriBidiBinary.framework/Versions/A/GPlayerFriBidiBinary);
#   - compatibility version 1.0.0;
#   - FriBidi's own fribidi_* API, exported unchanged and alone.
#
# Usage:
#   ./build-fribidi.sh [--slice ID]... [--jobs N]
#
# Slices as for build-ffmpeg.sh (all eight by default). Needs Xcode with the
# iOS, tvOS and macOS SDKs, make, and curl. Environment:
#   FFMPEG_PATCHED_WORK              work directory (default ./build)
#   FFMPEG_PATCHED_OUT               output directory (default ./out)
#   FFMPEG_PATCHED_FRIBIDI_BUNDLE_ID CFBundleIdentifier (default ffmpeg-patched.GPlayerFriBidiBinary)
#   FFMPEG_PATCHED_BUNDLE_VERSION    CFBundleVersion (default 1)

set -eu

FRIBIDI_VERSION=1.0.16
FRIBIDI_URL=https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz
FRIBIDI_SHA256=1b1cde5b235d40479e91be2f0e88a309e3214c8ab470ec8a2744d82a5a9ea05c

NAME=GPlayerFriBidiBinary
ALL_SLICES='ios-arm64 iossim-arm64 iossim-x86_64 tvos-arm64 tvossim-arm64 tvossim-x86_64 macos-arm64 macos-x86_64'

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORK=${FFMPEG_PATCHED_WORK:-"$ROOT/build"}
OUT=${FFMPEG_PATCHED_OUT:-"$ROOT/out"}
BUNDLE_ID=${FFMPEG_PATCHED_FRIBIDI_BUNDLE_ID:-ffmpeg-patched.$NAME}
BUNDLE_VERSION=${FFMPEG_PATCHED_BUNDLE_VERSION:-1}
SLICES=''
JOBS=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
export LC_ALL=C LANG=C ZERO_AR_DATE=1

die() { printf 'build-fribidi: error: %s\n' "$*" >&2; exit 1; }
note() { printf 'build-fribidi: %s\n' "$*"; }

while [ "$#" -gt 0 ]; do
    case $1 in
        --slice) SLICES="$SLICES $2"; shift 2 ;;
        --jobs) JOBS=$2; shift 2 ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$SLICES" ] || SLICES=$ALL_SLICES
case "$ROOT$WORK$OUT" in *' '*) die 'paths with spaces are not supported' ;; esac

# Sets SDK, PLATFORM, KIND, ARCH, TRIPLE and HOST (autotools) for a slice.
slice_info() {
    case $1 in
        ios-arm64) SDK=iphoneos PLATFORM=ios KIND=device ARCH=arm64 TRIPLE=arm64-apple-ios15.0 HOST=arm ;;
        iossim-arm64) SDK=iphonesimulator PLATFORM=ios KIND=simulator ARCH=arm64 TRIPLE=arm64-apple-ios15.0-simulator HOST=arm ;;
        iossim-x86_64) SDK=iphonesimulator PLATFORM=ios KIND=simulator ARCH=x86_64 TRIPLE=x86_64-apple-ios15.0-simulator HOST=x86_64 ;;
        tvos-arm64) SDK=appletvos PLATFORM=tvos KIND=device ARCH=arm64 TRIPLE=arm64-apple-tvos15.0 HOST=arm ;;
        tvossim-arm64) SDK=appletvsimulator PLATFORM=tvos KIND=simulator ARCH=arm64 TRIPLE=arm64-apple-tvos15.0-simulator HOST=arm ;;
        tvossim-x86_64) SDK=appletvsimulator PLATFORM=tvos KIND=simulator ARCH=x86_64 TRIPLE=x86_64-apple-tvos15.0-simulator HOST=x86_64 ;;
        macos-arm64) SDK=macosx PLATFORM=macos KIND=device ARCH=arm64 TRIPLE=arm64-apple-macos12.0 HOST=aarch64 ;;
        macos-x86_64) SDK=macosx PLATFORM=macos KIND=device ARCH=x86_64 TRIPLE=x86_64-apple-macos12.0 HOST=x86_64 ;;
        *) die "unknown slice: $1" ;;
    esac
}

ARCHIVE="$WORK/downloads/fribidi-$FRIBIDI_VERSION.tar.xz"
mkdir -p "$WORK/downloads" "$WORK/source"
if [ ! -f "$ARCHIVE" ]; then
    curl --fail --location --proto '=https' --tlsv1.2 -o "$ARCHIVE.part" "$FRIBIDI_URL"
    mv "$ARCHIVE.part" "$ARCHIVE"
fi
[ "$(shasum -a 256 "$ARCHIVE" | awk '{ print $1 }')" = "$FRIBIDI_SHA256" ] || die "checksum mismatch: $ARCHIVE"
SOURCE="$WORK/source/fribidi-$FRIBIDI_VERSION"
[ -d "$SOURCE" ] || tar -xf "$ARCHIVE" -C "$WORK/source"

for SLICE in $SLICES; do
    slice_info "$SLICE"
    note "building $SLICE"
    SDK_PATH=$(xcrun --sdk "$SDK" --show-sdk-path)
    CLANG=$(xcrun --sdk "$SDK" --find clang)
    PREFIX="$WORK/fribidi/$SLICE"
    rm -rf "$PREFIX" "$PREFIX-build"
    mkdir -p "$PREFIX-build"
    # A static FriBidi, as its own build system makes it, is the link input.
    (
        cd "$PREFIX-build"
        env CC="$CLANG" CXX="$(xcrun --sdk "$SDK" --find clang++)" \
            AR="$(xcrun --sdk "$SDK" --find ar)" RANLIB="$(xcrun --sdk "$SDK" --find ranlib)" \
            CFLAGS="-target $TRIPLE -isysroot $SDK_PATH -fPIC -O2" \
            CXXFLAGS="-target $TRIPLE -isysroot $SDK_PATH -fPIC -O2" \
            LDFLAGS="-target $TRIPLE -isysroot $SDK_PATH" \
            PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" \
            "$SOURCE/configure" --host="$HOST-apple-darwin" --prefix="$PREFIX" \
                --enable-static --disable-shared --disable-docs
        make -j "$JOBS"
        make install
    ) > "$PREFIX-build.log" 2>&1 || { tail -30 "$PREFIX-build.log" >&2; die "FriBidi build failed for $SLICE"; }
    nm -arch "$ARCH" -g -U "$PREFIX/lib/libfribidi.a" | awk '!/:$/ && NF == 3 && $2 != "U" { print $3 }' \
        | sort -u | grep -E '^_fribidi_' > "$PREFIX/exports.txt"
    if [ "$PLATFORM" = macos ]; then BINARY_PATH="$NAME.framework/Versions/A/$NAME"; else BINARY_PATH="$NAME.framework/$NAME"; fi
    "$CLANG" -target "$TRIPLE" -isysroot "$SDK_PATH" -dynamiclib \
        -Wl,-S -Wl,-dead_strip -Wl,-headerpad_max_install_names -Wl,-application_extension \
        -Wl,-force_load,"$PREFIX/lib/libfribidi.a" \
        -install_name "@rpath/$BINARY_PATH" \
        -compatibility_version 1.0.0 -current_version "$FRIBIDI_VERSION" \
        -Wl,-exported_symbols_list,"$PREFIX/exports.txt" \
        -o "$PREFIX/$NAME"
done

write_info_plist() {
    case $PLATFORM:$KIND in
        ios:device) SUPPORTED=iPhoneOS ;; ios:simulator) SUPPORTED=iPhoneSimulator ;;
        tvos:device) SUPPORTED=AppleTVOS ;; tvos:simulator) SUPPORTED=AppleTVSimulator ;;
        macos:device) SUPPORTED=MacOSX ;;
    esac
    case $PLATFORM in
        ios) EXTRA='<key>MinimumOSVersion</key><string>15.0</string><key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>' ;;
        tvos) EXTRA='<key>MinimumOSVersion</key><string>15.0</string><key>UIDeviceFamily</key><array><integer>3</integer></array>' ;;
        macos) EXTRA='<key>LSMinimumSystemVersion</key><string>12.0</string>' ;;
    esac
    cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>$NAME</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>$FRIBIDI_VERSION</string>
<key>CFBundleSupportedPlatforms</key><array><string>$SUPPORTED</string></array>
<key>CFBundleVersion</key><string>$BUNDLE_VERSION</string>
$EXTRA
</dict>
</plist>
EOF
    plutil -lint "$1" > /dev/null
}

XCFRAMEWORK_ARGS=''
for VARIANT in 'ios-device:ios-arm64' 'ios-simulator:iossim-arm64 iossim-x86_64' 'tvos-device:tvos-arm64' \
    'tvos-simulator:tvossim-arm64 tvossim-x86_64' 'macos:macos-arm64 macos-x86_64'; do
    set --
    for LANE in ${VARIANT#*:}; do
        case " $SLICES " in *" $LANE "*) set -- "$@" "$WORK/fribidi/$LANE/$NAME"; FIRST_LANE=${FIRST_LANE:-$LANE} ;; esac
    done
    [ "$#" -gt 0 ] || continue
    slice_info "$FIRST_LANE"
    unset FIRST_LANE
    VARIANT_DIR="$WORK/fribidi/variants/${VARIANT%%:*}"
    FRAMEWORK="$VARIANT_DIR/$NAME.framework"
    rm -rf "$VARIANT_DIR"
    mkdir -p "$VARIANT_DIR"
    if [ "$#" -eq 1 ]; then cp "$1" "$VARIANT_DIR/$NAME.bin"; else lipo -create "$@" -output "$VARIANT_DIR/$NAME.bin"; fi
    xcrun strip -x "$VARIANT_DIR/$NAME.bin"
    if [ "$PLATFORM" = macos ]; then
        mkdir -p "$FRAMEWORK/Versions/A/Resources"
        mv "$VARIANT_DIR/$NAME.bin" "$FRAMEWORK/Versions/A/$NAME"
        write_info_plist "$FRAMEWORK/Versions/A/Resources/Info.plist"
        ln -s A "$FRAMEWORK/Versions/Current"
        ln -s "Versions/Current/$NAME" "$FRAMEWORK/$NAME"
        ln -s Versions/Current/Resources "$FRAMEWORK/Resources"
    else
        mkdir -p "$FRAMEWORK"
        mv "$VARIANT_DIR/$NAME.bin" "$FRAMEWORK/$NAME"
        write_info_plist "$FRAMEWORK/Info.plist"
    fi
    codesign --force --sign - --timestamp=none "$FRAMEWORK" > /dev/null 2>&1
    codesign --verify --strict "$FRAMEWORK"
    XCFRAMEWORK_ARGS="$XCFRAMEWORK_ARGS -framework $FRAMEWORK"
done
[ -n "$XCFRAMEWORK_ARGS" ] || die 'no slice was built'
mkdir -p "$OUT"
rm -rf "$OUT/$NAME.xcframework"
# shellcheck disable=SC2086
xcodebuild -create-xcframework $XCFRAMEWORK_ARGS -output "$OUT/$NAME.xcframework" > /dev/null
note "wrote $OUT/$NAME.xcframework"
