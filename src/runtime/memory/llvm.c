typedef struct foo_storage {
    void *data;
    struct foo_storage *next;
} foo_storage;

typedef struct { foo_storage *head; } foo_region;

static float foo_f32(uint32_t bits) {
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static double foo_f64(uint64_t bits) {
    double value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static void *foo_reserve(foo_region *region, size_t size) {
    foo_storage *entry = malloc(sizeof(*entry));
    if (!entry) return NULL;
    entry->data = calloc(size ? size : 1, 1);
    if (!entry->data) { free(entry); return NULL; }
    entry->next = region->head;
    region->head = entry;
    return entry->data;
}

static void foo_close(foo_region *region) {
    while (region->head) {
        foo_storage *entry = region->head;
        region->head = entry->next;
        free(entry->data);
        free(entry);
    }
}
