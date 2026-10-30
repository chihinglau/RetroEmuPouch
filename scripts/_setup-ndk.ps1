$ErrorActionPreference = 'Continue'
$cmd = 'mkdir -p /home/ubuntu/ndkdl && cp /mnt/d/ai/prj/trae/HuaWei/RetroEmuPouch/build/android-ndk-r28c-linux.zip /home/ubuntu/ndkdl/ && cd /home/ubuntu/ndkdl && unzip -q -o android-ndk-r28c-linux.zip && echo UNZIP_DONE && ls /home/ubuntu/ndkdl && ls /home/ubuntu/ndkdl/android-ndk-r28c/toolchains/llvm/prebuilt/'
& wsl.exe -e bash -lc $cmd
Write-Host "exit=$LASTEXITCODE"
