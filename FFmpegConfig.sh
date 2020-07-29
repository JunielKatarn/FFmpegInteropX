#!/bin/bash
DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

declare -A arch
arch['x86']='x86'
arch['x64']='x86_64'
arch['ARM']='arm'
arch['ARM64']='arm64'

platform=$2

configureArgsOrig="\
    --toolchain=msvc \
    --disable-programs \
    --disable-d3d11va \
    --disable-dxva2 \
    --disable-encoders \
    --disable-devices \
    --disable-hwaccels \
    --disable-doc \
    --enable-shared \
    --enable-cross-compile \
    --enable-debug \
    --enable-zlib \
    --enable-bzlib \
    --enable-lzma \
    --enable-libxml2 \
    --enable-iconv \
    --arch=${arch[$platform]} \
    --target-os=win32 \
    --prefix=$DIR/ffmpeg/Build/Windows10/$platform
"

configureArgs="\
    --toolchain=msvc \
    --disable-all \
    --disable-d3d11va \
    --disable-muxers \
    --disable-protocols \
    --disable-doc \
    --enable-shared \
    --enable-cross-compile \
    --enable-debug \
    --enable-avcodec \
    --disable-avdevice \
    --enable-avfilter \
    --enable-avformat \
    --enable-swresample \
    --disable-swscale \
    --enable-decoder=adpcm_ima_qt \
    --enable-demuxer=aiff \
    --enable-demuxer=avi \
    \
    --disable-manpages \
    --disable-podpages \
    --disable-network \
    --disable-zlib \
    --disable-schannel \
    --disable-dxva2 \
    --disable-swscale-alpha \
    --disable-runtime-cpudetect \
    \
    --arch=${arch[$platform]} \
    --target-os=win32 \
    --prefix=$DIR/ffmpeg/Build/Windows10/$platform
"

if [ "$platform" == "x86" ]; then
    configureArgs="\
        $configureArgs \
            --extra-cflags='-MD -DWINAPI_FAMILY=WINAPI_FAMILY_APP -D_WIN32_WINNT=0x0A00 -DLZMA_API_STATIC' \
            --extra-ldflags='-APPCONTAINER WindowsApp.lib' \
"

elif [ "$platform" == "x64" ]; then
    configureArgs="\
        $configureArgs \
            --extra-cflags='-MD -DWINAPI_FAMILY=WINAPI_FAMILY_APP -D_WIN32_WINNT=0x0A00 -DLZMA_API_STATIC' \
            --extra-ldflags='-APPCONTAINER WindowsApp.lib' \
"

elif [ "$platform" == "ARM" ]; then
    configureArgs="\
        $configureArgs \
            --as=armasm \
            --cpu=armv7 \
            --extra-cflags='-MD -DWINAPI_FAMILY=WINAPI_FAMILY_APP -D_WIN32_WINNT=0x0A00 -DLZMA_API_STATIC -D__ARM_PCS_VFP' \
            --extra-ldflags='-APPCONTAINER WindowsApp.lib' \
"

elif [ "$platform" == "ARM64" ]; then
    configureArgs="\
        $configureArgs \
            --as=armasm64 \
            --cpu=armv8 \
            --extra-cflags='-MD -DWINAPI_FAMILY=WINAPI_FAMILY_APP -D_WIN32_WINNT=0x0A00 -DLZMA_API_STATIC -D__ARM_PCS_VFP' \
            --extra-ldflags='-APPCONTAINER WindowsApp.lib' \
"

fi

echo "Make Win10 $platform"
pushd $DIR/ffmpeg
rm -rf Build/Windows10/$platform/*
rm -rf Output/Windows10/$platform/*
mkdir -p Output/Windows10/$platform
cd Output/Windows10/$platform

eval $DIR/ffmpeg/configure $configureArgs || exit

make -j8     --trace 2>&1 | tee log.txt || exit
make install --trace 2>&1 | tee ins.txt || exit
#make -j8     || exit
#make install || exit
popd

exit 0