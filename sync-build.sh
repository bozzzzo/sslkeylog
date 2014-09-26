#!/bin/bash
# Detect a local change, sync to build machine and retrieve result when done. A
# notification is also send when the build is complete.
#
# Author: Peter Wu <peter@lekensteyn.nl>
#
# Recommendations:
# - ssh-agent (add keys before with ssh-add)
# - 2 GiB remote storage (builddir is 900 MiB, git tree is 486 MiB)
# - Gigabit link between working machine and build machine
# - Matching local + remote OS environments to avoid library mismatches.
#   In my case I run schroot to enter a chroot with matching libs (see
#   $remotecmd below).
# - libnotify for notifications when ready.

# LOCAL source dir (on non-volatile storage for reliability)
localsrcdir=$HOME/projects/wireshark/

# REMOTE
# REMOTE host, is a ssh alias that can be defined in ~/.ssh/config, e.g.:
# Host wireshark-builder
#    User foo
#    Hostname 10.42.0.1
remotehost=wireshark-builder
# Remote source dir, it can be volatile (tmpfs) since it is just a copy. On the
# local side, it is recommended to create a symlink to the localsrcdir for
# debugging purposes
remotesrcdir=/tmp/wireshark/
# Remote directory to generate objects, it must also be accessible locally for
# easier debugging (rpath)
builddir=/tmp/wsbuild/

# LOCAL & REMOTE program dir (Available since 1.11.x and 1.12.0)
rundir="$builddir/run/"

CC=${CC:-cc}
CXX=${CXX:-c++}
# For clang, `-O1` (or `-g`?) seems necessary to get something other than
# "<optimized out>".
# -O1 -g -gdwarf-4 -fsanitize=address -fsanitize=undefined -fno-omit-frame-pointer
CFLAGS=${CFLAGS:--fsanitize=address}
CXXFLAGS=${CXXFLAGS:--fsanitize=address}

LIBDIR=/usr/lib
# Run with `B32=1 ./sync-build.sh` to build for multilib
if [[ ${B32:-} ]]; then
    LIBDIR=/usr/lib32
    CFLAGS="$CFLAGS -m32"
    CXXFLAGS="$CXXFLAGS -m32"
fi

# PATH is needed for /usr/bin/core_perl/pod2man (PCAP)
# ENABLE_QT5=1: install qt5-tools on Arch Linux
# 32-bit libs on Arch: lib32-libcap lib32-gnutls lib32-gtk2 lib32-krb5
# lib32-portaudio  lib32-geoip lib32-libnl lib32-lua
remotecmd="schroot -c chroot:arch -- sh -c '
PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/bin/core_perl;
if [ ! -e $builddir/CMakeCache.txt ]; then
    mkdir -p $builddir && cd $builddir &&
    set -x &&
    time \
    CC=$CC CXX=$CXX \
    PKG_CONFIG_LIBDIR=$LIBDIR/pkgconfig \
    cmake \
        -DCMAKE_INSTALL_PREFIX=/tmp/wsroot \
        -DENABLE_GTK3=0 \
        -DENABLE_PORTAUDIO=1 \
        -DENABLE_QT5=1 \
        -DENABLE_GEOIP=1 \
        -DENABLE_KERBEROS=1 \
        -DENABLE_SBC=0 \
        -DENABLE_SMI=0 \
        -DENABLE_GNUTLS=1 \
        -DENABLE_GCRYPT=1 \
        -DCMAKE_BUILD_TYPE=Debug \
        $remotesrcdir \
        -DCMAKE_LIBRARY_PATH=$LIBDIR \
        -DCMAKE_C_FLAGS=$(printf %q "$CFLAGS") \
        -DCMAKE_CXX_FLAGS=$(printf %q "$CXXFLAGS") \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=1
fi &&
time make -C $builddir -j16
'"


# Touch this file to trigger a build.
sync=$(mktemp --tmpdir 'sync-build-XXXXXXXX')
monpid=
cleanup() {
    rm -f "$sync"
    [ -z "$monpid" ] || kill $monpid
}
trap cleanup EXIT

round=0
monitor_changes() {
    # Wait for changes, but ignore .git/ and vim swap files
    # NOTE: you cannot add multiple --exclude options, they must be combined
    inotifywait -r -m -e close_write \
        --exclude='/(\.[^/]+)?\.swp?.$|~$|\/.git/' \
        "$localsrcdir/" |
    while read x; do
        printf '\e[36m%s\e[m\n' "Trigger $((++round)): $x" >&2
        touch "$sync"
    done
}


### MAIN ###

# For gdb
if [ ! -e "${remotesrcdir%%/}" ]; then
    ln -sv "$localsrcdir" "${remotesrcdir%%/}"
fi

monitor_changes & monpid=$!

echo Waiting...
while inotifywait -qq -e close_write "$sync"; do
    echo Woke up...
    # Wait for a second in case I save something and want to do a ninja edit.
    sleep 1

    # IMPORTANT: do not sync top-level config.h or it will break OOT builds
    rsync -av --delete --exclude='.*.sw?' \
        --exclude=config.h \
        "$localsrcdir/" "$remotehost:$remotesrcdir/" &&
    ssh -t "$remotehost" "$remotecmd"
    retval=$?
    if [ $retval -ne 0 ]; then
        notify-send -- "$(tty) - $(date -R)" "Build broke with $retval"
        sleep 2
    else
        mkdir -p "$rundir"
        rsync -av --delete \
            --exclude='.*.sw?' \
            --exclude='*.a' \
            "$remotehost:$rundir" "$rundir"
        notify-send -- "$(tty) - $(date -R)" "READY"
    fi
    echo Another satisfied customer. NEXT
done
