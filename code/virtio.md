# Virtio
Virtio is a paravirtualized device driver model commonly used for more efficient I/O in virtualized environments. The device driver has two parts -- frontend and backend. The frontend driver is a simple driver that interfaces with the guest kernel and uses an abstract communication model called Virtio Ring for communicating with the backend driver residing in the host. To know more about Virtio Ring basics, read [Rusty Russell's original paper](http://dl.acm.org/citation.cfm?id=1400108). The [Virtio Specification document](http://docs.oasis-open.org/virtio/virtio/v1.0/csprd01/virtio-v1.0-csprd01.html) contains the latest specification and is a useful reference. The paper gives a nice overview and may be read for better understanding, but refer to the specification document for the latest changes.

NOTE ON STYLE: Any code snippets given here are incomplete and cannot be run as-is. To emphasize on this fact, omitted code has been denoted by an ellipsis (...)

In this document, I cover the three steps in which I did this project
1. Creating a basic Virtio device in the frontend and backend. This was just defining a new type of device which can be discovered and probed in the guest OS and a Virtio frontend driver can be written for it.
1. Adding functionality to register this device as a generic block device in the linux kernel.
1. Adding functionality for resizing the block device. This includes the interfaces for the user to give resize command to the backend, the interface for the user application running in the guest to enumerate which blocks to evict and the housekeeping involved for the frontend and backend to do the resizing correctly each time.

## Definition of a New Device in QEMU
There are two important parts to defining a new device in QEMU.
1. Defining a new device type by extending VirtIODevice.
1. Encapsulating our new device functionality in a PCI device for exposing to the guest. See the [Virtio specification document](http://docs.oasis-open.org/virtio/virtio/v1.0/csprd01/virtio-v1.0-csprd01.html) for transport types other than PCI (for example, there's MMIO and more).

### Defining a New Device Type
A new virtio device is created by extending the abstract VirtIODevice. We have defined a new device type `struct VirtIOVssd` in `include/hw/virtio/virtio-vssd.h` as follows:
```
typedef struct VirtIOVssd {
    VirtIODevice parent_obj;
    VirtQueue *vq, *ctrl_vq;
	...
} VirtIOVssd;
```
We only need to define our VirtQueues in here. Nothing more is required for a basic Virtio device. So I have removed all the other irrelevant parts from the struct definition.

We also define a macro that will typecast a given `VirtIODevice` type to our `VirtIOVssd` type.
```
#define VIRTIO_VSSD(obj) \
    OBJECT_CHECK(VirtIOVssd, (obj), TYPE_VIRTIO_VSSD)
```

A **virtqueue** is a FIFO abstraction over the virtio ring. It provides a simple interface to push data from both ends - the frontend and the backend. Moreover, there is a simple abstraction for notifying the other end after adding the data to the queue. You just register callback functions that are invoked when the notification comes from the other end.

The detailed device definition is done in `hw/block/virtio-vssd.c`. A new `TypeInfo` struct is defined for our device type.

```
static const TypeInfo virtio_vssd_info = {
    .name = TYPE_VIRTIO_VSSD,
    .parent = TYPE_VIRTIO_DEVICE,
    .instance_size = sizeof(VirtIOVssd),
    .class_init = virtio_vssd_class_init,
};
```
There are two types of functions that are required to be defined for any device type -- `class_init` and `instance_init`. The former is used to specify initialization tasks common to all the instances of this device (this forms a device class), while the latter is used to initialize specific instances separately. We do not need to implement the `instance_init` for the VirtIOVssd device. We just register a function for `class_init` here.

We register the new device type with `virtio_register_types()`. Our `class_init` function, called `virtio_vssd_class_init` registers more functions which will be called when the machine is being started. For example, the `realize` function, implemented by `virtio_vssd_device_realize` is where we initialize device state. Again, removing all the extra stuff, following is the code needed for a basic Virtio device realize:
```
static void virtio_vssd_device_realize(DeviceState *dev, Error **errp)
{
    VirtIODevice *vdev = VIRTIO_DEVICE(dev);
    VirtIOVssd *vssd = VIRTIO_VSSD(dev);
	...

	virtio_init(vdev, "virtio-vssd", VIRTIO_ID_VSSD, sizeof(struct virtio_vssd_config));

    // TODO: What is a good virtqueue size for a block device? We set it to 128.
    vssd->vq = virtio_add_queue(vdev, 128, virtio_vssd_handle_request);
	vssd->ctrl_vq = virtio_add_queue(vdev, 128, virtio_vssd_handle_resize);
	...
}
```
We just initialize the device and register two virtqueues here. The number of virtqueues to be used is entirely dependent on you. We created two so that one can transfer the read/write data of the block device while the other one transfers the resize commands and their responses and acknowledgements. Each virtqueue is registered with the callback function that is invoked when the frontend notifies that some data has been added to the queue.

Two other mandatory things that are required to define a device properly are as follows:
* A list of properties (an array of type Property); we keep it empty by adding only an end-of-list element.
```
static Property virtio_vssd_properties[] = {
    DEFINE_PROP_END_OF_LIST(),
};
```
* A `get_features` function; we have just defined a dummy function without any modifications.
```
static uint64_t virtio_vssd_get_features(VirtIODevice *vdev, uint64_t features, Error **errp)
{
    return features;
}
```
I did not fully understand the usage of these two things and did not use them. It might be a good exercise to go through the other Virtio devices' codes to understand how they use them. 

### Encapsulating the Device in a PCI Device
By defining the new device type, we have defined the core functionality. But we still do not know how the communication will happen between the backend and the frontend. Hence we need to encapsulate this device functionality in a virtio PCI device. This is done so that our device shows up as a new PCI device in the guest. We define our new PCI device as an extension of `VirtIOPCIProxy` in `hw/virtio/virtio-pci.h`:
```
struct VirtIOVssdPCI {
    VirtIOPCIProxy parent_obj;
    VirtIOVssd vdev;
};
```
Just like we did for `VirtIOVssd`, we also define a macro here to typecast a `VirtIOPCIProxy` to a `VirtIOVssdPCI` object type.
```
#define VIRTIO_VSSD_PCI(obj) \
    OBJECT_CHECK(VirtIOVssdPCI, (obj), TYPE_VIRTIO_VSSD_PCI)
```

The PCI device is registered in `hw/virtio/virtio-pci.c`. Similar to `VirtIOVssd`, we have a `TypeInfo` object that has the various functions like `instance_init`, `class_init` etc. The implementation for `class_init` is important here.
```
static void virtio_vssd_pci_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    VirtioPCIClass *k = VIRTIO_PCI_CLASS(klass);
    PCIDeviceClass *pcidev_k = PCI_DEVICE_CLASS(klass);

    k->realize = virtio_vssd_pci_realize;
    dc->props = virtio_vssd_pci_properties;
    set_bit(DEVICE_CATEGORY_MISC, dc->categories);

    pcidev_k->vendor_id = PCI_VENDOR_ID_REDHAT_QUMRANET;
    pcidev_k->device_id = PCI_DEVICE_ID_VIRTIO_VSSD;
    pcidev_k->revision = VIRTIO_PCI_ABI_VERSION;
    pcidev_k->class_id = PCI_CLASS_OTHERS;
}
```
We define a `realize` function, an empty properties list and **set the PCI vendor id, device id, revision and class id**. The latter two are not important and are default values that all other virtio pci devices use too. [Wikipedia](https://en.wikipedia.org/wiki/PCI_configuration_space#Standardized_registers) has a nice explanation about PCI device ids. The [Debian website](https://wiki.debian.org/HowToIdentifyADevice/PCI) also has some nice information about tools like `lspci` and other methods to identify a PCI device. 

The `realize` function here just sets the parent bus to be the virtio pci bus which is an implementation of the abstract virtio bus.

NOTE: Just like the initialization functions viz. `realize` etc., both the frontend and backend have corresponding clean-up functions like `unrealize`. We do not expound much on them here.

## Writing a new Frontend Device Driver in the Linux Kernel
Once all the above actions are done, we should be able to add our new device to the VM while starting up QEMU. We just use the following command line flag when starting QEMU:
```
-device virtio-vssd-pci
```

A basic virtio frontend driver need not do a lot. We have defined our frontend driver in `drivers/block/virtio_vssd.c`.

We define our basic virtio device, `struct virtio_vssd` as follows:
```
struct virtio_vssd {
	struct virtio_device *vdev;
	struct virtqueue *vq, *ctrl_vq;
	...
	
};
```
As mentioned earlier, the basic device need not do a lot. It just has to have virtqueues and must extend `struct virtio_device`.

We need to register the driver using `register_virtio_driver()`. The `struct virtio_driver` that we register here has an `id_table` field. This is where we give the virtio device id (and not the PCI id) of our device, VirtIOVssd which we defined in the backend in `include/standard-headers/linux/virtio_ids.h`. The linux kernel has some convoluted mechanism because of which it replaces the PCI device id with the subdevice id for newer virtio devices. This happens in the virtio PCI device discovery code which we don't touch. Here's a mail that I had sent it to Puru Sir, after finally figuring out this mystery:

> A PCI device configuration has 4 fields to identify the vendor, device, subvendor and subdevice. And Virtio developers decided to use these fields very confusingly. In the frontend virtio device initialization code, they replace the device id with the subdevice id. Hence, even if we want to match against the device id we specified in the backend (0x1016), we match against 54.

> Now, even when I set the subdevice id to 0x1016 in the backend, it was being replaced by 54. This is because, in the backend, it is populated by the Virtio device id, which was 54. I had defined it and forgotten about it as it was not being used anywhere directly. And moreover, we were using a Virtio PCI device. Well, a Virtio PCI device encapsulates the Virtio device.

> I have not understood why they do so yet. Probably it is done to avoid code rewrite. Till virtio 1.0, the devices had different device codes.

We register a `probe` function that is reponsible for registering this driver for our device. 
```
static int virtio_vssd_probe(struct virtio_device *vdev) {
	struct virtio_vssd *vssd;
	int err;
	...
	
	vssd = kzalloc(sizeof(*vssd), GFP_KERNEL);
	if (!vssd) {
		err = -ENOMEM;
		goto out;
	}

	vssd->vdev = vdev;
	...

	err = init_virtqueues(vssd);
	if (err) {
		goto out_free_vssd;
	}
	...
	
	vdev->priv = vssd;
	...
	
	printk(KERN_ALERT "virtio_vssd: Device initialized\n");
	return 0;

out_free_vssd:
	vssd->vdev->config->del_vqs(vssd->vdev);
	kfree(vssd);

out:
	return err;
}
```

We need to discover virtqueues and initialize your device state in the probe function. The function `init_virtqueues` does this.
```
static int init_virtqueues(struct virtio_vssd *vssd) {
	struct virtqueue *vqs[1];

	vq_callback_t *callbacks[] = { virtio_vssd_request_completed, virtio_vssd_resize_callback };
	const char *names[] = { "virtio_vssd_request_completed", "virtio_vssd_resize_callback" };

	int err;
	int nvqs = 2;

	err = vssd->vdev->config->find_vqs(vssd->vdev, nvqs, vqs, callbacks, names);
	if (err) {
		return err;
	}

	vssd->vq = vqs[0];
	vssd->ctrl_vq = vqs[1];

	return 0;
}
```
Just like virtqueue initialization in the backend, we register callbacks to the individual virtqueues. This is done by a call to the `find_vqs` function of the virtio device which discovers the virtqueues registered by the backend.

## Communication between the frontend and backend
This is the most crucial part but incredibly simple. Its just that the lack of documentation made it difficult for me to get it right.
### Guest-to-host
The guest creates a scatter-gather list from a buffer or multiple buffers. It then calls a variant of `virtqueue_add_*()` to add the buffer to the virtqueue. The buffer can be IN buffers (meaning host will send some data) or OUT buffers (meaning guest is sending some data). The `virtqueue_add_inbuf()` and `virtqueue_add_outbuf()` variants are straightforward. They take just one scatterlist and add it to the virtqueue as IN and OUT respectively. But the `virtqueue_add_sgs()` variant allows both the types. It takes an array of scatterlists. Each individual scatterlist can be marked either IN or OUT. **So the convention to keep in mind is that first all the OUT buffers should be added and then all the IN buffers should be added.** The `out` and `in` parameters are indices in the array of scatterlists where the OUT and IN buffers start respectively. Another important parameter to the `virtqueue_add_*()` functions is the `void *data` parameter. The buffer we share to the host using scatterlists can be passed as a void pointer to virtio. It does proper housekeeping and while giving the response back, it returns the same pointer back. Since the host has read from or modified the same address locations in the guest's memory area, this pointer to our data can be accessed to read the response from the host.

To initialize a scattelist from a buffer (it can be anything, a struct, an array or any other data structure in the memory; it just needs to be contiguous), we use the function `sg_init_one`

Finally, to tell the host that it has added an entry in the virtqueue, the guest calls `virtqueue_kick` or its asynchronous variant `virtqueue_kick_prepare` followed by `virtqueue_notify`.

Conversly, when the guest gets a response from the host, the callback function registered while initializing the virtqueue will be called. There is a simple function called `virtqueue_get_buf`. It returns the same `void *data` pointer that was passed to the `virtqueue_add_*` functions.

### Host-to-guest
The host callback registered with the virtqueue will get called whenever it receives a *kick* from the guest. It can use two functions at its disposal -- `virtqueue_pop` and `virtqueue_push`. The former function is used to pop an element. It always returns a void pointer pointing to a `VirtQueueElement`. The `VirtQueueElement` contains information about the IN and OUT buffers and arrays of `struct iovec` (io vectors), which are the userspace equivalent of scatterlists. They also contain an address and an offset. In our code, we encapsulate it in a `VirtIOVssdRequest`.
```
typedef struct VirtIOVssdReq {
    VirtQueueElement elem;
	...
	
    VirtIOVssd *vssd;
    VirtQueue *vq;
    ...

} VirtIOVssdReq;
```

We populate the other elements of `VirtIOVssdReq` ourselves. We look at this callback in more detail when we look at the block device implementation.

When its time for the host to tell the guest, it pushes the virtqueue element on the virtqueue using `virtqueue_push`, and then calls `virtio_notify` to notify the guest that the request has been processed.

Other handy functions to note are `iov_to_buf`, which copies data from an iovec to a buffer (a struct, array etc). Then we can work on the data in the buffer directly. After we are done, we can again copy data from the buffer to the iovec using `iov_from_buf`.
