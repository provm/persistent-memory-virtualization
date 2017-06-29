# Virtio
Virtio is a paravirtualized device driver model commonly used for more efficient I/O in virtualized environments.
In this document, I briefly list down pointers to creation of a new virtio device as well as communication between the frontend and the backend.

## Definition of a new device in QEMU
A new virtio device is created by extending the abstract VirtIODevice. You register the device with `virtio_register_types()`. See hw/block/virtio-vssd.c. You need to create virtqueues here.
You also encapsulate this device functionality in a virtio PCI device. See hw/virtio/virtio-pci.c.

## Writing a new frontend device driver in the linux kernel
A new virtio frontend driver need not do a lot. It needs to register the driver using `register_virtio_driver()`. See drivers/virtio_vssd.c. You need to discover virtqueues and initialize your device state in the probe function.

## Communication between the frontend and backend
The primary mode of communication is through a virtqueue. The guest creates a scatter-gather list from a buffer or multiple buffers. It then calls a variant of `virtqueue_add_*()` to add the buffer to the virtqueue. The buffer can be IN buffers (meaning host will send some data) or OUT buffers (meaning guest is sending some data). The `virtqueue_add_inbuf()` and `virtqueue_add_outbuf()` variants are straightforward. But the `virtqueue_add_sgs()` variant allows both the types. So the convention to keep in mind is that first all the OUT buffers should be added and then all the IN buffers should be added. The `out` and `in` parameters are indices in the array of scatterlist pointers where the OUT and IN buffers start respectively.
