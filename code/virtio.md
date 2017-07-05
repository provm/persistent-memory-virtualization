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

We need to register the driver using `register_virtio_driver()`. The `struct virtio_driver` that we register here has an `id_table` field. This is where we give the virtio device id (and not the PCI id) of our device, VirtIOVssd which we defined in the backend in `include/standard-headers/linux/virtio_ids.h`. The linux kernel has some convoluted mechanism because of which it replaces the PCI device id with the subdevice id for newer virtio devices. This happens in the virtio PCI device discovery code which we don't touch. Here's a mail that I had sent to Puru Sir, after finally figuring out this mystery:

> A PCI device configuration has 4 fields to identify the vendor, device, subvendor and subdevice. And Virtio developers decided to use these fields very confusingly. In the frontend virtio device initialization code, they replace the device id with the subdevice id. Hence, even if we want to match against the device id we specified in the backend (0x1016), we match against 54.
>
> Now, even when I set the subdevice id to 0x1016 in the backend, it was being replaced by 54. This is because, in the backend, it is populated by the Virtio device id, which was 54. I had defined it and forgotten about it as it was not being used anywhere directly. And moreover, we were using a Virtio PCI device. Well, a Virtio PCI device encapsulates the Virtio device.
>
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

## Creating a Block Device
Once the basic virtio device is done and you've understood the communication method well, it is easy to build the block device on top. We start with the frontend.

### Block Device in the Frontend
It is instructive to start by reading the chapter 16 on Block Drivers in Linux Device Drivers, 3rd edition. It is a bit dated in terms of the function names etc. But the basic functionality remains the same and the function names in the kernel might have changed a bit. Read especially about the two interfaces a block driver gets to handle requests -- the `make_request_fn` and the `request_fn`. There are important differences between them in terms of where in the request processing pipeline, the driver takes over.

After multiple iterations of trying to get the semantics correct, we have implemented the `request_fn`. The granularity of `make_request_fn` is the `struct bio` which might make it inefficient to *kick* the backend each time. I do not have a comparative analysis of the performance of both but it would be a nice exercise.
A third interface for the block device driver is to interface with the *multiqueue block layer*. This layer creates per-core queues and thus reduces the request queue lock bottleneck seen in multiprocessor environments. But I think you should try doing that only when you have understood the legacy single queue interfaces well i.e. the make request function and the request function.

Coming to our code, our `struct virtio_vssd` has the following important components to make it work like a block device:
```
struct virtio_vssd {
    ...

    spinlock_t q_lock;
	
    struct request_queue *queue;
    struct gendisk *gdisk;

    struct scatterlist sglist[SG_SIZE];
    ...
};
```
The `struct gendisk` is required to be registered as a block device. It is the structure that contains all the information linux needs to interface with this block driver. The `spinlock_t` is the queue lock which we register along with the block device. The kernel uses this spinlock while calling the operation on the request queue associated with this device. The scatterlist array is for converting the request into a scatterlist. We will see how it works shortly.

The relevant portion of the probe function which registers the block device is as follows:
```
static int virtio_vssd_probe(struct virtio_device *vdev) {
    spin_lock_init(&vssd->q_lock);

    vssd->queue = blk_init_queue(virtio_vssd_request, &vssd->q_lock);
    if(vssd->queue == NULL) {
        err = -ENOMEM;
        goto out_free_vssd;
    }

    vssd->queue->queuedata = vssd;
    vdev->priv = vssd;

    vssd->gdisk = alloc_disk(MINORS);
    if (!vssd->gdisk) {
        //printk (KERN_ALERT "virtio_vssd: Call to alloc_disk failed\n");
        goto out_free_vssd;
    }
    vssd->gdisk->major = virtio_vssd_major;
    vssd->gdisk->first_minor = MINORS; // TODO: We probably need to set it to 1
    vssd->gdisk->fops = &virtio_vssd_ops;
    vssd->gdisk->queue = vssd->queue;
    vssd->gdisk->private_data = vssd;
    snprintf (vssd->gdisk->disk_name, 32, "vssda"); // TODO: A crude hard-coding, ince we are creating only one device of this kind.

    set_capacity(vssd->gdisk, vssd->capacity);
    add_disk(vssd->gdisk);

    sg_init_table(vssd->sglist, SG_SIZE);

    printk(KERN_ALERT "virtio_vssd: Device initialized\n");
    return 0;

out_free_vssd:
    vssd->vdev->config->del_vqs(vssd->vdev);
    kfree(vssd);

out:
    return err;
}
```

The request function is registered in the call to `blk_init_queue`. It takes two arguments, the request function to be called by the linux kernel block I/O layer for request processing and the spinlock on the request queue that will be used throughout. 

Then we populate the `struct gendisk` with the data that we have. For example, the major device number, `virtio_vssd_major` is obtained from the call to `register_blkdev` which registers a new block device in the kernel. This call is made in the module init function, `virtio_vssd_driver_init`, which we have not discussed above. We call `alloc_disk` with the number of minor device numbers we want to support. Most modern block drivers have this number as 16. If you set it to 1, you will not be able to see any partitions in the disk.

The disk name is hard-coded for `vssda` for now as we know there will be only one such device in the VM. For multiple devices, one might need to loop through the above construct and assign different names like `vssdb, vssdc, ...`.

`vssd->gdisk->private_data` is an recurring construct worth mentioning. In a lot of places in the linux kernel, a void pointer would be used to store a reference to something that might be referred to later. In this case, we store a pointer to our `struct virtio_vssd` so that we can access its elements later. We do the same with `vssd->queue->queuedata`. Essentially we want to be able to access our device struct later on, maybe for some housekeeping etc. A similar thing was done in the virtio communication explained earlier, when we assign our buffer to the `void *data` so that later when the response comes from the host, we access that buffer from the same pointer.

`sg_init_table` initializes the scatterlist array. We will use this to map the request data into a scatterlist in the request function outlined below.
```
static void virtio_vssd_request(struct request_queue *q) {
    struct request *req;
    struct virtio_vssd *vssd = q->queuedata;
    struct virtio_vssd_request *vssdreq;
    struct scatterlist *sglist[3];
    struct scatterlist hdr, status;
    unsigned int num = 0, out = 0, in = 0;
    int error;

    //printk(KERN_ALERT "virtio_vssd: Request fn called!\n");

    if(unlikely((req = blk_peek_request(q)) == NULL))
        goto no_out;

    if(req->cmd_type != REQ_TYPE_FS)
        goto no_out;

    if(!virtio_vssd_request_valid(req, vssd))
        goto no_out;

    vssdreq = kmalloc(sizeof(*vssdreq), GFP_ATOMIC);
    if (unlikely(!vssdreq)) {
        goto no_out;
    }

    vssd = req->rq_disk->private_data;
    vssdreq->request = req;

    num = blk_rq_map_sg(q, req, vssd->sglist);
    //printk(KERN_ALERT "virtio_vssd: Request mapped to sglist. Count: %u\n", num);

    if(unlikely(!num))
        goto free_vssdreq;

    vssdreq->hdr.sector = cpu_to_virtio32(vssd->vdev, blk_rq_pos(req));
    vssdreq->hdr.type = cpu_to_virtio32(vssd->vdev, rq_data_dir(req));

    sg_init_one(&hdr, &vssdreq->hdr, sizeof(vssdreq->hdr));
    sglist[out++] = &hdr;

    if (rq_data_dir(req) == WRITE) {
        sglist[out++] = vssd->sglist;
    } else {
        sglist[out + in++] = vssd->sglist;
    }

    sg_init_one(&status, &vssdreq->status, sizeof(vssdreq->status));
    sglist[out + in++] = &status;

    //printk(KERN_ALERT "virtio_vssd: Sector: %llu\tDirection: %u\n", vssdreq->hdrsector, vssdreq->hdr.type);
    error = virtqueue_add_sgs(vssd->vq, sglist, out, in, vssdreq, GFP_ATOMIC);
    if (error < 0) {
        //printk(KERN_ALERT "virtio_vssd: Error adding scatterlist to virtqueue. Stopping request queue\n");
        blk_stop_queue(q);
        goto free_vssdreq;
    }
    blk_start_request(req);
    virtqueue_kick(vssd->vq);

no_out:
    return;

free_vssdreq:
    kfree(vssdreq);
}
```

For each request, we create three scatterlists. This is the format that we have decided upon by looking at the virtio_blk implementation. It has a lot more number of fields that we do not need. The important thing to keep in mind is the model of communication using virtqueues and the direction -- IN/OUT. Once you have understood the abstract idea, the implementation will reinforce the idea. If you're unsure about how that works, go and read the section on communication again.

The three scatterlists are as follows:
1. A header, called `struct vssd_hdr`. It just has two fields -- `type and sector`. The former denotes the direction of the request -- READ = 0, WRITE = 1. And the latter is self-explanatory. It is the starting sector number for this request on the device. We mark this as an OUT buffer.
1. A scatterlist mapped from the block I/O request using the `blk_rq_map_sg()` function. It is marked as IN/OUT based on whether this was a READ/WRITE request.
1. The status word. This is always an IN buffer and it gets the status of this request from the host to the guest.

Remember that this is just the convention we followed to suit our requirements. We will see that a different convention is used for the resize command communication.

A careful reading of the code will give you an idea as to how the indexes of the OUT and IN buffers are maintained and that the OUT buffers are strictly before the IN buffers. The scatterlists are then sent to the `virtqueue_add_sgs()` function.

Finally the frontend *kicks* the backend to tell it to process the request.

On receiving the response back from the backend, the virtqueue callback, `virtio_vssd_request_completed` is called. It calls `virtqueue_get_buf()` and gets the same `struct virtio_vssd_request` on which this request was called. Then it just calls the request completion function, `__blk_end_request_all` and hands over the request for processing by the block I/O layer. It all works seamlessly as long as we follow the virtqueue communication guidelines properly.

### Block Device in the Backend
Creating a block device in the backend is fairly straightforward. We just add some more state to the `struct VirtIOVssd` like the `backingdevice` name, the fd (file descriptor obtained from the open system call) etc. Inside the `realize` function, we initialize all of this state, for example, open the device file `/dev/sdb` in `O_DIRECT` mode etc.

```
static void virtio_vssd_device_realize(DeviceState *dev, Error **errp)
{
    ...

    strncpy(vssd->backingdevice, "/dev/sdb", 9);

    vssd->fd = open(vssd->backingdevice, O_RDWR | O_DIRECT/* | O_SYNC*/);
    if(vssd->fd < 0) {
        error_setg(errp, "Unable to initialize backing SSD state");
        return;
    }
    ...

    vssd->capacity = 2097152; // =2^21 (# of 512 byte sectors; therefore 2^30 bytes or 1GB)
    ...
}
```

The real work is done by the `virtio_vssd_handle_request` function that was registered for this virtqueue during initialization. Broadly, it does four things --
1. Pops a `VirtQueueElement` from the virtqueue. Sets some state in the `VirtIOVssdReq` like the device etc.
1. Extracts the `iovec` iovectors from the VirtQueueElement. There is also direction information attached with each vector.
1. Performs a read/write directly on the device file using readv/writev functions. Read more about how they work [here](http://man7.org/linux/man-pages/man2/readv.2.html). Sets the status code to the error reported, if any. 
1. Pushes the VirtQueueElement back to the virtqueue and *notifies* the guest about the data pushed.

The function `qemu_iovec_init_external` just initializes a structure called `QEMUIOVector` which has some more book-keeping than a normal `struct iovec`.

## Adding 'Resize' Functionality
The resize functionality basically involves the backend informing the frontend about a resize command from the user which is given from the qemu monitor.

The command we have implemented is called `ssd-balloon`. It has just one signed parameter: the number of sectors to be removed or given back to the virtual device. Minus (-) sign denotes that the sectors are to be removed from the virtual device; also called *balloon inflation*. Plus (+) sign indicates that sectors are to be given back to the virtual device; also called *balloon deflation*.

This is similar to the memory ballooning method where the pages required by the host are given by a balloon driver running in the guest. So whenever the host needs to shrink the vssd size, it asks the guest driver to give it some number of sectors which can be unmapped from this VM and possibly mapped to another one.

We discuss the changes made to enable resizing in three parts
1. Changes made to the frontend for resizing
1. Changes made to the backend for resizing
1. Changes made to the backend to add a new qemu command

At the end we also discuss the possible alternatives that could be used.

### Changes made to the frontend for resizing
We define a `struct virtio_vssd_resize_info` which is used for communication between the backend and the frontend.
```
struct virtio_vssd_resize_info {
    s32 status;
    s32 ack;
    //u64 *sector_list;
    u64 sector_list[SSD_BALLOON_UNIT];
};
```
It might be helpful here to again revisit the virtqueue communication model described in the first section. For any communication, the guest needs to earmark memory as IN/OUT and tell the backend about it. Hence, whether it is inflation or deflation, the first step is the host telling the guest about the command. The next step is the guest allocating memory and telling the host.

Following are the steps for inflation:
1. The command from the user is handled in the backend. The backend maintains a configuration of the device whose size now needs to change.
1. The backend notifies the frontend via a config_changed event that it needs to free n sectors.
1. The frontend allocates memory for an array of 4096 sector numbers (unsigned 64-bit integers). It then marks the buffer as OUT (direction of data flow) because it needs to free sectors and tell the backend.
1. The frontend populates the sector number array with either random numbers (using `get_random_bytes()`) or those obtained from the application via the procfs interface (discussed later) and *kicks* the backend.
1. The backend reads data from the buffer shared by the frontend, updates its own records of the sector numbers taken from the guest; and acknowledges the number of sectors obtained, to the guest via another notification.

#### The `procfs` interface
We created a proc file named `/proc/vssd_balloon_blknum`. This is used to write the block numbers (and not sector numbers) to the driver which can be evicted. This was done for a particular experiment and does not really implement a callback etc. An independent program just writes a bunch of block numbers to the proc file. The driver reads them into an array. On getting a request to inflate the balloon, it just reads the block numbers sequentially and marks those blocks (= 8 sectors/block) as invalid, see the code snippet below.
```
static void virtio_vssd_free_blocks(struct virtio_vssd *vssd, struct virtio_vssd_resize_info *resize_info) {
    u32 i, j=0, total_sectors = vssd->capacity < abs(resize_info->status) ? vssd->capacity : abs(resize_info->status);
    u32 *list = vssd->block_list;
    u64 blk_num, sector_num;
    ...

    for(;j<total_sectors && idx_remove < idx;) {
        blk_num = blknums[idx_remove++];
        for(i=0; i<8; i++) {
            sector_num = blk_num * 8 + i;
            spin_lock_irq(&vssd->q_lock);
            if((list[sector_num/32] & (1 << (sector_num % 32))) == 0) {
                list[sector_num/32] |= (1 << (sector_num % 32));
                resize_info->sector_list[j++] = sector_num;
            }
            spin_unlock_irq(&vssd->q_lock);
        }
    }
}
```

The steps for deflation are as follows:
1. The command from the user is handled in the backend.
1. The backend notifies the frontend via a config_changed event that it will be given back n sectors.
1. The frontend allocates memory for an array of 4096 sector numbers (unsigned 64-bit integers). It then marks the buffer as IN (direction of data flow) because it needs to receive sector list from the backend.
1. The frontend *kicks* the backend.
1. The backend fills the buffer with the sector numbers and notifies the frontend.
1. The frontend reads data from the buffer filled by the backend, updates its records of valid sector numbers on the vSSD; and acknowledges the number of sectors obtained, to the backend via another notification.

Both the frontend and the backend keep a bitmap of all the sector numbers to keep track of sectors that have been ballooned out (1=sector ballooned out).

#### The `config_changed` Event
The `config_changed` event in the frontend virtio driver is a method to notify the guest about any changes to the config. The host and the guest maintain identical config data structures and the host notifies the guest about the change in the config values via `virtio_notify_config()` function.
```
static void virtio_vssd_conf_changed(struct virtio_device *vdev) {
    struct virtio_vssd *vssd = vdev->priv;
    __le32 command;

    virtio_cread(vdev, struct virtio_vssd_config, command, &command);
    ...
}
```
The frontend function reads the changed config using the `virtio_cread()` function and works accordingly.

In the backend, whenever we invoke the `virtio_notify_config()`, it internally calls the `get_config` function we have registered for the device. There, we can set the values we want for the config to tell the guest. Here's the implementation of the backend `get_config` function.
```
static void virtio_vssd_get_config(VirtIODevice *vdev, uint8_t *config_data)
{
    VirtIOVssd *vssd = VIRTIO_VSSD(vdev);
    struct virtio_vssd_config config;
    int sign = vssd->command < 0 ? -1 : 1;
    config.command = sign*vssd->command > SSD_BALLOON_UNIT ? sign*SSD_BALLOON_UNIT : vssd->command;

    vssd->command -= config.command;

    config.capacity = vssd->capacity;
    memcpy(config_data, &config, sizeof(struct virtio_vssd_config));
}
```

### Changes made to backend for resizing
The backend, on receiving the *kick* from the frontend, handles the resize in the function `virtio_vssd_handle_resize()`. Note the usage of `iov_to_buf()` and `iov_from_buf()` functions here. This is the simpler way to process data in the backend. In case of balloon inflation, it just reads the sector numbers received from the guest and updates its bitmap (1=sector ballooned out). But in case of balloon deflation, it has to choose which sector numbers to return. **So it goes over the bitmap serially and releases all the sectors that were ballooned out sequentially.** This is a grossly inefficient design, especially when it is compounded by the multiple iterations of the ballooning process to fulfill one command, which we explain next.

#### Multiple iterations of the ballooning process
The ballooning process might take multiple iterations as the buffer size is 4096 sector numbers. Thus for ballooning in/out larger amount of memory, we need to follow the steps outlined above iteratively. As an example, consider ballooning 16 GB out of a 32 GB sized vSSD device. 16 GB = 16 * 2^21 sectors = 33554432 sectors i.e. 8192 iterations of 4096 sector numbers each.

The way we do it is storing the current outstanding number of sectors to be ballooned in a variable called `command` in the `struct VirtIOVssd` device state.
```
typedef struct VirtIOVssd {
    ...
    int64_t command; // the outstanding number of sectors yet to be processed
    uint64_t capacity; // The capacity of the disk (# of 512-byte sectors)
    uint32_t *block_list; // bitmap of valid guest sector numbers; use this to choose sectors to free
    ...
} VirtIOVssd;
```
At the end of the processing of the resize request, we check if the command is non-zero, we again call `virtio_notify_config()` to start another iteration of the ballooning, as shown in the code snippet below.

```
static void virtio_vssd_handle_resize(VirtIODevice *vdev, VirtQueue *vq)
{
    ...
    if(vssd->command != 0) {
        virtio_notify_config(vdev);
    } else if(vssd->command == 0 && resize_info.status == resize_info.ack) {
        ...
        printf("virtio_vssd_backend: Ballooning finished: %lu: %u\n", duration, total_sectors);
    }
}
```

### Adding a New QEMU Monitor Command
To add a new QEMU monitor command, we define functions that register callbacks in `balloon.c` called `qemu_add_ssd_balloon_handler` and `qemu_remove_ssd_balloon_handler`. These functions register and remove callbacks for our command which we define in `hmp-commands.hx` along the lines of the `balloon` command. We call it `ssd-balloon` and it can accept both positive and negative integers. Hence we use `i` as the type. It stands for 32-bit signed integer. There's also the option of a 64-bit integer using `l`. `monitor.c` contains a list of all the supported types in a comment just after the pre-processor macro section.
```
{
    .name       = "ssd-balloon",
    .args_type  = "value:i",
    .params     = "target",
    .help       = "request VM to change its balloon size by given number of sectors",
    .cmd        = hmp_ssd_balloon,
}
```
The `hmp_ssd_balloon` function invoked from here simply calls the `qmp_ssd_balloon` function. This function invokes our event handler function, if registered (using `qemu_add_ssd_balloon_handler` during device realize).
```
static void virtio_vssd_device_realize(DeviceState *dev, Error **errp)
{
    ...
    qemu_add_ssd_balloon_handler(virtio_ssd_balloon_to_target, vssd);
}
```

The handler function is as follows:
```
static void virtio_ssd_balloon_to_target(void *opaque, int64_t target)
{
    VirtIOVssd *vssd = VIRTIO_VSSD(opaque);
    VirtIODevice *vdev = VIRTIO_DEVICE(vssd);

    vssd->command += target; // We add to ensure that the direction is preserved.
    ...

    virtio_notify_config(vdev);
}
```
We just update the `command` variable in the vssd device state. And we call `virtio_notify_config()` function to notify the device. **This might cause race condition because if there is already a balloon command processing being done, then both the resize handler and this function might call the interrupt. Thus the value of the command might be different and there might be issues around correctness.**

#### Alternative Designs
Since we implemented the `config_changed` event in the frontend driver, we do not really need to keep the size of the buffer for sharing sector numbers fixed. We could precisely allocate a buffer of size asked for by the command from the host in the config change. This might save multiple iterations and make the performance better. A possible problem with this is that it might be difficult to allocate contiguous buffers in the kernel if they are large in size. The reason we need a contiguous buffer is that it is easy to create a scatterlist out of it. Just allocate one scatterlist from the buffer using `sg_init_one`. But I have no idea how one might create a scatterlist from a non-contiguous buffer allocated using, say `vmalloc`.

Another area of improvement is the way sectors to be given back are chosen by sequentially scanning the whole bitmap from start to the end. So in case of multiple iterations, it really causes O(n^2) lookups on the bitmap. This is grossly inefficient and can be easily improved. Maybe using a static variable to store the first invalid sector number and then scanning from there onwards would help.

## Conclusion
With this we come to the end of this manual. This work was done by Bhavesh Singh over a period of 6 months starting January 2017, as part of his Master's Thesis Project at IIT Bombay. The work was guided by Prof. Purushottam Kulkarni, IIT Bombay. Debadatta Mishra, a Ph.D student at IIT Bombay, gave helpful technical inputs during times of no progress. This documentation was written over a period of 4 days starting July 1st, 2017.
