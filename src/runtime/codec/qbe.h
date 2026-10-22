/* QBE's typed layout descriptor feeds the shared JSON parser and writer. */
typedef struct {
    const uint8_t *next, *end;
    const char *error;
} foo_qbe_codec_schema;

static const uint8_t *foo_qbe_codec_take(foo_qbe_codec_schema *schema,
    size_t count) {
    if (schema->error || count > (size_t)(schema->end - schema->next)) {
        schema->error = "InvalidSchema";
        return NULL;
    }
    const uint8_t *value = schema->next;
    schema->next += count;
    return value;
}

static uint32_t foo_qbe_codec_word(foo_qbe_codec_schema *schema, size_t size) {
    const uint8_t *bytes = foo_qbe_codec_take(schema, size);
    uint32_t value = 0;
    if (bytes)
        for (size_t index = 0; index < size; ++index)
            value |= (uint32_t)bytes[index] << (index * 8);
    return value;
}

static void foo_qbe_codec_limit(uint8_t limit[16], unsigned bits,
    bool signed_value, bool negative) {
    memset(limit, 0, 16);
    unsigned magnitude_bits = signed_value ? bits - 1 : bits;
    for (unsigned bit = 0; bit < magnitude_bits; ++bit)
        limit[bit >> 3] |= (uint8_t)(1u << (bit & 7));
    if (signed_value) {
        limit[(bits - 1) >> 3] &=
            (uint8_t)~(1u << ((bits - 1) & 7));
        if (negative) {
            memset(limit, 0, 16);
            limit[(bits - 1) >> 3] =
                (uint8_t)(1u << ((bits - 1) & 7));
        }
    }
}

static bool foo_qbe_codec_wide_exceeds(const uint8_t value[16],
    const uint8_t limit[16]) {
    for (int index = 15; index >= 0; --index) {
        if (value[index] != limit[index])
            return value[index] > limit[index];
    }
    return false;
}

static void foo_qbe_codec_wide_negate(uint8_t value[16]) {
    unsigned carry = 1;
    for (unsigned index = 0; index < 16; ++index) {
        unsigned next = (unsigned)(uint8_t)~value[index] + carry;
        value[index] = (uint8_t)next;
        carry = next >> 8;
    }
}

static const char *foo_qbe_codec_write_wide(const uint8_t *value,
    unsigned bits, bool signed_value, FOOWriter *writer) {
    uint8_t number[16], limit[16];
    memcpy(number, value, 16);
    bool negative = signed_value &&
        ((number[(bits - 1) >> 3] >> ((bits - 1) & 7)) & 1u);
    if (negative) foo_qbe_codec_wide_negate(number);
    foo_qbe_codec_limit(limit, bits, false, false);
    for (unsigned index = 0; index < 16; ++index)
        number[index] &= limit[index];
    char digits[40];
    size_t count = 0;
    do {
        unsigned remainder = 0;
        for (int index = 15; index >= 0; --index) {
            unsigned dividend = (remainder << 8) | number[index];
            number[index] = (uint8_t)(dividend / 10);
            remainder = dividend % 10;
        }
        digits[count++] = (char)('0' + remainder);
        bool more = false;
        for (unsigned index = 0; index < 16; ++index)
            more |= number[index] != 0;
        if (!more) break;
    } while (count < sizeof(digits));
    if (negative) foo_put(writer, "-", 1);
    while (count) foo_put(writer, &digits[--count], 1);
    return writer->failed ? "OutOfMemory" : NULL;
}

static const char *foo_qbe_codec_read_wide(const FOOJson *node,
    uint8_t *value, unsigned bits, bool signed_value) {
    if (node->kind != 'd') return "ExpectedNumber";
    bool negative = node->raw.len && node->raw.data[0] == '-';
    if (negative && !signed_value) return "NumberOverflow";
    size_t start = negative ? 1 : 0;
    if (start == node->raw.len) return "NumberOverflow";
    uint8_t number[16] = {0}, limit[16];
    for (size_t index = start; index < node->raw.len; ++index) {
        uint8_t digit = node->raw.data[index];
        if (digit < '0' || digit > '9') return "NumberOverflow";
        unsigned carry = digit - '0';
        for (unsigned part = 0; part < 16; ++part) {
            unsigned next = number[part] * 10u + carry;
            number[part] = (uint8_t)next;
            carry = next >> 8;
        }
        if (carry) return "NumberOverflow";
    }
    foo_qbe_codec_limit(limit, bits, signed_value, negative);
    if (foo_qbe_codec_wide_exceeds(number, limit)) return "NumberOverflow";
    if (negative) foo_qbe_codec_wide_negate(number);
    memcpy(value, number, 16);
    return NULL;
}

static void foo_qbe_codec_bits_get(uint8_t result[16],
    const uint8_t *source, uint32_t offset, uint32_t bits) {
    memset(result, 0, 16);
    for (uint32_t bit = 0; bit < bits; ++bit) {
        uint32_t position = offset + bit;
        result[bit >> 3] |= (uint8_t)(((source[position >> 3] >>
            (position & 7)) & 1u) << (bit & 7));
    }
}

static void foo_qbe_codec_bits_set(uint8_t *destination, uint32_t offset,
    uint32_t bits, const uint8_t source[16]) {
    for (uint32_t bit = 0; bit < bits; ++bit) {
        uint32_t position = offset + bit;
        uint8_t mask = (uint8_t)(1u << (position & 7));
        if ((source[bit >> 3] >> (bit & 7)) & 1u)
            destination[position >> 3] |= mask;
        else destination[position >> 3] &= (uint8_t)~mask;
    }
}

static const char *foo_qbe_codec_write(foo_qbe_codec_schema *schema,
    const uint8_t *value, FOOWriter *writer, unsigned depth) {
    if (depth >= 256) return "JsonDepthExceeded";
    const uint8_t *kind = foo_qbe_codec_take(schema, 1);
    if (!kind) return schema->error;
    switch (*kind) {
    case 'V':
        foo_put(writer, "{}", 2);
        break;
    case 'B': {
        uint8_t enabled;
        memcpy(&enabled, value, sizeof(enabled));
        foo_put(writer, enabled ? "true" : "false", enabled ? 4 : 5);
        break;
    }
    case 'U':
    case 'I': {
        uint32_t width = foo_qbe_codec_word(schema, 1);
        uint32_t bits = foo_qbe_codec_word(schema, 1);
        uint64_t number = 0;
        if (schema->error || width == 0 || width > 16 ||
            (width & (width - 1)) != 0 || bits == 0 || bits > width * 8)
            return "InvalidSchema";
        if (width == 16)
            return foo_qbe_codec_write_wide(value, bits, *kind == 'I', writer);
        memcpy(&number, value, width);
        if (bits < 64) number &= (UINT64_C(1) << bits) - 1;
        char buffer[32];
        int length;
        if (*kind == 'I') {
            if (bits < 64 && (number & (UINT64_C(1) << (bits - 1))))
                number |= UINT64_MAX << bits;
            length = snprintf(buffer, sizeof(buffer), "%lld",
                (long long)(int64_t)number);
        } else {
            length = snprintf(buffer, sizeof(buffer), "%llu",
                (unsigned long long)number);
        }
        if (length < 0 || (size_t)length >= sizeof(buffer))
            return "NumberOverflow";
        foo_put(writer, buffer, (size_t)length);
        break;
    }
    case 'T': {
        foo_qbe_slice text;
        memcpy(&text, value, sizeof(text));
        if (text.length > SIZE_MAX || (text.length && !text.data))
            return "InvalidText";
        FOOText source = {text.data, (size_t)text.length};
        if (!foo_unicode_valid(source)) return "InvalidUtf8";
        foo_quote(writer, source);
        break;
    }
    case 'S': {
        uint32_t stride = foo_qbe_codec_word(schema, 4);
        uint32_t alignment = foo_qbe_codec_word(schema, 4);
        uint32_t child_length = foo_qbe_codec_word(schema, 4);
        const uint8_t *element = foo_qbe_codec_take(schema, child_length);
        if (!element || !stride || !alignment || !child_length)
            return "InvalidSchema";
        foo_qbe_slice sequence;
        memcpy(&sequence, value, sizeof(sequence));
        if (sequence.length > SIZE_MAX / stride ||
            (sequence.length && !sequence.data)) return "InvalidSequence";
        foo_put(writer, "[", 1);
        for (uint64_t index = 0; index < sequence.length; ++index) {
            if (index) foo_put(writer, ",", 1);
            foo_qbe_codec_schema child = {element, element + child_length, NULL};
            const char *error = foo_qbe_codec_write(&child,
                sequence.data + (size_t)index * stride, writer, depth + 1);
            if (error) return error;
            if (child.next != child.end) return "InvalidSchema";
        }
        foo_put(writer, "]", 1);
        break;
    }
    case 'A': {
        uint32_t count = foo_qbe_codec_word(schema, 4);
        uint32_t stride = foo_qbe_codec_word(schema, 4);
        uint32_t child_length = foo_qbe_codec_word(schema, 4);
        const uint8_t *element = foo_qbe_codec_take(schema, child_length);
        if (!element || !stride || !child_length) return "InvalidSchema";
        foo_put(writer, "[", 1);
        for (uint32_t index = 0; index < count; ++index) {
            if (index) foo_put(writer, ",", 1);
            foo_qbe_codec_schema child = {element, element + child_length, NULL};
            const char *error = foo_qbe_codec_write(&child,
                value + (size_t)index * stride, writer, depth + 1);
            if (error) return error;
            if (child.next != child.end) return "InvalidSchema";
        }
        foo_put(writer, "]", 1);
        break;
    }
    case 'O': {
        uint32_t offset = foo_qbe_codec_word(schema, 4);
        uint32_t child_length = foo_qbe_codec_word(schema, 4);
        const uint8_t *element = foo_qbe_codec_take(schema, child_length);
        if (!element || !child_length) return "InvalidSchema";
        if (!*value) {
            foo_put(writer, "null", 4);
        } else {
            foo_qbe_codec_schema child = {element, element + child_length, NULL};
            const char *error = foo_qbe_codec_write(&child, value + offset,
                writer, depth + 1);
            if (error) return error;
            if (child.next != child.end) return "InvalidSchema";
        }
        break;
    }
    case 'R': {
        uint32_t count = foo_qbe_codec_word(schema, 2);
        if (schema->error) return schema->error;
        foo_put(writer, "{", 1);
        for (uint32_t index = 0; index < count; ++index) {
            uint32_t offset = foo_qbe_codec_word(schema, 4);
            uint32_t length = foo_qbe_codec_word(schema, 2);
            const uint8_t *name = foo_qbe_codec_take(schema, length);
            if (!name) return schema->error;
            if (index) foo_put(writer, ",", 1);
            foo_quote(writer, (FOOText){name, length});
            foo_put(writer, ":", 1);
            const char *error = foo_qbe_codec_write(schema, value + offset,
                writer, depth + 1);
            if (error) return error;
        }
        foo_put(writer, "}", 1);
        break;
    }
    case 'C': {
        uint32_t count = foo_qbe_codec_word(schema, 2);
        uint32_t offset = foo_qbe_codec_word(schema, 4);
        uint32_t tag = 0;
        memcpy(&tag, value, sizeof(tag));
        if (schema->error || !count || tag >= count)
            return "InvalidChoiceTag";
        foo_put(writer, "{", 1);
        for (uint32_t index = 0; index < count; ++index) {
            uint32_t name_length = foo_qbe_codec_word(schema, 2);
            const uint8_t *name = foo_qbe_codec_take(schema, name_length);
            uint32_t child_length = foo_qbe_codec_word(schema, 4);
            const uint8_t *child = foo_qbe_codec_take(schema, child_length);
            if (!name || !child || !name_length || !child_length)
                return "InvalidSchema";
            if (index != tag) continue;
            foo_quote(writer, (FOOText){name, name_length});
            foo_put(writer, ":", 1);
            foo_qbe_codec_schema member = {child, child + child_length, NULL};
            const char *error = foo_qbe_codec_write(&member, value + offset,
                writer, depth + 1);
            if (error) return error;
            if (member.next != member.end) return "InvalidSchema";
        }
        foo_put(writer, "}", 1);
        break;
    }
    case 'P': {
        uint32_t count = foo_qbe_codec_word(schema, 2);
        if (schema->error) return schema->error;
        foo_put(writer, "{", 1);
        for (uint32_t index = 0; index < count; ++index) {
            uint32_t offset = foo_qbe_codec_word(schema, 4);
            uint32_t bits = foo_qbe_codec_word(schema, 2);
            uint32_t name_length = foo_qbe_codec_word(schema, 2);
            const uint8_t *name = foo_qbe_codec_take(schema, name_length);
            uint32_t child_length = foo_qbe_codec_word(schema, 4);
            const uint8_t *child = foo_qbe_codec_take(schema, child_length);
            if (!name || !child || !name_length || !child_length ||
                !bits || bits > 128 || offset > UINT32_MAX - bits)
                return "InvalidSchema";
            if (index) foo_put(writer, ",", 1);
            foo_quote(writer, (FOOText){name, name_length});
            foo_put(writer, ":", 1);
            uint8_t field[16];
            foo_qbe_codec_bits_get(field, value, offset, bits);
            foo_qbe_codec_schema member = {child, child + child_length, NULL};
            const char *error = foo_qbe_codec_write(&member, field,
                writer, depth + 1);
            if (error) return error;
            if (member.next != member.end) return "InvalidSchema";
        }
        foo_put(writer, "}", 1);
        break;
    }
    default: return "InvalidSchema";
    }
    return writer->failed ? "OutOfMemory" : NULL;
}

typedef struct {
    foo_qbe_allocation *text, *sequence;
} foo_qbe_codec_owned;

static const char *foo_qbe_codec_read(foo_qbe_codec_schema *schema,
    const FOOJson *node, uint8_t *value, foo_qbe_codec_owned *owned,
    unsigned depth) {
    if (depth >= 256) return "JsonDepthExceeded";
    const uint8_t *kind = foo_qbe_codec_take(schema, 1);
    if (!kind) return schema->error;
    switch (*kind) {
    case 'V':
        return node->kind == '{' && !node->child ? NULL : "ExpectedObject";
    case 'B': {
        if (node->kind != 't' && node->kind != 'f')
            return "ExpectedBoolean";
        *value = node->kind == 't';
        return NULL;
    }
    case 'U':
    case 'I': {
        uint32_t width = foo_qbe_codec_word(schema, 1);
        uint32_t bits = foo_qbe_codec_word(schema, 1);
        if (schema->error || width == 0 || width > 16 ||
            (width & (width - 1)) != 0 || bits == 0 || bits > width * 8)
            return "InvalidSchema";
        if (width == 16)
            return foo_qbe_codec_read_wide(node, value, bits, *kind == 'I');
        if (node->kind != 'd') return "ExpectedNumber";
        bool negative = node->raw.len && node->raw.data[0] == '-';
        if (negative && *kind == 'U') return "NumberOverflow";
        uint64_t maximum = bits == 64 ? UINT64_MAX :
            (UINT64_C(1) << bits) - 1;
        if (*kind == 'I') maximum >>= 1;
        uint64_t limit = maximum + (negative && *kind == 'I');
        uint64_t number = 0;
        size_t start = negative ? 1 : 0;
        if (start == node->raw.len) return "NumberOverflow";
        for (size_t index = start; index < node->raw.len; ++index) {
            uint8_t digit = node->raw.data[index];
            if (digit < '0' || digit > '9' ||
                (uint64_t)(digit - '0') > limit ||
                number > (limit - (digit - '0')) / 10)
                return "NumberOverflow";
            number = number * 10 + digit - '0';
        }
        if (negative) number = ~number + 1;
        memcpy(value, &number, width);
        return NULL;
    }
    case 'T': {
        if (node->kind != 's') return "ExpectedText";
        if (node->raw.len == 0) return NULL;
        uint8_t *copy = foo_qbe_reserve(&owned->text, node->raw.len, 1);
        if (!copy) return "OutOfMemory";
        memcpy(copy, node->raw.data, node->raw.len);
        foo_qbe_slice text = {copy, node->raw.len};
        memcpy(value, &text, sizeof(text));
        return NULL;
    }
    case 'S': {
        uint32_t stride = foo_qbe_codec_word(schema, 4);
        uint32_t alignment = foo_qbe_codec_word(schema, 4);
        uint32_t child_length = foo_qbe_codec_word(schema, 4);
        const uint8_t *element = foo_qbe_codec_take(schema, child_length);
        if (!element || !stride || !alignment ||
            (alignment & (alignment - 1)) != 0 || !child_length)
            return "InvalidSchema";
        if (node->kind != '[') return "ExpectedSequence";
        size_t count = 0;
        for (const FOOJson *child = node->child; child; child = child->next) {
            if (count == SIZE_MAX / stride) return "Overflow";
            ++count;
        }
        uint8_t *data = NULL;
        if (count) {
            data = foo_qbe_reserve(&owned->sequence, count * stride,
                alignment);
            if (!data) return "OutOfMemory";
        }
        foo_qbe_slice sequence = {data, count};
        memcpy(value, &sequence, sizeof(sequence));
        const FOOJson *child = node->child;
        for (size_t index = 0; index < count; ++index) {
            foo_qbe_codec_schema member = {element, element + child_length, NULL};
            const char *error = foo_qbe_codec_read(&member, child,
                data + index * stride, owned, depth + 1);
            if (error) return error;
            if (member.next != member.end) return "InvalidSchema";
            child = child->next;
        }
        return NULL;
    }
    case 'A': {
        uint32_t count = foo_qbe_codec_word(schema, 4);
        uint32_t stride = foo_qbe_codec_word(schema, 4);
        uint32_t child_length = foo_qbe_codec_word(schema, 4);
        const uint8_t *element = foo_qbe_codec_take(schema, child_length);
        if (!element || !stride || !child_length) return "InvalidSchema";
        if (node->kind != '[') return "ExpectedArray";
        const FOOJson *child = node->child;
        for (uint32_t index = 0; index < count; ++index) {
            if (!child) return "ExpectedArrayLength";
            foo_qbe_codec_schema member = {element, element + child_length, NULL};
            const char *error = foo_qbe_codec_read(&member, child,
                value + (size_t)index * stride, owned, depth + 1);
            if (error) return error;
            if (member.next != member.end) return "InvalidSchema";
            child = child->next;
        }
        if (child) return "ExpectedArrayLength";
        return NULL;
    }
    case 'O': {
        uint32_t offset = foo_qbe_codec_word(schema, 4);
        uint32_t child_length = foo_qbe_codec_word(schema, 4);
        const uint8_t *element = foo_qbe_codec_take(schema, child_length);
        if (!element || !child_length) return "InvalidSchema";
        if (node->kind == 'n') return NULL;
        *value = 1;
        foo_qbe_codec_schema child = {element, element + child_length, NULL};
        const char *error = foo_qbe_codec_read(&child, node, value + offset,
            owned, depth + 1);
        return error ? error :
            child.next == child.end ? NULL : "InvalidSchema";
    }
    case 'R': {
        uint32_t count = foo_qbe_codec_word(schema, 2);
        if (schema->error) return schema->error;
        if (node->kind != '{') return "ExpectedObject";
        for (uint32_t index = 0; index < count; ++index) {
            uint32_t offset = foo_qbe_codec_word(schema, 4);
            uint32_t length = foo_qbe_codec_word(schema, 2);
            const uint8_t *name = foo_qbe_codec_take(schema, length);
            if (!name) return schema->error;
            const FOOJson *child = node->child;
            while (child && (child->key.len != length ||
                memcmp(child->key.data, name, length))) child = child->next;
            if (!child) return "MissingField";
            const char *error = foo_qbe_codec_read(schema, child,
                value + offset, owned, depth + 1);
            if (error) return error;
        }
        return NULL;
    }
    case 'C': {
        uint32_t count = foo_qbe_codec_word(schema, 2);
        uint32_t offset = foo_qbe_codec_word(schema, 4);
        if (schema->error || !count) return "InvalidSchema";
        if (node->kind != '{' || !node->child || node->child->next)
            return "ExpectedChoice";
        bool matched = false;
        for (uint32_t index = 0; index < count; ++index) {
            uint32_t name_length = foo_qbe_codec_word(schema, 2);
            const uint8_t *name = foo_qbe_codec_take(schema, name_length);
            uint32_t child_length = foo_qbe_codec_word(schema, 4);
            const uint8_t *child = foo_qbe_codec_take(schema, child_length);
            if (!name || !child || !name_length || !child_length)
                return "InvalidSchema";
            if (node->child->key.len != name_length ||
                memcmp(node->child->key.data, name, name_length)) continue;
            foo_qbe_codec_schema member = {child, child + child_length, NULL};
            const char *error = foo_qbe_codec_read(&member, node->child,
                value + offset, owned, depth + 1);
            if (error) return error;
            if (member.next != member.end) return "InvalidSchema";
            memcpy(value, &index, sizeof(index));
            matched = true;
        }
        return matched ? NULL : "UnknownChoice";
    }
    case 'P': {
        uint32_t count = foo_qbe_codec_word(schema, 2);
        if (schema->error) return schema->error;
        if (node->kind != '{') return "ExpectedObject";
        for (uint32_t index = 0; index < count; ++index) {
            uint32_t offset = foo_qbe_codec_word(schema, 4);
            uint32_t bits = foo_qbe_codec_word(schema, 2);
            uint32_t name_length = foo_qbe_codec_word(schema, 2);
            const uint8_t *name = foo_qbe_codec_take(schema, name_length);
            uint32_t child_length = foo_qbe_codec_word(schema, 4);
            const uint8_t *child = foo_qbe_codec_take(schema, child_length);
            if (!name || !child || !name_length || !child_length ||
                !bits || bits > 128 || offset > UINT32_MAX - bits)
                return "InvalidSchema";
            const FOOJson *field = node->child;
            while (field && (field->key.len != name_length ||
                memcmp(field->key.data, name, name_length))) field = field->next;
            if (!field) return "MissingField";
            uint8_t decoded[16] = {0};
            foo_qbe_codec_schema member = {child, child + child_length, NULL};
            const char *error = foo_qbe_codec_read(&member, field, decoded,
                owned, depth + 1);
            if (error) return error;
            if (member.next != member.end) return "InvalidSchema";
            foo_qbe_codec_bits_set(value, offset, bits, decoded);
        }
        return NULL;
    }
    default: return "InvalidSchema";
    }
}

static void foo_qbe_codec_attach(foo_qbe_allocation **target,
    foo_qbe_allocation **owned) {
    if (!*owned) return;
    foo_qbe_allocation *last = *owned;
    while (last->next) last = last->next;
    last->next = *target;
    *target = *owned;
    *owned = NULL;
}

static int foo_qbe_codec_commit(foo_qbe_codec_owned *owned) {
    if (!owned->text && !owned->sequence) return 1;
    foo_qbe_text_enter();
    if (owned->text && !foo_qbe_text_registered) {
        if (atexit(foo_qbe_text_cleanup) != 0) {
            foo_qbe_text_leave();
            return 0;
        }
        foo_qbe_text_registered = 1;
    }
    if (owned->sequence && !foo_qbe_sequence_registered) {
        if (atexit(foo_qbe_sequence_cleanup) != 0) {
            foo_qbe_text_leave();
            return 0;
        }
        foo_qbe_sequence_registered = 1;
    }
    foo_qbe_codec_attach(&foo_qbe_text_allocations, &owned->text);
    foo_qbe_codec_attach(&foo_qbe_sequence_allocations, &owned->sequence);
    foo_qbe_text_leave();
    return 1;
}

/* Common scalar records can be decoded without allocating a JSON tree. A miss
 * leaves the result untouched so the shared parser retains the full JSON rules. */
static bool foo_qbe_codec_scalar_record(const foo_qbe_slice *text,
    const uint8_t *descriptor, size_t length, uint8_t *output) {
    foo_qbe_codec_schema schema = {descriptor, descriptor + length, NULL};
    const uint8_t *tag = foo_qbe_codec_take(&schema, 1);
    if (!tag || *tag != 'R') return false;
    uint32_t count = foo_qbe_codec_word(&schema, 2);
    if (schema.error || !count || count > 16) return false;
    struct { uint32_t offset; uint8_t width; uint64_t value; } fields[16];
    const uint8_t *source = text->data;
    size_t size = (size_t)text->length, at = 0;
    if (!size || source[at++] != '{') return false;
    for (uint32_t index = 0; index < count; ++index) {
        uint32_t offset = foo_qbe_codec_word(&schema, 4);
        uint32_t name_length = foo_qbe_codec_word(&schema, 2);
        const uint8_t *name = foo_qbe_codec_take(&schema, name_length);
        if (!name || !name_length || size - at < (size_t)name_length + 3 ||
            source[at++] != '"') return false;
        for (uint32_t byte = 0; byte < name_length; ++byte)
            if (name[byte] < 32 || name[byte] > 126 ||
                name[byte] == '"' || name[byte] == '\\') return false;
        if (memcmp(source + at, name, name_length)) return false;
        at += name_length;
        if (source[at++] != '"' || source[at++] != ':') return false;
        const uint8_t *kind = foo_qbe_codec_take(&schema, 1);
        if (!kind) return false;
        uint64_t number = 0;
        uint8_t width = 1;
        if (*kind == 'B') {
            if (size - at >= 4 && !memcmp(source + at, "true", 4)) {
                number = 1;
                at += 4;
            } else if (size - at >= 5 && !memcmp(source + at, "false", 5)) {
                at += 5;
            } else return false;
        } else if (*kind == 'U' || *kind == 'I') {
            width = (uint8_t)foo_qbe_codec_word(&schema, 1);
            uint32_t bits = foo_qbe_codec_word(&schema, 1);
            if (schema.error || !width || width > 8 ||
                (width & (width - 1)) || !bits || bits > width * 8)
                return false;
            bool negative = at < size && source[at] == '-';
            if (negative) ++at;
            if (negative && *kind == 'U') return false;
            uint64_t maximum = bits == 64 ? UINT64_MAX :
                (UINT64_C(1) << bits) - 1;
            if (*kind == 'I') maximum >>= 1;
            uint64_t limit = maximum + (negative && *kind == 'I');
            size_t start = at;
            while (at < size && source[at] >= '0' && source[at] <= '9') {
                uint64_t digit = source[at++] - '0';
                if (digit > limit || number > (limit - digit) / 10)
                    return false;
                number = number * 10 + digit;
            }
            if (at == start || (at - start > 1 && source[start] == '0') ||
                (negative && !number)) return false;
            if (negative) number = ~number + 1;
        } else return false;
        fields[index].offset = offset;
        fields[index].width = width;
        fields[index].value = number;
        if (at >= size || source[at++] != (index + 1 == count ? '}' : ','))
            return false;
    }
    if (schema.error || schema.next != schema.end || at != size) return false;
    for (uint32_t index = 0; index < count; ++index)
        memcpy(output + fields[index].offset, &fields[index].value,
            fields[index].width);
    return true;
}

static bool foo_qbe_codec_encode_scalar_record(void *output,
    const uint8_t *value, const uint8_t *descriptor, size_t length,
    int byte_sequence) {
    foo_qbe_codec_schema schema = {descriptor, descriptor + length, NULL};
    const uint8_t *tag = foo_qbe_codec_take(&schema, 1);
    if (!tag || *tag != 'R') return false;
    uint32_t count = foo_qbe_codec_word(&schema, 2);
    if (schema.error || !count || count > 16) return false;
    uint8_t bytes[512];
    size_t used = 0;
    bytes[used++] = '{';
    for (uint32_t index = 0; index < count; ++index) {
        uint32_t offset = foo_qbe_codec_word(&schema, 4);
        uint32_t name_length = foo_qbe_codec_word(&schema, 2);
        const uint8_t *name = foo_qbe_codec_take(&schema, name_length);
        if (!name || !name_length || sizeof(bytes) - used < name_length + 4)
            return false;
        for (uint32_t byte = 0; byte < name_length; ++byte)
            if (name[byte] < 32 || name[byte] > 126 ||
                name[byte] == '"' || name[byte] == '\\') return false;
        if (index) bytes[used++] = ',';
        bytes[used++] = '"';
        memcpy(bytes + used, name, name_length);
        used += name_length;
        bytes[used++] = '"';
        bytes[used++] = ':';
        const uint8_t *kind = foo_qbe_codec_take(&schema, 1);
        if (!kind) return false;
        if (*kind == 'B') {
            uint8_t enabled;
            memcpy(&enabled, value + offset, 1);
            const char *word = enabled ? "true" : "false";
            size_t size = enabled ? 4 : 5;
            if (sizeof(bytes) - used < size) return false;
            memcpy(bytes + used, word, size);
            used += size;
        } else if (*kind == 'U' || *kind == 'I') {
            uint32_t width = foo_qbe_codec_word(&schema, 1);
            uint32_t bits = foo_qbe_codec_word(&schema, 1);
            if (schema.error || !width || width > 8 ||
                (width & (width - 1)) || !bits || bits > width * 8)
                return false;
            uint64_t number = 0;
            memcpy(&number, value + offset, width);
            if (bits < 64) number &= (UINT64_C(1) << bits) - 1;
            bool negative = *kind == 'I' &&
                (number & (UINT64_C(1) << (bits - 1))) != 0;
            if (negative && bits < 64) number |= UINT64_MAX << bits;
            if (negative) number = ~number + 1;
            uint8_t digits[21];
            size_t digits_count = 0;
            do {
                digits[digits_count++] = (uint8_t)('0' + number % 10);
                number /= 10;
            } while (number);
            if (sizeof(bytes) - used < digits_count + (size_t)negative)
                return false;
            if (negative) bytes[used++] = '-';
            while (digits_count) bytes[used++] = digits[--digits_count];
        } else return false;
    }
    if (schema.error || schema.next != schema.end ||
        sizeof(bytes) - used < 1) return false;
    bytes[used++] = '}';
    foo_qbe_codec_owned owned = {0};
    uint8_t *copy = foo_qbe_reserve(byte_sequence ? &owned.sequence : &owned.text,
        used, 1);
    if (!copy || !foo_qbe_codec_commit(&owned)) {
        foo_qbe_free(&owned.text);
        foo_qbe_free(&owned.sequence);
        foo_qbe_table_error(output, "OutOfMemory");
        return true;
    }
    memcpy(copy, bytes, used);
    foo_qbe_slice text = {copy, used};
    memcpy((uint8_t *)output + 8, &text, sizeof(text));
    return true;
}

void foo_qbe_codec_encode(void *output, const void *value,
    const uint8_t *descriptor, uint64_t length, int byte_sequence) {
    if (!output) return;
    if (!value || !descriptor || length > SIZE_MAX) {
        foo_qbe_table_error(output, "InvalidInput");
        return;
    }
    if (foo_qbe_codec_encode_scalar_record(output, value, descriptor,
        (size_t)length, byte_sequence)) return;
    foo_qbe_codec_schema schema = {descriptor, descriptor + length, NULL};
    FOOWriter writer = {0};
    const char *error = foo_qbe_codec_write(&schema, value, &writer, 0);
    if (!error && schema.next != schema.end) error = "InvalidSchema";
    foo_qbe_codec_owned owned = {0};
    uint8_t *copy = NULL;
    if (!error) {
        copy = foo_qbe_reserve(byte_sequence ? &owned.sequence : &owned.text,
            writer.length, 1);
        if (!copy || !foo_qbe_codec_commit(&owned)) error = "OutOfMemory";
        else memcpy(copy, writer.data, writer.length);
    }
    if (error) {
        foo_qbe_free(&owned.text);
        foo_qbe_free(&owned.sequence);
        foo_qbe_table_error(output, error);
    } else {
        foo_qbe_slice text = {copy, writer.length};
        memcpy((uint8_t *)output + 8, &text, sizeof(text));
    }
    free(writer.data);
}

void foo_qbe_codec_decode(void *output, const void *source,
    const uint8_t *descriptor, uint64_t length, uint64_t offset) {
    if (!output) return;
    if (!source || !descriptor || length > SIZE_MAX ||
        offset > SIZE_MAX) {
        foo_qbe_table_error(output, "InvalidInput");
        return;
    }
    foo_qbe_slice text;
    memcpy(&text, source, sizeof(text));
    if (text.length > SIZE_MAX || (text.length && !text.data)) {
        foo_qbe_table_error(output, "InvalidText");
        return;
    }
    if (foo_qbe_codec_scalar_record(&text, descriptor, (size_t)length,
        (uint8_t *)output + offset)) return;
    FOOResult parsed = foo_json_parse((FOOText){text.data, (size_t)text.length});
    if (parsed.error) {
        foo_qbe_table_error(output, parsed.error);
        return;
    }
    foo_qbe_codec_schema schema = {descriptor, descriptor + length, NULL};
    foo_qbe_codec_owned owned = {0};
    const char *error = foo_qbe_codec_read(&schema, parsed.pointer,
        (uint8_t *)output + offset, &owned, 0);
    if (!error && schema.next != schema.end) error = "InvalidSchema";
    if (!error && !foo_qbe_codec_commit(&owned)) error = "OutOfMemory";
    if (error) {
        foo_qbe_free(&owned.text);
        foo_qbe_free(&owned.sequence);
        foo_qbe_table_error(output, error);
    }
    foo_json_release(parsed.pointer);
}

typedef struct {
    const uint8_t *prefix;
    uint64_t prefix_length;
    const uint8_t *middle;
    uint64_t middle_length;
    const uint8_t *descriptor;
    uint64_t descriptor_length;
    uint64_t number_offset;
    uint64_t boolean_offset;
    uint64_t result_offset;
    uint64_t byte_sequence;
} foo_qbe_codec_u64_bool_plan;

void foo_qbe_codec_encode_u64_bool(void *output, uint64_t number, int active,
    const foo_qbe_codec_u64_bool_plan *plan) {
    if (!output) return;
    if (!plan || plan->prefix_length > 512 ||
        plan->middle_length > 512 - plan->prefix_length ||
        512 - plan->prefix_length - plan->middle_length < 26) {
        foo_qbe_table_error(output, "InvalidSchema");
        return;
    }
    uint8_t bytes[512], digits[20];
    size_t used = 0, count = 0;
    memcpy(bytes, plan->prefix, (size_t)plan->prefix_length);
    used += (size_t)plan->prefix_length;
    do {
        digits[count++] = (uint8_t)('0' + number % 10);
        number /= 10;
    } while (number);
    while (count) bytes[used++] = digits[--count];
    memcpy(bytes + used, plan->middle, (size_t)plan->middle_length);
    used += (size_t)plan->middle_length;
    const char *word = active ? "true" : "false";
    size_t word_length = active ? 4 : 5;
    memcpy(bytes + used, word, word_length);
    used += word_length;
    bytes[used++] = '}';

    foo_qbe_codec_owned owned = {0};
    uint8_t *copy = foo_qbe_reserve(plan->byte_sequence ?
        &owned.sequence : &owned.text, used, 1);
    if (!copy || !foo_qbe_codec_commit(&owned)) {
        foo_qbe_free(&owned.text);
        foo_qbe_free(&owned.sequence);
        foo_qbe_table_error(output, "OutOfMemory");
        return;
    }
    memcpy(copy, bytes, used);
    foo_qbe_slice text = {copy, used};
    memcpy((uint8_t *)output + 8, &text, sizeof(text));
}

void foo_qbe_codec_decode_u64_bool(void *output, const void *source,
    const foo_qbe_codec_u64_bool_plan *plan) {
    if (!output) return;
    if (!source || !plan) {
        foo_qbe_table_error(output, "InvalidInput");
        return;
    }
    foo_qbe_slice text;
    memcpy(&text, source, sizeof(text));
    if (text.length > SIZE_MAX || (text.length && !text.data)) {
        foo_qbe_table_error(output, "InvalidText");
        return;
    }
    size_t size = (size_t)text.length;
    if (plan->prefix_length <= size &&
        !memcmp(text.data, plan->prefix, (size_t)plan->prefix_length)) {
        size_t at = (size_t)plan->prefix_length, first = at;
        uint64_t number = 0;
        while (at < size && text.data[at] >= '0' && text.data[at] <= '9') {
            uint64_t digit = text.data[at++] - '0';
            if (number > (UINT64_MAX - digit) / 10) goto fallback;
            number = number * 10 + digit;
        }
        if (at == first || (at - first > 1 && text.data[first] == '0') ||
            plan->middle_length > size - at ||
            memcmp(text.data + at, plan->middle,
                (size_t)plan->middle_length)) goto fallback;
        at += (size_t)plan->middle_length;
        uint8_t active;
        if (size - at >= 4 && !memcmp(text.data + at, "true", 4)) {
            active = 1;
            at += 4;
        } else if (size - at >= 5 && !memcmp(text.data + at, "false", 5)) {
            active = 0;
            at += 5;
        } else goto fallback;
        if (at < size && size - at == 1 && text.data[at] == '}') {
            uint8_t *value = (uint8_t *)output + plan->result_offset;
            memcpy(value + plan->number_offset, &number, sizeof(number));
            memcpy(value + plan->boolean_offset, &active, sizeof(active));
            return;
        }
    }
fallback:
    foo_qbe_codec_decode(output, source, plan->descriptor,
        plan->descriptor_length, plan->result_offset);
}
