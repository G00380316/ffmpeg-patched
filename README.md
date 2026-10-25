# ffmpeg-patched

The corresponding source of two LGPL-2.1 libraries that an iOS, tvOS and
macOS app ships as dynamic frameworks, and the scripts that build an
interface-compatible replacement for each, so a recipient of the app can
modify a library and use their own build of it.

| Framework | Library | Source |
| --- | --- | --- |
| `GPlayerFFmpegBinary.framework` | FFmpeg 9.0.2 with the five changes below, and dav1d 1.5.4 linked in | `ffmpeg/`, `patches/`, `build-ffmpeg.sh` |
| `GPlayerFriBidiBinary.framework` | GNU FriBidi 1.0.16, unmodified | `build-fribidi.sh` (fetches the release) |

## What is here

- `ffmpeg/` is FFmpeg 9.0.2. The history shows exactly what changed: the first
  commit is the release tarball
  (`https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz`, SHA-256
  `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`)
  unchanged, and each following commit applies one patch.
- `patches/` holds the five patches and `manifest.json`, which records for
  each the file it changes and the SHA-256 of the patch, of that file as
  released and of the file once patched.
- `build-ffmpeg.sh` and `build-fribidi.sh` build the frameworks.
- `LICENSE` and `licenses/` hold the licence pointers and texts.

## The changes to FFmpeg

All five are in libavformat, and each applies with `patch -p1 --fuzz=0` to the
released file.

1. **`hls-retain-initialization.patch`** (`libavformat/hls.c`). Retain bounded
   HLS initialization maps; use consistent seek/packet timestamp rounding;
   expose the first demux timestamp read-only (the `first_demux_timestamp`
   option) for native seek bounds; keep 8.1's one byte range and one input per
   segment and one playlist per reference, and leave an EVENT playlist's
   duration unset until it ends and its streams' start time to FFmpeg's
   ordinary rule.
2. **`dash-optional-representation-attributes.patch`** (`libavformat/dashdec.c`).
   Do not dereference a Representation's absent id or codecs when grouping
   dependent video, nor free its attribute strings twice when copying them
   fails, both new in 9.0; keep a representation that reaches its end open, as
   8.1 did, and skipped while the others play on until a seek moves it; close
   at a seek one no longer wanted rather than reopen it, and put a closed one
   that is a whole file where a seek wanted it when it reopens; report an
   interrupted read instead of returning no packet, which 9.0 asked for again
   for ever when the first stream had a parser; and leave generic seeking off,
   as for HLS.
3. **`http-chunked-end-of-body.patch`** (`libavformat/http.c`). End a complete
   chunked response with EOF rather than EIO when its connection is not kept,
   as 8.1 did, keeping a size Content-Range already gave. When a seek's or
   reconnect's request fails and the old connection goes on, restore what the
   old response said of its body (its size, range end, chunk state, whether it
   closes, its ICY metadata interval and position, and whether it can seek),
   which the new request reset or its refusal's headers set: a refusal stating
   `Content-Length: 0` had ended a live stream at the next read. Keep the
   headers, referer and cookies a context was given to the origin they were
   given for (the `credentials_origin` option, by default the first URL's) on
   redirects and on requests made on a kept connection, and each cookie a
   response sets to that response's origin. A request whose redirects left that
   origin gets none of them, back on it included, and so does every request of
   a context given `credentials_withheld`, for opening where such redirects
   ended, which `left_credentials_origin` exports. A cookie set on a response to
   a request made without them is marked, and goes back to its origin on such a
   return where the origin's others do not: FFmpeg's HLS and DASH demuxers give
   every open the whole of the playlist's, whatever origin it names, and a
   redirect carried them to any origin.
4. **`matroska-chapter-languages.patch`** (`libavformat/matroskadec.c`). Keep
   each of a Matroska chapter's names with its language, which 9.0 read into
   one field and dropped the languages of, the last name winning: the chapter's
   title is still that last name, and each name in a language is kept as
   `title-<language>` in the chapter's metadata, as tags in a language are,
   ChapLanguageBCP47 before ChapLanguage, a name in `und` left out, so a player
   can show the chapters in its viewer's language.
5. **`movenc-eac3-dependent-substreams.patch`** (`libavformat/movenc.c`). Write
   a dependent E-AC-3 substream into `dec3` as Apple's player reads it: chan_loc
   bit k is chanmap location k + 5 (Lc/Rc to Cvh) and bit 8 is LFE2 (location
   14), where 9.0 wrote the chanmap shifted by five and five bits wide, and a
   dependent substream without a chanmap adds none, where 9.0 added its coding
   mode; take the JOC complexity of Atmos signalled in a dependent substream,
   which 9.0 never read and an independent frame without it cleared on every
   packet; and count the dependent substreams' rate in `data_rate`. 7.1 and
   dependent-substream Atmos were otherwise described as 5.1.

## Building

On a Mac with Xcode and its iOS, tvOS and macOS SDKs, and these tools:

```sh
brew install meson ninja nasm pkg-config llvm   # llvm provides llvm-objcopy
```

Then, from this directory (its path must not contain spaces):

```sh
./build-ffmpeg.sh                     # writes out/compatibility-remux/GPlayerFFmpegBinary.xcframework
./build-fribidi.sh                    # writes out/GPlayerFriBidiBinary.xcframework
```

`build-ffmpeg.sh` builds all eight lanes by default: iOS and tvOS devices
(arm64), their simulators (arm64, x86_64) and macOS (arm64, x86_64), for iOS
and tvOS 15.0 and macOS 12.0. `--slice macos-arm64` (repeatable) builds only
the lanes named, `--jobs N` sets make's parallelism, and `--from-tarball`
builds from the verified release tarball with `patches/` applied instead of
from `ffmpeg/`. dav1d 1.5.4 is fetched from
`https://code.videolan.org/videolan/dav1d/-/archive/1.5.4/dav1d-1.5.4.tar.bz2`
and checked against SHA-256
`2abfb0c89212e6e4733a54e0ae509ec00a5b845a6360946f918806e14aedb011`; FriBidi
1.0.16 from
`https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz`,
SHA-256 `1b1cde5b235d40479e91be2f0e88a309e3214c8ab470ec8a2744d82a5a9ea05c`.

FFmpeg is configured with every component off except those the app uses (the
list is in `configure_flags` in `build-ffmpeg.sh`), with no GPL, nonfree or
version 3 code. There are two profiles. `compatibility-remux`, the default,
adds the MP4 muxer (`--disable-iamf --enable-muxer=mp4`); `playback`
(`--profile playback`) decodes only. To see which one an app ships:

```sh
strings GPlayerFFmpegBinary.framework/GPlayerFFmpegBinary | grep -c -- --enable-muxer=mp4
```

A count above zero means `compatibility-remux`.

### The interface a replacement keeps

The app was linked against these, so a replacement must keep them; the scripts
do.

- The framework and binary names, `GPlayerFFmpegBinary` and
  `GPlayerFriBidiBinary`.
- The install names: `@rpath/GPlayerFFmpegBinary.framework/GPlayerFFmpegBinary`
  on iOS and tvOS and `@rpath/GPlayerFFmpegBinary.framework/Versions/A/GPlayerFFmpegBinary`
  on macOS, and likewise for `GPlayerFriBidiBinary`.
- Compatibility version 1.0.0.
- For FFmpeg, every global symbol renamed with the prefix `gpff_` (so
  `av_read_frame` is `gpff_av_read_frame`), so that it cannot collide with
  another FFmpeg in the same app, and only FFmpeg's public API exported: names
  beginning `av` (`avpriv_` among them), `swr_`, `swresample_`, `sws_` and
  `swscale_`. The script renames with `llvm-objcopy --redefine-syms` before
  linking, and links with that export list.
- For FriBidi, its own `fribidi_*` API, unchanged and alone.

To check a build against the framework in an app, compare their exported
symbols, install names and load commands; all three should be identical:

```sh
SHIPPED=<App>.app/Frameworks/GPlayerFFmpegBinary.framework/GPlayerFFmpegBinary
BUILT=out/compatibility-remux/GPlayerFFmpegBinary.xcframework/ios-arm64/GPlayerFFmpegBinary.framework/GPlayerFFmpegBinary
nm -gU -arch arm64 "$SHIPPED" | awk '{ print $3 }' > shipped.txt
nm -gU -arch arm64 "$BUILT" | awk '{ print $3 }' > built.txt
diff shipped.txt built.txt
otool -D "$SHIPPED"; otool -D "$BUILT"
otool -L "$SHIPPED"; otool -L "$BUILT"
```

## Replacing a framework in an app

The app loads each framework from its own bundle at launch by the install name
above. To run the app with your build:

1. Take the variant of your xcframework that matches where the app runs:
   `ios-arm64` for an iPhone or iPad, `ios-arm64_x86_64-simulator` for the
   simulator, `tvos-arm64` for an Apple TV, `macos-arm64_x86_64` for a Mac.
2. Replace the framework folder of the same name inside the app:
   `Payload/<App>.app/Frameworks/GPlayerFFmpegBinary.framework` in an iOS or
   tvOS app (unpack the `.ipa` first), or
   `<App>.app/Contents/Frameworks/GPlayerFFmpegBinary.framework` on macOS.
   Replace the whole folder, keeping its name.
3. Re-sign, inside out, with your own signing identity: the replaced
   framework, then the app.

   ```sh
   codesign -d --entitlements :- <App>.app > entitlements.plist
   codesign --force --sign "<your identity>" --timestamp <App>.app/Frameworks/GPlayerFFmpegBinary.framework
   codesign --force --sign "<your identity>" --entitlements entitlements.plist --timestamp <App>.app
   ```

   On macOS, use `Contents/Frameworks/...`, and add `--options runtime` if the
   app used the hardened runtime. For an iOS or tvOS device, replace
   `embedded.mobileprovision` with a provisioning profile of your own that
   matches your identity and the app's identifier, adjust the entitlements to
   your team, re-sign, and install the app with Xcode's Devices window or
   `xcrun devicectl device install app --device <device> <App>.app`.
4. Check the app loads your build: on macOS,
   `DYLD_PRINT_LIBRARIES=1 <App>.app/Contents/MacOS/<App>` lists the framework
   paths it loads.

Apple platforms only run code signed by its installer, so the replacement has
to be signed by you; never put private keys, provisioning profiles or account
secrets in anything you share. The app does not download or execute a
replacement itself: replacing a framework is something you do to your own
copy, as described here.

## Licences

- FFmpeg is licensed under the GNU Lesser General Public License version 2.1
  or later: see `ffmpeg/COPYING.LGPLv2.1` and `ffmpeg/LICENSE.md`. The
  configuration disables FFmpeg's GPL, nonfree and version 3 components.
- dav1d, linked into the FFmpeg framework, is under the BSD 2-Clause licence:
  `licenses/dav1d-COPYING`.
- GNU FriBidi is licensed under the GNU Lesser General Public License version
  2.1 or later: `licenses/fribidi-COPYING`.
- The build scripts and this README are under the MIT License. It covers
  only those files: using, changing or distributing FFmpeg, its patches or
  FriBidi is governed by their own licences above.

See `LICENSE`.
