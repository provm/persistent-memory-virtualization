# Patches for linux 4.9.14 and qemu 2.8.0
See virtio.md for notes on creating a new virtio device and setting up the communication properly between frontend and backend drivers.

## Steps for applying the patches
* Download and unzip the linux-4.9.14 and qemu-2.8.0 source code.
* [Linux Academy](https://linuxacademy.com/blog/linux/introduction-using-diff-and-patch/) has an excellent article on using the patch utility.

## Linux build instructions
* Make sure that you have configured the kernel and enabled the virtio drivers.
* Alternatively you could use the config file in this directory directly.

## QEMU build instructions
* I followed the practice of building in a separate build directory. This helps keep the source tree clean and all the build artifacts remain in a separate directory. So create a directory named build in the source tree.
* Execute the following commands to build the source code.
```
# Configure QEMU for x86_64 only - faster build
../configure --target-list=x86_64-softmmu --enable-debug --enable-debug-info --enable-gtk --disable-strip --disable-pie

# Build in parallel
make -j4
```
* The build artifacts are installed in the build directory.
