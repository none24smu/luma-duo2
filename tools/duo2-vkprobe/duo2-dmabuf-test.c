// duo2-dmabuf-test: does the GPU write into the display's buffers?
//
// Allocates a scanout buffer on the display device with GBM (as wlroots
// does), imports its dma-buf into Vulkan as external memory, has the GPU fill
// it with a known pattern, then maps the GBM buffer on the CPU and checks the
// pattern arrived. Proves the KGSL/Turnip <-> display dma-buf path end to end.
#include <fcntl.h>
#include <gbm.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

#define CHECK(x) do { VkResult r_ = (x); if (r_) { printf("%s: %d\n", #x, r_); return 1; } } while (0)

int main(void) {
    int drm = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    struct gbm_device *g = gbm_create_device(drm);
    struct gbm_bo *bo = gbm_bo_create(g, 1344, 1892, GBM_FORMAT_XRGB8888,
                                      GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING | GBM_BO_USE_LINEAR);
    if (!bo) { printf("gbm_bo_create failed\n"); return 1; }
    uint32_t stride = gbm_bo_get_stride(bo);
    VkDeviceSize size = (VkDeviceSize)stride * 1892;
    int fd = gbm_bo_get_fd(bo);
    printf("GBM scanout buffer: stride %u, %llu bytes, dma-buf fd %d\n", stride, (unsigned long long)size, fd);

    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_1 };
    VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    VkInstance inst; CHECK(vkCreateInstance(&ici, NULL, &inst));
    uint32_t n = 1; VkPhysicalDevice pd; vkEnumeratePhysicalDevices(inst, &n, &pd);
    if (!n) { printf("no Vulkan device\n"); return 1; }
    const char *exts[] = { "VK_KHR_external_memory_fd", "VK_EXT_external_memory_dma_buf" };
    float prio = 1;
    VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
    VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
                               .enabledExtensionCount = 2, .ppEnabledExtensionNames = exts };
    VkDevice dev; CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
    VkQueue q; vkGetDeviceQueue(dev, 0, 0, &q);

    VkExternalMemoryBufferCreateInfo ebi = { .sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO,
                                             .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT };
    VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .pNext = &ebi, .size = size,
                               .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
    VkBuffer buf; CHECK(vkCreateBuffer(dev, &bci, NULL, &buf));
    VkMemoryRequirements req; vkGetBufferMemoryRequirements(dev, buf, &req);
    PFN_vkGetMemoryFdPropertiesKHR getfdprops = (PFN_vkGetMemoryFdPropertiesKHR)vkGetDeviceProcAddr(dev, "vkGetMemoryFdPropertiesKHR");
    VkMemoryFdPropertiesKHR fdp = { .sType = VK_STRUCTURE_TYPE_MEMORY_FD_PROPERTIES_KHR };
    CHECK(getfdprops(dev, VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, fd, &fdp));
    uint32_t type = 0; uint32_t bits = req.memoryTypeBits & fdp.memoryTypeBits;
    while (type < 32 && !(bits & (1u << type))) type++;
    VkImportMemoryFdInfoKHR imp = { .sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR,
                                    .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, .fd = dup(fd) };
    VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .pNext = &imp,
                                 .allocationSize = req.size > size ? req.size : size, .memoryTypeIndex = type };
    VkDeviceMemory mem; CHECK(vkAllocateMemory(dev, &mai, NULL, &mem));
    CHECK(vkBindBufferMemory(dev, buf, mem, 0));
    printf("imported into Vulkan (memory type %u)\n", type);

    VkCommandPoolCreateInfo cpi = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
    VkCommandPool pool; vkCreateCommandPool(dev, &cpi, NULL, &pool);
    VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
                                        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    VkCommandBuffer cb; vkAllocateCommandBuffers(dev, &cai, &cb);
    VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    vkBeginCommandBuffer(cb, &bi);
    vkCmdFillBuffer(cb, buf, 0, size, 0xff00a0ffu);   // XRGB: opaque, R=00 G=a0 B=ff (Luma-ish blue)
    vkEndCommandBuffer(cb);
    VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence f; vkCreateFence(dev, &fci, NULL, &f);
    VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
    CHECK(vkQueueSubmit(q, 1, &si, f));
    CHECK(vkWaitForFences(dev, 1, &f, VK_TRUE, 2000000000ull));

    uint32_t mstride; void *map_data = NULL;
    uint32_t *px = gbm_bo_map(bo, 0, 0, 1344, 1892, GBM_BO_TRANSFER_READ, &mstride, &map_data);
    if (!px) { printf("gbm_bo_map failed\n"); return 1; }
    uint32_t a = px[0], b = px[(mstride / 4) * 946 + 672], c = px[(mstride / 4) * 1891 + 1343];
    printf("CPU reads back: first 0x%08x, centre 0x%08x, last 0x%08x -> %s\n", a, b, c,
           a == 0xff00a0ff && b == 0xff00a0ff && c == 0xff00a0ff ? "GPU wrote the display buffer" : "MISMATCH");
    gbm_bo_unmap(bo, map_data);
    return 0;
}
