/* FOO's checked kernel interface over the Vulkan compute adapter. */
FooResult foo_gpu_available(void) { return foo_vulkan_available(); }
FooResult foo_gpu_open(void) { return foo_vulkan_open(); }
FooResult foo_gpu_name(void *device) { return foo_vulkan_name(device); }
FooResult foo_gpu_capacity(void *pointer) {
  vulkan_lock();
  VulkanDevice *device = resource(pointer, VULKAN_DEVICES) ? pointer : NULL;
  FooResult result = device
      ? (FooResult){.number = device->properties.limits.maxComputeWorkGroupInvocations}
      : failure(CLOSED);
  vulkan_unlock();
  return result;
}
FooResult foo_gpu_supports(void *pointer, FooText feature) {
  vulkan_lock();
  VulkanDevice *device = resource(pointer, VULKAN_DEVICES) ? pointer : NULL;
  if (!device) { vulkan_unlock(); return failure(CLOSED); }
  uint64_t supported = 0;
  if (cpu_named(feature, "shared"))
    supported = device->properties.limits.maxComputeSharedMemorySize > 0;
  else if (cpu_named(feature, "atomic")) supported = 1;
  else if (cpu_named(feature, "subgroup"))
    supported = (device->subgroup.supportedStages & VK_SHADER_STAGE_COMPUTE_BIT) &&
      (device->subgroup.supportedOperations & VK_SUBGROUP_FEATURE_BALLOT_BIT);
  else if (cpu_named(feature, "event")) supported = 0;
  else if (cpu_named(feature, "mapping")) supported = 1;
  vulkan_unlock();
  return (FooResult){.number = supported};
}
FooResult foo_gpu_reserve(void *device, uint64_t size) {
  return foo_vulkan_reserve(device, size);
}
FooResult foo_gpu_mapped(void *buffer) { return foo_vulkan_mapped(buffer); }
FooResult foo_gpu_mutable(void *buffer) { return foo_vulkan_mapped(buffer); }
FooResult foo_gpu_upload(void *buffer, FooText source) {
  return foo_vulkan_upload(buffer, source);
}
FooResult foo_gpu_download(void *buffer, FooText destination) {
  return foo_vulkan_download(buffer, destination);
}
static FooResult gpu_transfer(void *pointer, FooText data, int read) {
  if (!data.data || data.len > SIZE_MAX / 4) return failure(ARGUMENT);
  FooText bytes = {data.data, data.len * 4};
  return read ? foo_vulkan_download(pointer, bytes) :
      foo_vulkan_upload(pointer, bytes);
}
FooResult foo_gpu_send(void *buffer, FooText source) {
  return gpu_transfer(buffer, source, 0);
}
FooResult foo_gpu_receive(void *buffer, FooText destination) {
  return gpu_transfer(buffer, destination, 1);
}
FooResult foo_gpu_push(void *buffer, FooText source) {
  return gpu_transfer(buffer, source, 0);
}
FooResult foo_gpu_pull(void *buffer, FooText destination) {
  return gpu_transfer(buffer, destination, 1);
}
FooResult foo_gpu_prepared(void *pointer, FooText source, FooText entry,
                           FooText widths, uint64_t localLimit,
                           uint64_t requirements, uint64_t localBytes) {
  if (!source.data || !entry.data || !entry.len || !widths.data ||
      !widths.len || widths.len > 32 || (requirements & ~7ULL))
    return failure(ARGUMENT);
  for (size_t index = 0; index < widths.len; index++)
    if (widths.data[index] != '4') return failure(ARGUMENT);
  vulkan_lock();
  VulkanDevice *device = resource(pointer, VULKAN_DEVICES) ? pointer : NULL;
  if (!device) { vulkan_unlock(); return failure(CLOSED); }
  uint64_t shared = device->properties.limits.maxComputeSharedMemorySize;
  int subgroup = (device->subgroup.supportedStages & VK_SHADER_STAGE_COMPUTE_BIT) &&
    (device->subgroup.supportedOperations & VK_SUBGROUP_FEATURE_BALLOT_BIT);
  if ((requirements & 1 && !shared) ||
      (requirements & 4 && !subgroup)) {
    vulkan_unlock(); return failure(MISSING);
  }
  if (localBytes > shared) {
    vulkan_unlock(); return failure(BOUNDS);
  }
  vulkan_unlock();
  FooResult result = foo_vulkan_compile(pointer, source, widths.len, 1);
  if (result.error) return result;
  vulkan_lock();
  VulkanKernel *kernel = resource(result.pointer, VULKAN_KERNELS)
      ? result.pointer : NULL;
  if (kernel) {
    kernel->prepared = 1;
    kernel->limit = localLimit;
  }
  vulkan_unlock();
  return result;
}
FooResult foo_gpu_bind(void *kernel, uint64_t index, void *buffer) {
  return foo_vulkan_bind(kernel, index, buffer);
}
FooResult foo_gpu_launch(void *kernel, uint64_t count) {
  return foo_vulkan_launch(kernel, count);
}
FooResult foo_gpu_dispatch(void *kernel, uint64_t count, uint64_t group) {
  return group ? foo_vulkan_dispatch(kernel, count, group) : failure(ARGUMENT);
}
FooResult foo_gpu_plane(void *kernel, uint64_t x, uint64_t y,
                        uint64_t columns, uint64_t rows) {
  return foo_vulkan_plane(kernel, x, y, columns, rows);
}
FooResult foo_gpu_volume(void *kernel, uint64_t x, uint64_t y, uint64_t z,
                         uint64_t columns, uint64_t rows, uint64_t layers) {
  return foo_vulkan_volume(kernel, x, y, z, columns, rows, layers);
}
FooResult foo_gpu_finish(void *device) { return foo_vulkan_finish(device); }
FooResult foo_gpu_discard(void *kernel) { return foo_vulkan_discard(kernel); }
FooResult foo_gpu_dispose(void *buffer) { return foo_vulkan_dispose(buffer); }
FooResult foo_gpu_close(void *device) { return foo_vulkan_close(device); }
