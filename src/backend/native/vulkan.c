#include "volk.h"
typedef struct VolkInstanceTable VolkInstanceTable;
typedef struct VolkDeviceTable VolkDeviceTable;

typedef struct {
  VkInstance instance;
  VolkInstanceTable host;
  VkPhysicalDevice physical;
  VkDevice device;
  VolkDeviceTable api;
  VkQueue queue;
  VkCommandPool pool;
  VkCommandBuffer command;
  VkFence fence;
  VkPhysicalDeviceMemoryProperties memory;
  VkPhysicalDeviceProperties properties;
  VkPhysicalDeviceSubgroupProperties subgroup;
  uint32_t children;
} VulkanDevice;
typedef struct {
  VulkanDevice *owner;
  VkBuffer buffer;
  VkDeviceMemory memory;
  void *mapped;
  size_t size;
  uint32_t bindings;
} VulkanBuffer;
typedef struct {
  VulkanDevice *owner;
  VkShaderModule shader;
  VkDescriptorSetLayout layout;
  VkPipelineLayout pipelineLayout;
  VkPipeline pipeline;
  VkDescriptorPool pool;
  VkDescriptorSet set;
  VulkanBuffer **buffers;
  uint32_t arity, group, rows, layers;
  uint64_t limit;
  uint8_t dynamic, prepared;
} VulkanKernel;
static atomic_flag vulkan_gate = ATOMIC_FLAG_INIT;
static void vulkan_lock(void) {
  while (atomic_flag_test_and_set_explicit(&vulkan_gate, memory_order_acquire)) {}
}
static void vulkan_unlock(void) {
  atomic_flag_clear_explicit(&vulkan_gate, memory_order_release);
}
static VkInstance vulkan_instance(void) {
  VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
    .pApplicationName = "FOO", .apiVersion = VK_API_VERSION_1_1};
  uint32_t count = 0;
  const char *extensions[1];
  uint32_t enabled = 0;
  VkInstanceCreateFlags flags = 0;
  if (volkInitialize() != VK_SUCCESS) return VK_NULL_HANDLE;
  if (vkEnumerateInstanceExtensionProperties(NULL, &count, NULL) == VK_SUCCESS &&
      count && count < 4096) {
    VkExtensionProperties *available = calloc(count, sizeof(*available));
    if (!available) return VK_NULL_HANDLE;
    if (vkEnumerateInstanceExtensionProperties(NULL, &count, available) == VK_SUCCESS)
      for (uint32_t index = 0; index < count; index++)
        if (!strcmp(available[index].extensionName,
                    VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)) {
          extensions[enabled++] = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
          flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
          break;
        }
    free(available);
  }
  VkInstanceCreateInfo info = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
    .pApplicationInfo = &app, .flags = flags,
    .enabledExtensionCount = enabled,
    .ppEnabledExtensionNames = enabled ? extensions : NULL};
  VkInstance instance = VK_NULL_HANDLE;
  if (vkCreateInstance(&info, NULL, &instance) != VK_SUCCESS)
    return VK_NULL_HANDLE;
  return instance;
}
static int vulkan_compute(VolkInstanceTable *api, VkPhysicalDevice physical,
                          uint32_t *family) {
  uint32_t count = 0;
  api->vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, NULL);
  if (!count || count > 4096) return 0;
  VkQueueFamilyProperties *families = calloc(count, sizeof(*families));
  if (!families) return 0;
  api->vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, families);
  int found = 0;
  for (uint32_t index = 0; index < count; index++) {
    if (families[index].queueCount &&
        (families[index].queueFlags & VK_QUEUE_COMPUTE_BIT)) {
      *family = index;
      found = 1;
      break;
    }
  }
  free(families);
  return found;
}
static int vulkan_memory(VolkInstanceTable *api, VkPhysicalDevice physical,
                         VkPhysicalDeviceMemoryProperties *memory) {
  api->vkGetPhysicalDeviceMemoryProperties(physical, memory);
  for (uint32_t index = 0; index < memory->memoryTypeCount; index++)
    if ((memory->memoryTypes[index].propertyFlags &
         (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
          VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) ==
        (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
         VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) return 1;
  return 0;
}
static FooResult vulkan_select(uint64_t selected, int create) {
  vulkan_lock();
  VkInstance instance = vulkan_instance();
  if (!instance) {
    vulkan_unlock();
    return create ? failure(MISSING) : (FooResult){0};
  }
  VolkInstanceTable host;
  volkLoadInstanceTable(&host, instance);
  uint32_t count = 0;
  if (host.vkEnumeratePhysicalDevices(instance, &count, NULL) != VK_SUCCESS ||
      !count || count > 4096) {
    host.vkDestroyInstance(instance, NULL);
    vulkan_unlock(); return create ? failure(MISSING) : (FooResult){0};
  }
  VkPhysicalDevice *physical = calloc(count, sizeof(*physical));
  if (!physical) {
    host.vkDestroyInstance(instance, NULL);
    vulkan_unlock(); return failure(MEMORY);
  }
  VkResult status = host.vkEnumeratePhysicalDevices(instance, &count, physical);
  uint32_t family = 0;
  VkPhysicalDeviceMemoryProperties memory;
  VkPhysicalDevice chosen = VK_NULL_HANDLE;
  uint64_t eligible = 0;
  if (status == VK_SUCCESS)
    for (uint32_t index = 0; index < count; index++) {
      uint32_t candidate = 0;
      VkPhysicalDeviceProperties properties;
      host.vkGetPhysicalDeviceProperties(physical[index], &properties);
      if (properties.apiVersion < VK_API_VERSION_1_1) continue;
      if (!vulkan_compute(&host, physical[index], &candidate) ||
          !vulkan_memory(&host, physical[index], &memory)) continue;
      if (eligible == selected) {
        chosen = physical[index]; family = candidate;
        if (create) break;
      }
      eligible++;
    }
  free(physical);
  if (!chosen || !create) {
    host.vkDestroyInstance(instance, NULL);
    vulkan_unlock();
    return create ? failure(MISSING) : (FooResult){.number = eligible};
  }
  float priority = 1.0f;
  VkDeviceQueueCreateInfo queueInfo = {
    .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
    .queueFamilyIndex = family, .queueCount = 1, .pQueuePriorities = &priority};
  uint32_t extensionCount = 0;
  const char *deviceExtensions[1] = {NULL};
  if (host.vkEnumerateDeviceExtensionProperties(chosen, NULL,
      &extensionCount, NULL) == VK_SUCCESS && extensionCount &&
      extensionCount < 4096) {
    VkExtensionProperties *available = calloc(extensionCount, sizeof(*available));
    if (!available) {
      host.vkDestroyInstance(instance, NULL);
      vulkan_unlock(); return failure(MEMORY);
    }
    if (host.vkEnumerateDeviceExtensionProperties(chosen, NULL,
        &extensionCount, available) == VK_SUCCESS)
      for (uint32_t index = 0; index < extensionCount; index++)
        if (!strcmp(available[index].extensionName,
                    "VK_KHR_portability_subset")) {
          deviceExtensions[0] = "VK_KHR_portability_subset";
          break;
        }
    free(available);
  }
  VkDeviceCreateInfo deviceInfo = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
    .queueCreateInfoCount = 1, .pQueueCreateInfos = &queueInfo,
    .enabledExtensionCount = deviceExtensions[0] ? 1u : 0u,
    .ppEnabledExtensionNames = deviceExtensions[0] ? deviceExtensions : NULL};
  VkDevice device = VK_NULL_HANDLE;
  if (host.vkCreateDevice(chosen, &deviceInfo, NULL, &device) != VK_SUCCESS) {
    host.vkDestroyInstance(instance, NULL);
    vulkan_unlock(); return failure(SYSTEM);
  }
  VulkanDevice *result = owned(sizeof(*result), VULKAN_DEVICES);
  if (!result) {
    VolkDeviceTable api;
    volkLoadDeviceTable(&api, device);
    api.vkDestroyDevice(device, NULL);
    host.vkDestroyInstance(instance, NULL);
    vulkan_unlock(); return failure(MEMORY);
  }
  result->instance = instance;
  result->host = host;
  result->physical = chosen;
  result->device = device;
  result->memory = memory;
  volkLoadDeviceTable(&result->api, device);
  host.vkGetPhysicalDeviceProperties(chosen, &result->properties);
  if (host.vkGetPhysicalDeviceProperties2) {
    result->subgroup.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_PROPERTIES;
    VkPhysicalDeviceProperties2 properties = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
      .pNext = &result->subgroup};
    host.vkGetPhysicalDeviceProperties2(chosen, &properties);
  }
  result->api.vkGetDeviceQueue(device, family, 0, &result->queue);
  VkCommandPoolCreateInfo poolInfo = {
    .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
    .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
    .queueFamilyIndex = family};
  VkCommandBufferAllocateInfo commandInfo = {
    .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
    .commandPool = VK_NULL_HANDLE,
    .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
  VkFenceCreateInfo fenceInfo = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
  status = result->api.vkCreateCommandPool(device, &poolInfo, NULL, &result->pool);
  if (status == VK_SUCCESS) {
    commandInfo.commandPool = result->pool;
    status = result->api.vkAllocateCommandBuffers(device, &commandInfo,
                                                   &result->command);
  }
  if (status == VK_SUCCESS)
    status = result->api.vkCreateFence(device, &fenceInfo, NULL, &result->fence);
  if (status != VK_SUCCESS) {
    if (result->pool) result->api.vkDestroyCommandPool(device, result->pool, NULL);
    result->api.vkDestroyDevice(device, NULL);
    host.vkDestroyInstance(instance, NULL);
    Resource *entry = resource(result, VULKAN_DEVICES);
    if (entry) entry->closed = 1;
    vulkan_unlock(); return failure(SYSTEM);
  }
  vulkan_unlock();
  return (FooResult){.pointer = result};
}
FooResult foo_vulkan_available(void) {
  FooResult result = vulkan_select(0, 0);
  if (!result.error) result.number = result.number != 0;
  return result;
}
FooResult foo_vulkan_count(void) { return vulkan_select(0, 0); }
FooResult foo_vulkan_open(void) { return vulkan_select(0, 1); }
FooResult foo_vulkan_select(uint64_t index) { return vulkan_select(index, 1); }
FooResult foo_vulkan_name(void *pointer) {
  vulkan_lock();
  VulkanDevice *device = resource(pointer, VULKAN_DEVICES) ? pointer : NULL;
  FooResult result = device ? text(device->properties.deviceName,
      strlen(device->properties.deviceName)) : failure(CLOSED);
  vulkan_unlock();
  return result;
}
FooResult foo_vulkan_reserve(void *pointer, uint64_t size) {
  vulkan_lock();
  VulkanDevice *device = resource(pointer, VULKAN_DEVICES) ? pointer : NULL;
  if (!device) { vulkan_unlock(); return failure(CLOSED); }
  if (!size || size > SIZE_MAX || device->children == UINT32_MAX) {
    vulkan_unlock(); return failure(BOUNDS);
  }
  VulkanBuffer *result = owned(sizeof(*result), VULKAN_BUFFERS);
  if (!result) { vulkan_unlock(); return failure(MEMORY); }
  result->owner = device;
  result->size = (size_t)size;
  VkBufferCreateInfo info = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
    .size = size, .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
    .sharingMode = VK_SHARING_MODE_EXCLUSIVE};
  VkResult status = device->api.vkCreateBuffer(device->device, &info, NULL,
                                               &result->buffer);
  VkMemoryRequirements requirements;
  if (status == VK_SUCCESS)
    device->api.vkGetBufferMemoryRequirements(device->device, result->buffer,
                                              &requirements);
  uint32_t selected = UINT32_MAX;
  if (status == VK_SUCCESS)
    for (uint32_t index = 0; index < device->memory.memoryTypeCount; index++) {
      VkMemoryPropertyFlags flags = device->memory.memoryTypes[index].propertyFlags;
      if ((requirements.memoryTypeBits & (1u << index)) &&
          (flags & (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                    VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) ==
            (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
             VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
        if (selected == UINT32_MAX || (flags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT))
          selected = index;
        if (flags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) break;
      }
    }
  if (status == VK_SUCCESS && selected != UINT32_MAX) {
    VkMemoryAllocateInfo allocation = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = requirements.size, .memoryTypeIndex = selected};
    status = device->api.vkAllocateMemory(device->device, &allocation, NULL,
                                          &result->memory);
    if (status == VK_SUCCESS)
      status = device->api.vkBindBufferMemory(device->device, result->buffer,
                                              result->memory, 0);
    if (status == VK_SUCCESS)
      status = device->api.vkMapMemory(device->device, result->memory, 0,
                                       VK_WHOLE_SIZE, 0, &result->mapped);
  }
  if (status != VK_SUCCESS || selected == UINT32_MAX) {
    if (result->memory) device->api.vkFreeMemory(device->device, result->memory, NULL);
    if (result->buffer) device->api.vkDestroyBuffer(device->device, result->buffer, NULL);
    Resource *entry = resource(result, VULKAN_BUFFERS);
    if (entry) entry->closed = 1;
    vulkan_unlock(); return failure(selected == UINT32_MAX ? MISSING : SYSTEM);
  }
  device->children++;
  vulkan_unlock();
  return (FooResult){.pointer = result};
}
FooResult foo_vulkan_mapped(void *pointer) {
  vulkan_lock();
  VulkanBuffer *buffer = resource(pointer, VULKAN_BUFFERS) ? pointer : NULL;
  FooResult result = buffer
      ? (FooResult){.text = {(const uint8_t *)buffer->mapped, buffer->size}}
      : failure(CLOSED);
  vulkan_unlock();
  return result;
}
FooResult foo_vulkan_upload(void *pointer, FooText source) {
  vulkan_lock();
  VulkanBuffer *buffer = resource(pointer, VULKAN_BUFFERS) ? pointer : NULL;
  if (!buffer) { vulkan_unlock(); return failure(CLOSED); }
  if (!source.data || source.len != buffer->size) {
    vulkan_unlock(); return failure(ARGUMENT);
  }
  memcpy(buffer->mapped, source.data, buffer->size);
  vulkan_unlock(); return (FooResult){0};
}
FooResult foo_vulkan_download(void *pointer, FooText destination) {
  vulkan_lock();
  VulkanBuffer *buffer = resource(pointer, VULKAN_BUFFERS) ? pointer : NULL;
  if (!buffer) { vulkan_unlock(); return failure(CLOSED); }
  if (!destination.data || destination.len != buffer->size) {
    vulkan_unlock(); return failure(ARGUMENT);
  }
  memcpy((void *)destination.data, buffer->mapped, buffer->size);
  vulkan_unlock(); return (FooResult){0};
}
static VkResult vulkan_pipeline(VulkanKernel *kernel, uint32_t columns,
                                uint32_t rows, uint32_t layers,
                                VkPipeline *pipeline) {
  VulkanDevice *device = kernel->owner;
  VkSpecializationMapEntry entries[3] = {
    {0, 0, sizeof(uint32_t)},
    {1, sizeof(uint32_t), sizeof(uint32_t)},
    {2, 2 * sizeof(uint32_t), sizeof(uint32_t)}};
  uint32_t sizes[3] = {columns, rows, layers};
  VkSpecializationInfo specialization = {
    .mapEntryCount = 3, .pMapEntries = entries,
    .dataSize = sizeof(sizes), .pData = sizes};
  VkComputePipelineCreateInfo info = {
    .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
    .stage = {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
      .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = kernel->shader,
      .pName = "main",
      .pSpecializationInfo = kernel->dynamic ? &specialization : NULL},
    .layout = kernel->pipelineLayout};
  return device->api.vkCreateComputePipelines(device->device,
      VK_NULL_HANDLE, 1, &info, NULL, pipeline);
}
FooResult foo_vulkan_compile(void *pointer, FooText code, uint64_t bindings,
                             uint64_t group) {
  vulkan_lock();
  VulkanDevice *device = resource(pointer, VULKAN_DEVICES) ? pointer : NULL;
  if (!device) { vulkan_unlock(); return failure(CLOSED); }
  if (!code.data || code.len < 20 || code.len % 4 ||
      bindings == 0 || bindings > 32 || group == 0 ||
      group > device->properties.limits.maxComputeWorkGroupInvocations ||
      group > device->properties.limits.maxComputeWorkGroupSize[0] ||
      device->children == UINT32_MAX) {
    vulkan_unlock(); return failure(ARGUMENT);
  }
  uint32_t *words = malloc(code.len);
  if (!words) { vulkan_unlock(); return failure(MEMORY); }
  memcpy(words, code.data, code.len);
  if (words[0] != 0x07230203u) {
    free(words); vulkan_unlock(); return failure(ARGUMENT);
  }
  int localSize = 0, dynamic = 0;
  for (size_t index = 5; index < code.len / 4;) {
    uint32_t length = words[index] >> 16;
    if (!length || length > code.len / 4 - index) {
      free(words); vulkan_unlock(); return failure(ARGUMENT);
    }
    if ((words[index] & 0xffffu) == 16 && length >= 6 &&
        words[index + 2] == 17 && words[index + 3] == group &&
        words[index + 4] == 1 && words[index + 5] == 1)
      localSize = 1;
    if ((words[index] & 0xffffu) == 331 && length >= 6 &&
        words[index + 2] == 38)
      dynamic = 1;
    index += length;
  }
  if (!localSize && !dynamic) {
    free(words); vulkan_unlock(); return failure(ARGUMENT);
  }
  VulkanKernel *result = owned(sizeof(*result), VULKAN_KERNELS);
  if (!result) { free(words); vulkan_unlock(); return failure(MEMORY); }
  result->owner = device;
  result->arity = (uint32_t)bindings;
  result->group = (uint32_t)group;
  result->rows = 1;
  result->layers = 1;
  result->dynamic = dynamic;
  result->buffers = calloc(bindings, sizeof(*result->buffers));
  VkDescriptorSetLayoutBinding *slots = calloc(bindings, sizeof(*slots));
  if (!result->buffers || !slots) {
    free(result->buffers); free(slots); free(words);
    Resource *entry = resource(result, VULKAN_KERNELS);
    if (entry) entry->closed = 1;
    vulkan_unlock(); return failure(MEMORY);
  }
  for (uint32_t index = 0; index < bindings; index++) {
    slots[index].binding = index;
    slots[index].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    slots[index].descriptorCount = 1;
    slots[index].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
  }
  VkShaderModuleCreateInfo shaderInfo = {
    .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
    .codeSize = code.len, .pCode = words};
  VkDescriptorSetLayoutCreateInfo layoutInfo = {
    .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    .bindingCount = (uint32_t)bindings, .pBindings = slots};
  VkResult status = device->api.vkCreateShaderModule(device->device, &shaderInfo,
                                                      NULL, &result->shader);
  free(words);
  if (status == VK_SUCCESS)
    status = device->api.vkCreateDescriptorSetLayout(device->device,
        &layoutInfo, NULL, &result->layout);
  free(slots);
  VkPipelineLayoutCreateInfo pipelineInfo = {
    .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
    .setLayoutCount = 1, .pSetLayouts = &result->layout};
  if (status == VK_SUCCESS)
    status = device->api.vkCreatePipelineLayout(device->device, &pipelineInfo,
                                                NULL, &result->pipelineLayout);
  if (status == VK_SUCCESS)
    status = vulkan_pipeline(result, (uint32_t)group, 1, 1,
                             &result->pipeline);
  VkDescriptorPoolSize poolSize = {.type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
    .descriptorCount = (uint32_t)bindings};
  VkDescriptorPoolCreateInfo poolInfo = {
    .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
    .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &poolSize};
  if (status == VK_SUCCESS)
    status = device->api.vkCreateDescriptorPool(device->device, &poolInfo,
                                                NULL, &result->pool);
  VkDescriptorSetAllocateInfo setInfo = {
    .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
    .descriptorPool = result->pool, .descriptorSetCount = 1,
    .pSetLayouts = &result->layout};
  if (status == VK_SUCCESS)
    status = device->api.vkAllocateDescriptorSets(device->device, &setInfo,
                                                   &result->set);
  if (status != VK_SUCCESS) {
    if (result->pool) device->api.vkDestroyDescriptorPool(device->device, result->pool, NULL);
    if (result->pipeline) device->api.vkDestroyPipeline(device->device, result->pipeline, NULL);
    if (result->pipelineLayout) device->api.vkDestroyPipelineLayout(device->device, result->pipelineLayout, NULL);
    if (result->layout) device->api.vkDestroyDescriptorSetLayout(device->device, result->layout, NULL);
    if (result->shader) device->api.vkDestroyShaderModule(device->device, result->shader, NULL);
    free(result->buffers); result->buffers = NULL;
    Resource *entry = resource(result, VULKAN_KERNELS);
    if (entry) entry->closed = 1;
    vulkan_unlock(); return failure(SYSTEM);
  }
  device->children++;
  vulkan_unlock(); return (FooResult){.pointer = result};
}
FooResult foo_vulkan_bind(void *pointer, uint64_t index, void *memory) {
  vulkan_lock();
  VulkanKernel *kernel = resource(pointer, VULKAN_KERNELS) ? pointer : NULL;
  VulkanBuffer *buffer = resource(memory, VULKAN_BUFFERS) ? memory : NULL;
  if (!kernel || !buffer) { vulkan_unlock(); return failure(CLOSED); }
  if (index >= kernel->arity || buffer->owner != kernel->owner ||
      buffer->bindings == UINT32_MAX) {
    vulkan_unlock(); return failure(ARGUMENT);
  }
  VkDescriptorBufferInfo info = {.buffer = buffer->buffer,
    .offset = 0, .range = buffer->size};
  VkWriteDescriptorSet update = {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
    .dstSet = kernel->set, .dstBinding = (uint32_t)index,
    .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
    .pBufferInfo = &info};
  kernel->owner->api.vkUpdateDescriptorSets(kernel->owner->device, 1, &update,
                                             0, NULL);
  if (kernel->buffers[index]) kernel->buffers[index]->bindings--;
  kernel->buffers[index] = buffer;
  buffer->bindings++;
  vulkan_unlock(); return (FooResult){0};
}
static FooResult vulkan_run(void *pointer, const uint64_t extent[3],
                            const uint64_t shape[3]) {
  vulkan_lock();
  VulkanKernel *kernel = resource(pointer, VULKAN_KERNELS) ? pointer : NULL;
  if (!kernel) { vulkan_unlock(); return failure(CLOSED); }
  VulkanDevice *device = kernel->owner;
  uint32_t groups[3];
  uint64_t lanes = 1, count = 1;
  uint64_t wanted[3] = {shape[0] ? shape[0] : kernel->group,
    shape[1] ? shape[1] : kernel->rows,
    shape[2] ? shape[2] : kernel->layers};
  for (uint32_t axis = 0; axis < 3; axis++) {
    if (!extent[axis] || !wanted[axis] || wanted[axis] > UINT32_MAX ||
        wanted[axis] > device->properties.limits.maxComputeWorkGroupSize[axis] ||
        extent[axis] % wanted[axis] ||
        extent[axis] / wanted[axis] >
          device->properties.limits.maxComputeWorkGroupCount[axis] ||
        lanes > UINT64_MAX / wanted[axis] ||
        count > UINT64_MAX / extent[axis]) {
      vulkan_unlock(); return failure(BOUNDS);
    }
    lanes *= wanted[axis];
    count *= extent[axis];
    groups[axis] = (uint32_t)(extent[axis] / wanted[axis]);
  }
  if (lanes > device->properties.limits.maxComputeWorkGroupInvocations ||
      count > UINT32_MAX || count > SIZE_MAX / 4 ||
      (kernel->limit && lanes > kernel->limit)) {
    vulkan_unlock(); return failure(BOUNDS);
  }
  for (uint32_t index = 0; index < kernel->arity; index++)
    if (!kernel->buffers[index] ||
        (kernel->prepared && kernel->buffers[index]->size < count * 4)) {
      vulkan_unlock(); return failure(ARGUMENT);
    }
  if (kernel->group != wanted[0] || kernel->rows != wanted[1] ||
      kernel->layers != wanted[2]) {
    if (!kernel->dynamic) { vulkan_unlock(); return failure(ARGUMENT); }
    VkPipeline pipeline = VK_NULL_HANDLE;
    if (vulkan_pipeline(kernel, (uint32_t)wanted[0], (uint32_t)wanted[1],
                        (uint32_t)wanted[2], &pipeline) != VK_SUCCESS) {
      vulkan_unlock(); return failure(SYSTEM);
    }
    device->api.vkDestroyPipeline(device->device, kernel->pipeline, NULL);
    kernel->pipeline = pipeline;
    kernel->group = (uint32_t)wanted[0];
    kernel->rows = (uint32_t)wanted[1];
    kernel->layers = (uint32_t)wanted[2];
  }
  VkResult status = device->api.vkResetCommandPool(device->device, device->pool, 0);
  VkCommandBufferBeginInfo begin = {
    .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
    .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
  if (status == VK_SUCCESS)
    status = device->api.vkBeginCommandBuffer(device->command, &begin);
  if (status == VK_SUCCESS) {
    device->api.vkCmdBindPipeline(device->command,
        VK_PIPELINE_BIND_POINT_COMPUTE, kernel->pipeline);
    device->api.vkCmdBindDescriptorSets(device->command,
        VK_PIPELINE_BIND_POINT_COMPUTE, kernel->pipelineLayout,
        0, 1, &kernel->set, 0, NULL);
    device->api.vkCmdDispatch(device->command, groups[0], groups[1], groups[2]);
    status = device->api.vkEndCommandBuffer(device->command);
  }
  if (status == VK_SUCCESS)
    status = device->api.vkResetFences(device->device, 1, &device->fence);
  VkSubmitInfo submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
    .commandBufferCount = 1, .pCommandBuffers = &device->command};
  if (status == VK_SUCCESS)
    status = device->api.vkQueueSubmit(device->queue, 1, &submit, device->fence);
  if (status == VK_SUCCESS)
    status = device->api.vkWaitForFences(device->device, 1, &device->fence,
                                        VK_TRUE, UINT64_MAX);
  vulkan_unlock();
  return status == VK_SUCCESS ? (FooResult){0} : failure(SYSTEM);
}
FooResult foo_vulkan_launch(void *pointer, uint64_t count) {
  uint64_t extent[3] = {count, 1, 1}, shape[3] = {0, 1, 1};
  return vulkan_run(pointer, extent, shape);
}
FooResult foo_vulkan_dispatch(void *pointer, uint64_t count, uint64_t group) {
  uint64_t extent[3] = {count, 1, 1}, shape[3] = {group, 1, 1};
  return vulkan_run(pointer, extent, shape);
}
FooResult foo_vulkan_plane(void *pointer, uint64_t x, uint64_t y,
                            uint64_t columns, uint64_t rows) {
  uint64_t extent[3] = {x, y, 1}, shape[3] = {columns, rows, 1};
  return vulkan_run(pointer, extent, shape);
}
FooResult foo_vulkan_volume(void *pointer, uint64_t x, uint64_t y, uint64_t z,
                             uint64_t columns, uint64_t rows, uint64_t layers) {
  uint64_t extent[3] = {x, y, z}, shape[3] = {columns, rows, layers};
  return vulkan_run(pointer, extent, shape);
}
FooResult foo_vulkan_finish(void *pointer) {
  vulkan_lock();
  VulkanDevice *device = resource(pointer, VULKAN_DEVICES) ? pointer : NULL;
  if (!device) { vulkan_unlock(); return failure(CLOSED); }
  VkResult status = device->api.vkQueueWaitIdle(device->queue);
  vulkan_unlock();
  return status == VK_SUCCESS ? (FooResult){0} : failure(SYSTEM);
}
FooResult foo_vulkan_discard(void *pointer) {
  vulkan_lock();
  Resource *entry = resource(pointer, VULKAN_KERNELS);
  if (!entry) { vulkan_unlock(); return failure(CLOSED); }
  VulkanKernel *kernel = pointer;
  VulkanDevice *device = kernel->owner;
  for (uint32_t index = 0; index < kernel->arity; index++)
    if (kernel->buffers[index]) kernel->buffers[index]->bindings--;
  free(kernel->buffers); kernel->buffers = NULL;
  device->api.vkDestroyDescriptorPool(device->device, kernel->pool, NULL);
  device->api.vkDestroyPipeline(device->device, kernel->pipeline, NULL);
  device->api.vkDestroyPipelineLayout(device->device, kernel->pipelineLayout, NULL);
  device->api.vkDestroyDescriptorSetLayout(device->device, kernel->layout, NULL);
  device->api.vkDestroyShaderModule(device->device, kernel->shader, NULL);
  device->children--;
  entry->closed = 1;
  vulkan_unlock(); return (FooResult){0};
}
FooResult foo_vulkan_dispose(void *pointer) {
  vulkan_lock();
  Resource *entry = resource(pointer, VULKAN_BUFFERS);
  if (!entry) { vulkan_unlock(); return failure(CLOSED); }
  VulkanBuffer *buffer = pointer;
  if (buffer->bindings) { vulkan_unlock(); return failure(ARGUMENT); }
  VulkanDevice *device = buffer->owner;
  device->api.vkUnmapMemory(device->device, buffer->memory);
  device->api.vkDestroyBuffer(device->device, buffer->buffer, NULL);
  device->api.vkFreeMemory(device->device, buffer->memory, NULL);
  device->children--;
  entry->closed = 1;
  vulkan_unlock(); return (FooResult){0};
}
FooResult foo_vulkan_close(void *pointer) {
  vulkan_lock();
  Resource *entry = resource(pointer, VULKAN_DEVICES);
  if (!entry) { vulkan_unlock(); return failure(CLOSED); }
  VulkanDevice *device = pointer;
  if (device->children) { vulkan_unlock(); return failure(ARGUMENT); }
  if (device->api.vkDeviceWaitIdle(device->device) != VK_SUCCESS) {
    vulkan_unlock(); return failure(SYSTEM);
  }
  device->api.vkDestroyFence(device->device, device->fence, NULL);
  device->api.vkDestroyCommandPool(device->device, device->pool, NULL);
  device->api.vkDestroyDevice(device->device, NULL);
  device->host.vkDestroyInstance(device->instance, NULL);
  entry->closed = 1;
  vulkan_unlock(); return (FooResult){0};
}
