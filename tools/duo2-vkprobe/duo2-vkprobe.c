// duo2-vkprobe: is there a working Vulkan GPU, and what can it share?
//
// Creates a plain instance (no display extensions: Turnip's KGSL backend
// refuses VK_KHR_display), lists each physical device with its driver and
// memory, reports the extensions a compositor needs (dma-buf import/export,
// DRM identity), then runs a trivial command buffer to prove submission.
#include <stdio.h>
#include <string.h>
#include <vulkan/vulkan.h>

static int has_ext(VkPhysicalDevice pd, const char *name) {
    uint32_t n = 0;
    vkEnumerateDeviceExtensionProperties(pd, NULL, &n, NULL);
    VkExtensionProperties ext[512];
    if (n > 512) n = 512;
    vkEnumerateDeviceExtensionProperties(pd, NULL, &n, ext);
    for (uint32_t i = 0; i < n; i++)
        if (!strcmp(ext[i].extensionName, name)) return 1;
    return 0;
}

int main(void) {
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                              .pApplicationName = "duo2-vkprobe", .apiVersion = VK_API_VERSION_1_3 };
    VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    VkInstance inst;
    VkResult r = vkCreateInstance(&ici, NULL, &inst);
    if (r) { printf("vkCreateInstance: %d\n", r); return 1; }
    uint32_t n = 0;
    r = vkEnumeratePhysicalDevices(inst, &n, NULL);
    printf("physical devices: %u (%d)\n", n, r);
    VkPhysicalDevice pds[8];
    if (n > 8) n = 8;
    vkEnumeratePhysicalDevices(inst, &n, pds);
    for (uint32_t i = 0; i < n; i++) {
        VkPhysicalDeviceDriverProperties drv = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES };
        VkPhysicalDeviceProperties2 p2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &drv };
        vkGetPhysicalDeviceProperties2(pds[i], &p2);
        VkPhysicalDeviceMemoryProperties mem;
        vkGetPhysicalDeviceMemoryProperties(pds[i], &mem);
        printf("[%u] %s  (driver %s %s, API %u.%u.%u)\n", i, p2.properties.deviceName, drv.driverName,
               drv.driverInfo, VK_VERSION_MAJOR(p2.properties.apiVersion),
               VK_VERSION_MINOR(p2.properties.apiVersion), VK_VERSION_PATCH(p2.properties.apiVersion));
        for (uint32_t h = 0; h < mem.memoryHeapCount; h++)
            printf("    heap %u: %llu MiB\n", h, (unsigned long long)(mem.memoryHeaps[h].size >> 20));
        const char *want[] = { "VK_KHR_external_memory_fd", "VK_EXT_external_memory_dma_buf",
                               "VK_EXT_image_drm_format_modifier", "VK_EXT_physical_device_drm",
                               "VK_KHR_swapchain", "VK_EXT_queue_family_foreign" };
        for (unsigned k = 0; k < sizeof want / sizeof *want; k++)
            printf("    %-36s %s\n", want[k], has_ext(pds[i], want[k]) ? "yes" : "no");

        // One empty submission, waited on with a fence: the GPU runs work.
        float prio = 1.0f;
        VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                        .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &prio };
        VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1,
                                   .pQueueCreateInfos = &qci };
        VkDevice dev;
        if ((r = vkCreateDevice(pds[i], &dci, NULL, &dev))) { printf("    vkCreateDevice: %d\n", r); continue; }
        VkQueue q; vkGetDeviceQueue(dev, 0, 0, &q);
        VkCommandPoolCreateInfo cpi = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = 0 };
        VkCommandPool pool; vkCreateCommandPool(dev, &cpi, NULL, &pool);
        VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                                            .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                                            .commandBufferCount = 1 };
        VkCommandBuffer cb; vkAllocateCommandBuffers(dev, &cai, &cb);
        VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
        vkBeginCommandBuffer(cb, &bi); vkEndCommandBuffer(cb);
        VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
        VkFence f; vkCreateFence(dev, &fci, NULL, &f);
        VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
        r = vkQueueSubmit(q, 1, &si, f);
        VkResult w = vkWaitForFences(dev, 1, &f, VK_TRUE, 2000000000ull);
        printf("    submit %d, fence %s\n", r, w == VK_SUCCESS ? "signalled: the GPU executed work" : "NOT signalled");
        vkDestroyFence(dev, f, NULL); vkDestroyCommandPool(dev, pool, NULL); vkDestroyDevice(dev, NULL);
    }
    vkDestroyInstance(inst, NULL);
    return 0;
}
