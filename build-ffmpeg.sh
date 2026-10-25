#!/bin/sh
#
# Builds GPlayerFFmpegBinary.xcframework from the patched FFmpeg 9.0.2 in
# ffmpeg/ and dav1d 1.5.4: one dynamic GPlayerFFmpegBinary.framework per
# platform variant, interface-compatible with the framework an app ships, so
# it can replace that framework inside the app (see README.md).
#
# What a replacement has to keep, and this script reproduces:
#   - the framework and binary name, GPlayerFFmpegBinary;
#   - the install name, @rpath/GPlayerFFmpegBinary.framework/GPlayerFFmpegBinary
#     (macOS: @rpath/GPlayerFFmpegBinary.framework/Versions/A/GPlayerFFmpegBinary);
#   - compatibility version 1.0.0;
#   - every global renamed with the gpff_ prefix, and only FFmpeg's public API
#     exported: names beginning av (avpriv_ among them), swr_, swresample_,
#     sws_ and swscale_;
#   - the same configure profile, so the same components are present.
#
# Usage:
#   ./build-ffmpeg.sh [--profile compatibility-remux|playback] [--slice ID]...
#                     [--jobs N] [--from-tarball]
#
# Profiles: compatibility-remux (the default; it adds the MP4 muxer) and
# playback (decoding only). Slices: ios-arm64 iossim-arm64 iossim-x86_64
# tvos-arm64 tvossim-arm64 tvossim-x86_64 macos-arm64 macos-x86_64 (all by
# default). --from-tarball builds from the verified upstream tarball with
# patches/ applied, instead of from ffmpeg/.
#
# Needs Xcode with the iOS, tvOS and macOS SDKs, and meson, ninja, nasm,
# pkg-config and llvm-objcopy (for example: brew install meson ninja nasm
# pkg-config llvm). Environment:
#   FFMPEG_PATCHED_OBJCOPY        llvm-objcopy to use
#   FFMPEG_PATCHED_WORK           work directory (default ./build)
#   FFMPEG_PATCHED_OUT            output directory (default ./out)
#   FFMPEG_PATCHED_BUNDLE_ID      CFBundleIdentifier (default ffmpeg-patched.GPlayerFFmpegBinary)
#   FFMPEG_PATCHED_BUNDLE_VERSION CFBundleVersion (default 1)
#
# The paths of this directory must not contain spaces: FFmpeg's configure
# does not support them.

set -eu

FFMPEG_VERSION=9.0.2
FFMPEG_URL=https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
DAV1D_VERSION=1.5.4
DAV1D_URL=https://code.videolan.org/videolan/dav1d/-/archive/1.5.4/dav1d-1.5.4.tar.bz2
DAV1D_SHA256=2abfb0c89212e6e4733a54e0ae509ec00a5b845a6360946f918806e14aedb011

NAME=GPlayerFFmpegBinary
PREFIX=gpff_
EXPORT_PATTERN='^(av|swr_|swresample_|sws_|swscale_)'
ALL_SLICES='ios-arm64 iossim-arm64 iossim-x86_64 tvos-arm64 tvossim-arm64 tvossim-x86_64 macos-arm64 macos-x86_64'

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORK=${FFMPEG_PATCHED_WORK:-"$ROOT/build"}
OUT=${FFMPEG_PATCHED_OUT:-"$ROOT/out"}
BUNDLE_ID=${FFMPEG_PATCHED_BUNDLE_ID:-ffmpeg-patched.$NAME}
BUNDLE_VERSION=${FFMPEG_PATCHED_BUNDLE_VERSION:-1}
PROFILE=compatibility-remux
SLICES=''
JOBS=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
FROM_TARBALL=0
export LC_ALL=C LANG=C ZERO_AR_DATE=1

die() { printf 'build-ffmpeg: error: %s\n' "$*" >&2; exit 1; }
note() { printf 'build-ffmpeg: %s\n' "$*"; }
sha256() { shasum -a 256 "$1" | awk '{ print $1 }'; }

while [ "$#" -gt 0 ]; do
    case $1 in
        --profile) PROFILE=$2; shift 2 ;;
        --slice) SLICES="$SLICES $2"; shift 2 ;;
        --jobs) JOBS=$2; shift 2 ;;
        --from-tarball) FROM_TARBALL=1; shift ;;
        -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
case $PROFILE in compatibility-remux|playback) ;; *) die "unknown profile: $PROFILE" ;; esac
[ -n "$SLICES" ] || SLICES=$ALL_SLICES
case "$ROOT$WORK$OUT" in *' '*) die 'paths with spaces are not supported' ;; esac
for TOOL in xcrun xcodebuild meson ninja nasm pkg-config lipo libtool nm codesign plutil shasum curl; do
    command -v "$TOOL" >/dev/null 2>&1 || die "required tool is missing: $TOOL"
done
OBJCOPY=${FFMPEG_PATCHED_OBJCOPY:-}
for CANDIDATE in "$OBJCOPY" /opt/homebrew/opt/llvm/bin/llvm-objcopy /usr/local/opt/llvm/bin/llvm-objcopy "$(command -v llvm-objcopy || true)"; do
    if [ -n "$CANDIDATE" ] && [ -x "$CANDIDATE" ]; then OBJCOPY=$CANDIDATE; break; fi
done
[ -n "$OBJCOPY" ] && [ -x "$OBJCOPY" ] || die 'llvm-objcopy is missing; set FFMPEG_PATCHED_OBJCOPY'

# FFmpeg's configure flags: every component is off unless named here.
configure_flags() {
    printf '%s\n' \
        --disable-autodetect --disable-everything --disable-programs --disable-doc \
        --disable-debug --disable-gpl --disable-nonfree --disable-version3 \
        --disable-shared --enable-static --enable-pic --disable-symver \
        --enable-cross-compile --enable-pthreads --enable-network \
        --enable-securetransport --enable-libdav1d --enable-libxml2 \
        --disable-appkit --disable-avfoundation --disable-audiotoolbox \
        --disable-videotoolbox --disable-metal --disable-coreimage --disable-opencl \
        --disable-vulkan --disable-iconv --disable-bzlib --disable-lzma --disable-zlib \
        --disable-avdevice --disable-avfilter --enable-avcodec --enable-avformat \
        --enable-swresample --enable-swscale --disable-encoders --disable-muxers \
        --disable-filters --disable-devices \
        --enable-demuxer=aac,ac3,ass,avi,dash,dts,eac3,flac,flv,hls,matroska,mov,mp3,mpegts,ogg,rtsp,srt,truehd,wav,webvtt \
        --enable-decoder=aac,aac_latm,ac3,alac,dca,dvbsub,dvdsub,eac3,flac,h264,hevc,libdav1d,mp1,mp1float,mp2,mp2float,mp3,mp3float,mpeg2video,mpeg4,opus,pcm_f32le,pcm_f64le,pcm_s16be,pcm_s16le,pcm_s24be,pcm_s24le,pcm_s32be,pcm_s32le,pgssub,truehd,vc1,vorbis,vp8,vp9 \
        --enable-parser=aac,aac_latm,ac3,av1,dca,dvbsub,flac,h264,hevc,mlp,mpeg4video,mpegaudio,mpegvideo,opus,vc1,vorbis,vp8,vp9 \
        --enable-bsf=aac_adtstoasc,extract_extradata,h264_mp4toannexb,hevc_mp4toannexb,vp9_superframe_split \
        --enable-protocol=crypto,data,file,http,httpproxy,https,rtmp,rtmps,rtp,tcp,tls,udp
    if [ "$PROFILE" = compatibility-remux ]; then
        printf '%s\n' --disable-iamf --enable-muxer=mp4
    fi
}

# Sets SDK, PLATFORM, KIND, ARCH and TRIPLE for a slice.
slice_info() {
    case $1 in
        ios-arm64) SDK=iphoneos PLATFORM=ios KIND=device ARCH=arm64 TRIPLE=arm64-apple-ios15.0 ;;
        iossim-arm64) SDK=iphonesimulator PLATFORM=ios KIND=simulator ARCH=arm64 TRIPLE=arm64-apple-ios15.0-simulator ;;
        iossim-x86_64) SDK=iphonesimulator PLATFORM=ios KIND=simulator ARCH=x86_64 TRIPLE=x86_64-apple-ios15.0-simulator ;;
        tvos-arm64) SDK=appletvos PLATFORM=tvos KIND=device ARCH=arm64 TRIPLE=arm64-apple-tvos15.0 ;;
        tvossim-arm64) SDK=appletvsimulator PLATFORM=tvos KIND=simulator ARCH=arm64 TRIPLE=arm64-apple-tvos15.0-simulator ;;
        tvossim-x86_64) SDK=appletvsimulator PLATFORM=tvos KIND=simulator ARCH=x86_64 TRIPLE=x86_64-apple-tvos15.0-simulator ;;
        macos-arm64) SDK=macosx PLATFORM=macos KIND=device ARCH=arm64 TRIPLE=arm64-apple-macos12.0 ;;
        macos-x86_64) SDK=macosx PLATFORM=macos KIND=device ARCH=x86_64 TRIPLE=x86_64-apple-macos12.0 ;;
        *) die "unknown slice: $1" ;;
    esac
}

fetch() {
    FETCH_FILE="$WORK/downloads/$(basename "$1")"
    mkdir -p "$WORK/downloads"
    [ -f "$FETCH_FILE" ] || curl --fail --location --proto '=https' --tlsv1.2 -o "$FETCH_FILE.part" "$1"
    [ ! -f "$FETCH_FILE.part" ] || mv "$FETCH_FILE.part" "$FETCH_FILE"
    [ "$(sha256 "$FETCH_FILE")" = "$2" ] || die "checksum mismatch: $FETCH_FILE"
    printf '%s\n' "$FETCH_FILE"
}

prepare_sources() {
    mkdir -p "$WORK/source"
    DAV1D_SOURCE="$WORK/source/dav1d-$DAV1D_VERSION"
    if [ ! -d "$DAV1D_SOURCE" ]; then
        tar -xf "$(fetch "$DAV1D_URL" "$DAV1D_SHA256")" -C "$WORK/source"
    fi
    if [ "$FROM_TARBALL" = 1 ]; then
        FFMPEG_SOURCE="$WORK/source/ffmpeg-$FFMPEG_VERSION"
        rm -rf "$FFMPEG_SOURCE"
        tar -xf "$(fetch "$FFMPEG_URL" "$FFMPEG_SHA256")" -C "$WORK/source"
        INDEX=0
        while PATCH_NAME=$(plutil -extract "patches.$INDEX.name" raw -o - "$ROOT/patches/manifest.json" 2>/dev/null); do
            (cd "$FFMPEG_SOURCE" && patch --batch --forward --fuzz=0 -p1 < "$ROOT/patches/$PATCH_NAME")
            INDEX=$((INDEX + 1))
        done
    else
        FFMPEG_SOURCE="$ROOT/ffmpeg"
        [ ! -f "$FFMPEG_SOURCE/config.h" ] || die 'ffmpeg/ has been configured in place; clean it first'
    fi
    # Every patched file must match its recorded checksum.
    INDEX=0
    while TARGET=$(plutil -extract "patches.$INDEX.target" raw -o - "$ROOT/patches/manifest.json" 2>/dev/null); do
        EXPECTED=$(plutil -extract "patches.$INDEX.patched_sha256" raw -o - "$ROOT/patches/manifest.json")
        [ "$(sha256 "$FFMPEG_SOURCE/$TARGET")" = "$EXPECTED" ] || die "$TARGET is not the patched source"
        INDEX=$((INDEX + 1))
    done
}

# Compiler flags that keep build-machine paths out of the binaries.
prefix_maps() {
    for MAP in "$FFMPEG_SOURCE=/ffmpeg-source" "$WORK/$PROFILE/ffmpeg-build/$SLICE=/ffmpeg-build/$SLICE" \
        "$DAV1D_SOURCE=/dav1d-source" "$WORK/$PROFILE/dav1d-build/$SLICE=/dav1d-build/$SLICE" \
        "$WORK/$PROFILE/dav1d-stage/$SLICE=/dav1d-stage/$SLICE"; do
        printf ' -ffile-prefix-map=%s -fmacro-prefix-map=%s -fdebug-prefix-map=%s' "$MAP" "$MAP" "$MAP"
    done
}

build_dav1d() {
    DAV1D_BUILD="$WORK/$PROFILE/dav1d-build/$SLICE"
    DAV1D_STAGE="$WORK/$PROFILE/dav1d-stage/$SLICE"
    rm -rf "$DAV1D_BUILD" "$DAV1D_STAGE"
    mkdir -p "$DAV1D_BUILD.cross"
    if [ "$ARCH" = x86_64 ]; then CPU_FAMILY=x86_64; NASM_LINE="nasm = '$(command -v nasm)'"; else CPU_FAMILY=aarch64; NASM_LINE=''; fi
    C_ARGS=$(for MAP in "$DAV1D_SOURCE=/dav1d-source" "$DAV1D_BUILD=/dav1d-build/$SLICE"; do
        printf "'-ffile-prefix-map=%s', '-fmacro-prefix-map=%s', '-fdebug-prefix-map=%s', " "$MAP" "$MAP" "$MAP"; done)
    cat > "$DAV1D_BUILD.cross/cross.ini" <<EOF
[binaries]
c = ['$CLANG', '-target', '$TRIPLE', '-isysroot', '$SDK_PATH']
ar = '$AR'
strip = '$STRIP'
pkg-config = '/usr/bin/false'
$NASM_LINE

[host_machine]
system = 'darwin'
cpu_family = '$CPU_FAMILY'
cpu = '$ARCH'
endian = 'little'

[properties]
needs_exe_wrapper = true

[built-in options]
default_library = 'static'
buildtype = 'release'
b_staticpic = true
c_args = [${C_ARGS%, }]
EOF
    meson setup "$DAV1D_BUILD" "$DAV1D_SOURCE" --cross-file "$DAV1D_BUILD.cross/cross.ini" \
        --prefix=/ --libdir=lib --includedir=include -Dbitdepths=8,16 -Denable_tools=false \
        -Denable_examples=false -Denable_tests=false -Denable_docs=false \
        -Dtestdata_tests=false -Dlogging=true > "$DAV1D_BUILD.cross/setup.log" 2>&1 || {
        cat "$DAV1D_BUILD.cross/setup.log" >&2; die "dav1d configure failed for $SLICE"; }
    meson compile -C "$DAV1D_BUILD" > "$DAV1D_BUILD.cross/build.log" 2>&1 || die "dav1d build failed for $SLICE"
    DESTDIR="$DAV1D_STAGE" meson install -C "$DAV1D_BUILD" --no-rebuild > /dev/null
}

# The configuration avformat_configuration() reports, with the build
# machine's tools and paths replaced by placeholders.
summary_configuration() {
    printf '%s' "--prefix=/ --cc=<xcode-clang> --ar=<xcode-ar> --ranlib=<xcode-ranlib> --nm=<xcode-nm> --strip=<xcode-strip> --pkg-config=<pkg-config> --arch=$ARCH --target-os=darwin --sysroot=<apple-sdk> --target-triple=$TRIPLE --file-prefix-map=<source-and-build-paths>"
    [ "$ARCH" != x86_64 ] || printf ' %s' --disable-x86asm
    for FLAG in $(configure_flags); do printf ' %s' "$FLAG"; done
}

build_ffmpeg() {
    BUILD="$WORK/$PROFILE/ffmpeg-build/$SLICE"
    STAGE="$WORK/$PROFILE/ffmpeg-stage/$SLICE"
    PC_DIR="$WORK/$PROFILE/pkgconfig/$SLICE"
    rm -rf "$BUILD" "$STAGE" "$PC_DIR"
    mkdir -p "$BUILD" "$STAGE" "$PC_DIR"
    XML_HEADER="$SDK_PATH/usr/include/libxml2/libxml/xmlversion.h"
    XML_VERSION=$(sed -n 's/^#define LIBXML_DOTTED_VERSION "\([^"]*\)"/\1/p' "$XML_HEADER" | sed -n 1p)
    printf '%s\n' 'Name: libXML' 'Description: Apple SDK system libxml2' "Version: $XML_VERSION" \
        'Libs: -lxml2' "Cflags: -isystem$SDK_PATH/usr/include/libxml2" > "$PC_DIR/libxml-2.0.pc"
    set -- "$FFMPEG_SOURCE/configure" --prefix=/ "--cc=$CLANG" "--ar=$AR" "--ranlib=$RANLIB" \
        "--nm=$NM" "--strip=$STRIP" "--pkg-config=$(command -v pkg-config)" "--arch=$ARCH" \
        --target-os=darwin "--sysroot=$SDK_PATH" \
        "--extra-cflags=-target $TRIPLE$(prefix_maps)" "--extra-ldflags=-target $TRIPLE"
    [ "$ARCH" != x86_64 ] || set -- "$@" --disable-x86asm
    for FLAG in $(configure_flags); do set -- "$@" "$FLAG"; done
    (cd "$BUILD" && PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$DAV1D_STAGE/lib/pkgconfig:$PC_DIR" \
        PKG_CONFIG_SYSROOT_DIR="$DAV1D_STAGE" "$@") > "$BUILD.configure.log" 2>&1 || {
        tail -30 "$BUILD.configure.log" >&2; die "FFmpeg configure failed for $SLICE"; }
    SUMMARY=$(summary_configuration)
    for FILE in config.h ffbuild/config.mak; do
        awk -v summary="$SUMMARY" '
            $1 == "#define" && $2 == "FFMPEG_CONFIGURATION" { print "#define FFMPEG_CONFIGURATION \"" summary "\""; next }
            /^FFMPEG_CONFIGURATION=/ { print "FFMPEG_CONFIGURATION=" summary; next }
            { print }' "$BUILD/$FILE" > "$BUILD/$FILE.new"
        mv "$BUILD/$FILE.new" "$BUILD/$FILE"
    done
    make -C "$BUILD" -j "$JOBS" > "$BUILD.make.log" 2>&1 || { tail -30 "$BUILD.make.log" >&2; die "FFmpeg build failed for $SLICE"; }
    make -C "$BUILD" DESTDIR="$STAGE" install-libs > /dev/null
    libtool -static -o "$STAGE/merged.a" "$STAGE/lib/libavformat.a" "$STAGE/lib/libavcodec.a" \
        "$STAGE/lib/libswresample.a" "$STAGE/lib/libswscale.a" "$STAGE/lib/libavutil.a" \
        "$DAV1D_STAGE/lib/libdav1d.a" > "$BUILD.merge.log" 2>&1
}

# Renames every defined global of the merged archive to gpff_<name>, and
# writes the export list: the renamed public API.
prefix_and_list_exports() {
    nm -arch "$ARCH" -g "$STAGE/merged.a" > "$STAGE/globals.nm"
    if awk '!/:$/ && NF == 3 && $1 ~ /^[0-9a-f]+$/ && $2 != "U" && $3 !~ /^_/' "$STAGE/globals.nm" | grep . >/dev/null; then
        die "$SLICE defines globals without the Mach-O underscore, which cannot be renamed"
    fi
    awk -v pfx="_$PREFIX" '!/:$/ && NF == 3 && $2 != "U" && $3 ~ /^_/ && index($3, pfx) != 1 { print $3 }' \
        "$STAGE/globals.nm" | sort -u | awk -v pfx="$PREFIX" '{ print $0, "_" pfx substr($0, 2) }' > "$STAGE/rename.txt"
    "$OBJCOPY" --redefine-syms="$STAGE/rename.txt" "$STAGE/merged.a" "$STAGE/prefixed.a"
    nm -arch "$ARCH" -g -U "$STAGE/prefixed.a" | awk '!/:$/ && NF == 3 && $2 != "U" { print $3 }' | sort -u \
        | awk -v pfx="_$PREFIX" -v re="$EXPORT_PATTERN" 'index($0, pfx) == 1 && substr($0, length(pfx) + 1) ~ re' \
        > "$STAGE/exports.txt"
}

link_lane() {
    if [ "$PLATFORM" = macos ]; then BINARY_PATH="$NAME.framework/Versions/A/$NAME"; else BINARY_PATH="$NAME.framework/$NAME"; fi
    "$CLANG" -target "$TRIPLE" -isysroot "$SDK_PATH" -dynamiclib \
        -Wl,-force_load,"$STAGE/prefixed.a" \
        -install_name "@rpath/$BINARY_PATH" \
        -compatibility_version 1.0.0 -current_version "$FFMPEG_VERSION" \
        -Wl,-exported_symbols_list,"$STAGE/exports.txt" \
        -Wl,-dead_strip -Wl,-headerpad_max_install_names -Wl,-application_extension \
        -framework CoreFoundation -framework Security -lxml2 \
        -o "$STAGE/$NAME" > "$STAGE/link.log" 2>&1 || { cat "$STAGE/link.log" >&2; die "linking $SLICE failed"; }
}

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
<key>CFBundleShortVersionString</key><string>$FFMPEG_VERSION</string>
<key>CFBundleSupportedPlatforms</key><array><string>$SUPPORTED</string></array>
<key>CFBundleVersion</key><string>$BUNDLE_VERSION</string>
$EXTRA
</dict>
</plist>
EOF
    plutil -lint "$1" > /dev/null
}

# Combines a variant's lanes into one stripped, ad hoc signed framework.
assemble_variant() {
    VARIANT_DIR="$WORK/$PROFILE/variants/$1"
    shift
    set --
    for LANE in $VARIANT_LANES; do set -- "$@" "$WORK/$PROFILE/ffmpeg-stage/$LANE/$NAME"; done
    rm -rf "$VARIANT_DIR"
    mkdir -p "$VARIANT_DIR"
    if [ "$#" -eq 1 ]; then cp "$1" "$VARIANT_DIR/$NAME.bin"; else lipo -create "$@" -output "$VARIANT_DIR/$NAME.bin"; fi
    xcrun strip -x "$VARIANT_DIR/$NAME.bin"
    FRAMEWORK="$VARIANT_DIR/$NAME.framework"
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
}

prepare_sources
for SLICE in $SLICES; do
    slice_info "$SLICE"
    note "building $SLICE ($PROFILE)"
    SDK_PATH=$(xcrun --sdk "$SDK" --show-sdk-path)
    CLANG=$(xcrun --sdk "$SDK" --find clang)
    AR=$(xcrun --sdk "$SDK" --find ar)
    RANLIB=$(xcrun --sdk "$SDK" --find ranlib)
    NM=$(xcrun --sdk "$SDK" --find nm)
    STRIP=$(xcrun --sdk "$SDK" --find strip)
    build_dav1d
    build_ffmpeg
    prefix_and_list_exports
    link_lane
done

XCFRAMEWORK_ARGS=''
for VARIANT in 'ios-device:ios-arm64' 'ios-simulator:iossim-arm64 iossim-x86_64' 'tvos-device:tvos-arm64' \
    'tvos-simulator:tvossim-arm64 tvossim-x86_64' 'macos:macos-arm64 macos-x86_64'; do
    VARIANT_LANES=''
    for LANE in ${VARIANT#*:}; do
        [ -f "$WORK/$PROFILE/ffmpeg-stage/$LANE/$NAME" ] || continue
        case " $SLICES " in *" $LANE "*) VARIANT_LANES="$VARIANT_LANES $LANE" ;; esac
    done
    [ -n "$VARIANT_LANES" ] || continue
    slice_info $VARIANT_LANES
    assemble_variant "${VARIANT%%:*}"
done
[ -n "$XCFRAMEWORK_ARGS" ] || die 'no slice was built'
mkdir -p "$OUT/$PROFILE"
rm -rf "$OUT/$PROFILE/$NAME.xcframework"
# shellcheck disable=SC2086
xcodebuild -create-xcframework $XCFRAMEWORK_ARGS -output "$OUT/$PROFILE/$NAME.xcframework" > /dev/null
note "wrote $OUT/$PROFILE/$NAME.xcframework"
