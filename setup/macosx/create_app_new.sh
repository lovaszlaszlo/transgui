#!/bin/sh

set -ex

lazarus_dir="${1:-/Applications/Lazarus/}"
lazbuild_bin="$lazarus_dir/lazbuild"
if [ "${lazarus_dir%/}" != "/Applications/Lazarus" ] && [ ! -x "$lazbuild_bin" ]; then
  echo "Unable to find lazbuild at $lazbuild_bin." >&2
  exit 1
fi

prog_ver="$(cat ../../VERSION.txt)"
build="$(git rev-list --abbrev-commit --max-count=1 HEAD ../..)"

# Target architecture: x86_64 (default on Intel) or arm64 (default on Apple Silicon).
target_arch="${TRANSGUI_ARCH:-$(uname -m)}"
case "$target_arch" in
  arm64 | aarch64)
    target_arch=arm64
    target_cpu=aarch64
    dmg_suffix="-arm64"
    ;;
  x86_64)
    target_cpu=x86_64
    dmg_suffix=""
    ;;
  *)
    echo "Unsupported target architecture: $target_arch" >&2
    exit 1
    ;;
esac

# Code signing identity for the arm64 package. The default is an ad hoc signature,
# which gives every build a new identity: macOS then evaluates its privacy
# permissions (such as local network access) again on the first launch.
# Set TRANSGUI_SIGN_IDENTITY to the name of a certificate to keep them.
sign_identity="${TRANSGUI_SIGN_IDENTITY:--}"

# install_deps.sh installs the Intel toolchain only. For arm64 install FPC and
# Lazarus yourself and pass the Lazarus directory as the first argument.
if [ -z "${CI-}" ] && [ "$target_arch" = "x86_64" ]; then
  ./install_deps.sh
fi

fpc_bin="${FPC:-/usr/local/bin/fpc}"
if [ ! -x "$fpc_bin" ] && [ "$target_arch" = "arm64" ]; then
  fpc_bin="$(command -v fpc || :)"
fi
if [ ! -x "$fpc_bin" ]; then
  echo "Unable to find fpc at $fpc_bin." >&2
  exit 1
fi
fpc_ver="Free Pascal Compiler version $("$fpc_bin" -iV)"
exename=../../transgui
appname="Transmission Remote GUI"
dmg_dist_file="../../Release/transgui-$prog_ver$dmg_suffix.dmg"
dmg_temp_file="$dmg_dist_file.tmp.dmg"
dmgfolder=./Release
appfolder="$dmgfolder/$appname.app"
if [ ! -x "$lazbuild_bin" ]; then
  echo "Unable to find lazbuild at $lazbuild_bin." >&2
  exit 1
fi
lazarus_ver="$("$lazbuild_bin" -v)"
mount_device=""
remove_dmg_temp=0
remove_dmgfolder=0
remove_tmp_dmg=0
lazarus_pcp=""

detach_disk_image() {
  detach_device=$1
  detach_attempt=1

  sync
  while ! hdiutil detach "$detach_device"; do
    if [ "$detach_attempt" -ge 5 ]; then
      echo "Failed to detach $detach_device after $detach_attempt attempts." >&2
      return 1
    fi

    echo "Failed to detach $detach_device; retrying in 2 seconds." >&2
    sleep 2
    detach_attempt=$((detach_attempt + 1))
  done
}

cleanup() {
  status=$?
  cleanup_status=0

  trap '' HUP INT TERM
  trap - 0
  set +e

  if [ -n "$mount_device" ]; then
    detach_status=0
    detach_disk_image "$mount_device" || detach_status=$?
    if [ "$detach_status" -eq 0 ]; then
      mount_device=""
    else
      cleanup_status=$detach_status
      remove_tmp_dmg=0
    fi
  fi
  if [ "$remove_dmg_temp" -eq 1 ]; then
    rm -f "$dmg_temp_file" || cleanup_status=$?
  fi
  if [ "$remove_tmp_dmg" -eq 1 ]; then
    rm -f tmp.dmg || cleanup_status=$?
  fi
  if [ "$remove_dmgfolder" -eq 1 ]; then
    rm -rf "$dmgfolder" || cleanup_status=$?
  fi
  if [ -e ../../about.lfm.bak ]; then
    mv ../../about.lfm.bak ../../about.lfm || cleanup_status=$?
  fi
  if [ -n "$lazarus_pcp" ]; then
    rm -rf "$lazarus_pcp" || :
  fi

  if [ "$status" -eq 0 ]; then
    status=$cleanup_status
  fi
  exit "$status"
}

if [ ! "$lazarus_dir" = "" ]; then
  lazdir=LAZARUS_DIR="$lazarus_dir"
fi

if [ -e ../../about.lfm.bak ]; then
  echo "../../about.lfm.bak already exists; refusing to overwrite it." >&2
  exit 1
fi
if [ -e "$dmg_dist_file" ] && [ ! -f "$dmg_dist_file" ]; then
  echo "$dmg_dist_file exists and is not a regular file." >&2
  exit 1
fi
if [ -e "$dmg_temp_file" ] && [ ! -f "$dmg_temp_file" ]; then
  echo "$dmg_temp_file exists and is not a regular file." >&2
  exit 1
fi

trap cleanup 0
trap 'exit 1' HUP INT TERM

lazarus_pcp="$(mktemp -d "${TMPDIR:-/tmp}/transgui-lazarus-pcp.XXXXXX")" || exit 1

cleanup_lazbuild_state() {
  rm -rf ../../units ../../lib
  mkdir -p ../../units ../../lib "$lazarus_pcp"
}

run_lazbuild() {
  cleanup_lazbuild_state
  "$lazbuild_bin" -B ../../trcomp.lpk --lazarusdir="$lazarus_dir" --compiler="$fpc_bin" --cpu="$target_cpu" --widgetset=cocoa --pcp="$lazarus_pcp"
  # shellcheck disable=SC2086
  "$lazbuild_bin" -B ../../transgui.lpi --lazarusdir="$lazarus_dir" --compiler="$fpc_bin" --cpu="$target_cpu" --widgetset=cocoa --pcp="$lazarus_pcp" $lazbuild_opts
}

# Copies OpenSSL 3 into the application bundle, so HTTPS works without Homebrew.
bundle_openssl() {
  openssl_lib="${OPENSSL_LIB_DIR:-$(brew --prefix openssl@3 2> /dev/null || :)/lib}"
  if [ ! -f "$openssl_lib/libssl.3.dylib" ] || [ ! -f "$openssl_lib/libcrypto.3.dylib" ]; then
    echo "OpenSSL 3 was not found in $openssl_lib; the application will look for it at run time." >&2
    return 0
  fi

  frameworks="$appfolder/Contents/Frameworks"
  mkdir -p "$frameworks"
  cp -L "$openssl_lib/libssl.3.dylib" "$openssl_lib/libcrypto.3.dylib" "$frameworks"
  chmod u+w "$frameworks/libssl.3.dylib" "$frameworks/libcrypto.3.dylib"
  crypto_ref="$(otool -L "$frameworks/libssl.3.dylib" | awk '/libcrypto\.3\.dylib/ {print $1; exit}')"
  install_name_tool -id @loader_path/libcrypto.3.dylib "$frameworks/libcrypto.3.dylib"
  install_name_tool -id @loader_path/libssl.3.dylib \
    -change "$crypto_ref" @loader_path/libcrypto.3.dylib "$frameworks/libssl.3.dylib"
  codesign --force --sign "$sign_identity" "$frameworks/libcrypto.3.dylib" "$frameworks/libssl.3.dylib"
}

mkdir -p ../../Release/
sed -i.bak "s/'Version %s'/'Version %s Build $build'#13#10'Compiled by: $fpc_ver, Lazarus v$lazarus_ver'/" ../../about.lfm

if [ "$target_arch" = "arm64" ]; then
  # FPC 3.2.2 emits Objective-C metadata the current Apple linker rejects
  # ("malformed method list atom"), so the classic linker is required.
  # Its size optimizer (-Os, "SmallerCode" in transgui.lpi) miscompiles aarch64 code:
  # the application halts with exit code 255 while painting. Use plain -O1 instead.
  lazbuild_opts="--opt=-k-ld_classic --opt=-O- --opt=-O1"
  run_lazbuild
  # The tracked Makefile has no aarch64-darwin target; use the lazbuild output.
  cp ../../units/transgui "$exename"
else
  lazbuild_opts=""
  run_lazbuild

  # Building Intel version
  make -j"$(sysctl -n hw.ncpu)" -C ../.. clean CPU_TARGET=x86_64 FPC="$fpc_bin" "$lazdir"
  make -j"$(sysctl -n hw.ncpu)" -C ../.. CPU_TARGET=x86_64 FPC="$fpc_bin" "$lazdir"
fi

if ! [ -e $exename ]; then
  echo "$exename does not exist"
  exit 1
fi
strip "$exename"

remove_dmgfolder=1
rm -rf "$appfolder"

echo "Creating $appfolder..."
if [ "$target_arch" = "arm64" ]; then
  # Data files next to the executable cannot be sealed by the bundle signature.
  langfolder="$appfolder/Contents/Resources/lang"
else
  langfolder="$appfolder/Contents/MacOS/lang"
fi
mkdir -p "$appfolder/Contents/MacOS"
mkdir -p "$langfolder"
mkdir -p "$appfolder/Contents/Resources"

mv "$exename" "$appfolder/Contents/MacOS"
cp ../../lang/transgui.* "$langfolder"

cp ../../history.txt "$dmgfolder"
cp ../../README.md "$dmgfolder"

cp PkgInfo "$appfolder/Contents"
cp transgui.icns "$appfolder/Contents/Resources"
sed -e "s/@prog_ver@/$prog_ver/" Info.plist > "$appfolder/Contents/Info.plist"

if [ "$target_arch" = "arm64" ]; then
  bundle_openssl
  # Apple Silicon refuses to run unsigned code, and strip invalidates the linker signature.
  codesign --force --sign "$sign_identity" "$appfolder"
fi

ln -s /Applications "$dmgfolder/Drag \"Transmission Remote GUI\" here!"

hdiutil create -ov -anyowners -volname "transgui-v$prog_ver" -format UDRW -srcfolder ./Release -fs HFS+ "tmp.dmg"
remove_tmp_dmg=1

remove_tmp_dmg=0
attach_status=0
attach_output="$(hdiutil attach -readwrite -noautoopen "tmp.dmg")" || attach_status=$?
mount_device="$(printf '%s\n' "$attach_output" | awk 'NR == 1 && $1 ~ /^\/dev\/disk[0-9]+(s[0-9]+)*$/ {print $1}')"
if [ -z "$mount_device" ]; then
  echo "Failed to determine the mounted disk image device." >&2
  if [ "$attach_status" -ne 0 ]; then
    exit "$attach_status"
  fi
  exit 1
fi
remove_tmp_dmg=1
if [ "$attach_status" -ne 0 ]; then
  exit "$attach_status"
fi
mount_volume="$(printf '%s\n' "$attach_output" | awk -F '\t' 'NF >= 3 && $NF ~ /^\// {volume=$NF} END {print volume}')"
if [ -z "$mount_volume" ]; then
  echo "Failed to determine the mounted disk image volume." >&2
  exit 1
fi
cp transgui.icns "$mount_volume/.VolumeIcon.icns"
SetFile -c icnC "$mount_volume/.VolumeIcon.icns"
SetFile -a C "$mount_volume"

detach_disk_image "$mount_device"
mount_device=""
remove_dmg_temp=1
rm -f "$dmg_temp_file"
hdiutil convert tmp.dmg -format UDBZ -imagekey zlib-level=9 -o "$dmg_temp_file"
mv -f "$dmg_temp_file" "$dmg_dist_file"
remove_dmg_temp=0

if [ -z "${CI-}" ]; then
  open "$dmg_dist_file"
fi
