#!/usr/bin/env bash
#
# Copyright 2015 Brian Smith.
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND AND THE AUTHORS DISCLAIM ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY
# SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION
# OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
# CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

set -eux -o pipefail
IFS=$'\n\t'

printenv

case $TARGET_X in
aarch64-unknown-linux-gnu)
  export QEMU_LD_PREFIX=/usr/aarch64-linux-gnu
  ;;
arm-unknown-linux-gnueabihf)
  export QEMU_LD_PREFIX=/usr/arm-linux-gnueabihf
  ;;
aarch64-linux-android)
  ANDROID_ARCH=arm64
  ANDROID_ABI=arm64-v8a
  ANDROID_API=21
  ANDROID_SYS_IMG_API=24
  ;;
armv7-linux-androideabi)
  ANDROID_ARCH=arm
  ANDROID_ABI=armeabi-v7a
  ANDROID_API=18
  ANDROID_SYS_IMG_API=18
  ;;
*)
  ;;
esac

if [[ "$TARGET_X" =~ android ]]; then
  # install the android sdk/ndk
  mk/travis-install-android.sh --arch ${ANDROID_ARCH} \
                               --api-level ${ANDROID_API} \
                               --abi-name ${ANDROID_ABI} \
                               --sys-img-api-level ${ANDROID_SYS_IMG_API} \
                               --rust-target ${TARGET_X}

  export PATH=$HOME/android/android-ndk/bin:$PATH
  export PATH=$HOME/android/android-sdk-linux/platform-tools:$PATH
  export PATH=$HOME/android/android-sdk-linux/tools:$PATH
fi

if [[ "$TARGET_X" =~ ^(arm|aarch64) && ! "$TARGET_X" =~ android ]]; then
  # We need a newer QEMU than Travis has.
  # sudo is needed until the PPA and its packages are whitelisted.
  # See https://github.com/travis-ci/apt-source-whitelist/issues/271
  sudo add-apt-repository ppa:pietro-monteiro/qemu-backport -y
  sudo apt-get update -qq
  sudo apt-get install --no-install-recommends binfmt-support qemu-user-binfmt -y
fi

if [[ ! "$TARGET_X" =~ "x86_64-" ]]; then
  rustup target add "$TARGET_X"

  # By default cargo/rustc seems to use cc for linking, We installed the
  # multilib support that corresponds to $CC_X and $CXX_X but unless cc happens
  # to match $CC_X, that's not the right version. The symptom is a linker error
  # where it fails to find -lgcc_s.
  if [[ ! -z "${CC_X-}" ]]; then
    mkdir .cargo
    echo "[target.$TARGET_X]" > .cargo/config
    echo "linker= \"$CC_X\"" >> .cargo/config
    cat .cargo/config
  fi
fi

if [[ ! -z "${CC_X-}" ]]; then
  export CC=$CC_X
  $CC --version
else
  cc --version
fi
if [[ ! -z "${CXX_X-}" ]]; then
  export CXX=$CXX_X
  $CXX --version
else
  c++ --version
fi

cargo version
rustc --version

if [[ "$MODE_X" == "RELWITHDEBINFO" ]]; then
  mode=--release
  target_dir=target/$TARGET_X/release
else
  target_dir=target/$TARGET_X/debug
fi

case $TARGET_X in
*-linux-android*)
  cargo test -vv -j2 --no-run ${mode-} ${FEATURES_X-} --target=$TARGET_X

  # Building the AVD is slow. Do it here, after we build the code so that any
  # build breakage is reported sooner, instead of being delayed by this.
  echo no | android create avd --name test --target "android-${ANDROID_SYS_IMG_API}"
  android list avd

  emulator @test -memory 2048 -no-skin -no-boot-anim -no-window &
  adb wait-for-device
  adb root
  adb wait-for-device

  # Run the unit tests first.
  adb push $target_dir/ring-* /data/ring-test
  for testfile in `find src crypto -name "*_test*.txt" -o -name "*test*.pk8"`; do
    adb shell mkdir -p /data/`dirname $testfile`
    adb push $testfile /data/$testfile
  done
  adb shell mkdir -p /data/third-party/NIST
  adb push third-party/NIST/SHAVS /data/third-party/NIST/SHAVS
  adb shell "cd /data && ./ring-test" 2>&1 | tee /tmp/ring-test-log
  grep "test result: ok" /tmp/ring-test-log

  # Run the integration/functional tests.
  for testfile in `find tests -name "*_test*.txt" -o -name "*test*.pk8"`; do
    adb shell mkdir -p /data/`dirname $testfile`
    adb push $testfile /data/$testfile
  done
  find $target_dir -maxdepth 1 -name "*test*" -type f
  for test_exe in `find $target_dir -maxdepth 1 -name "*test*" -type f`; do
    adb push $test_exe /data/`basename $test_exe`
    adb shell "cd /data && ./`basename $test_exe`" 2>&1 | \
        tee /tmp/`basename $test_exe`-log
    grep "test result: ok" /tmp/`basename $test_exe`-log
  done
  ;;
*)
  cargo test -vv -j2 ${mode-} ${FEATURES_X-} --target=$TARGET_X
  ;;
esac

if [[ "$KCOV" == "1" ]]; then
  # kcov reports coverage as a percentage of code *linked into the executable*
  # (more accurately, code that has debug info linked into the executable), not
  # as a percentage of source code. Thus, any code that gets discarded by the
  # linker due to lack of usage isn't counted at all. Thus, we have to re-link
  # with "-C link-dead-code" to get accurate code coverage reports.
  # Alternatively, we could link pass "-C link-dead-code" in the "cargo test"
  # step above, but then "cargo test" we wouldn't be testing the configuration
  # we expect people to use in production.
  cargo clean
  RUSTFLAGS="-C link-dead-code" \
    cargo test -vv --no-run -j2  ${mode-} ${FEATURES_X-} --target=$TARGET_X
  mk/travis-install-kcov.sh
  for test_exe in `find target/$TARGET_X/debug -maxdepth 1 -executable -type f`; do
    ${HOME}/kcov-${TARGET_X}/bin/kcov \
      --verify \
      --coveralls-id=$TRAVIS_JOB_ID \
      --exclude-path=/usr/include \
      --include-pattern="ring/crypto,ring/src,ring/tests" \
      target/kcov \
      $test_exe
  done
fi

# Verify that `cargo build`, independent from `cargo test`, works; i.e. verify
# that non-test builds aren't trying to use test-only features. For platforms
# for which we don't run tests, this is the only place we even verify that the
# code builds.
cargo build -vv -j2 ${mode-} ${FEATURES_X-} --target=$TARGET_X

echo end of mk/travis.sh