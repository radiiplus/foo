#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct { const unsigned char *data; uint64_t length; } Slice;
typedef struct { const char *error; uint64_t value; } Result;
typedef struct { const char *error; Slice value; } SequenceResult;
typedef struct { const char *error; uint64_t padding; uint64_t value[2]; }
    WideResult;
typedef struct { uint64_t id; uint8_t active; } Packet;
typedef struct { const char *error; Packet value; } PacketResult;
typedef struct { const char *error; int64_t value; } SignedResult;
typedef struct { uint8_t present; uint8_t padding[7]; uint64_t value; }
    OptionalNumber;
typedef struct { const char *error; OptionalNumber value; } OptionalResult;
typedef struct { Slice name; uint8_t active; } NamedPacket;
typedef struct { const char *error; NamedPacket value; } NamedResult;

void foo_qbe_table_create(void *output);
void foo_qbe_table_put(void *output, void *handle, const void *key,
    const void *value, uint64_t size);
void foo_qbe_table_get(void *output, void *handle, const void *key,
    uint64_t size, uint64_t offset);
void foo_qbe_table_query(void *output, void *handle, const void *key,
    int operation);
void foo_qbe_table_close(void *output, void *handle);
void foo_qbe_sequence_sized(void *output, uint64_t count, uint64_t element_size,
    uint64_t alignment);
void foo_qbe_sequence_release(void *output, const void *source,
    uint64_t element_size);
void foo_qbe_codec_encode(void *output, const void *value,
    const uint8_t *descriptor, uint64_t length, int byte_sequence);
void foo_qbe_codec_decode(void *output, const void *source,
    const uint8_t *descriptor, uint64_t length, uint64_t offset);
void foo_qbe_text_release(void *output, const void *content);
void foo_qbe_text_find(void *output, const void *content, const void *needle);
int foo_qbe_text_equal(const void *left, const void *right);

int main(void) {
    Slice searched = {(const unsigned char *)"abababc", 7};
    Slice repeated = {(const unsigned char *)"ababc", 5};
    Slice single = {(const unsigned char *)"c", 1};
    Slice empty = {NULL, 0};
    Slice missing_needle = {(const unsigned char *)"d", 1};
    OptionalNumber position = {0};
    foo_qbe_text_find(&position, &searched, &repeated);
    if (!position.present || position.value != 2) return 45;
    position = (OptionalNumber){0};
    foo_qbe_text_find(&position, &searched, &single);
    if (!position.present || position.value != 6) return 46;
    position = (OptionalNumber){0};
    foo_qbe_text_find(&position, &searched, &empty);
    if (!position.present || position.value != 0) return 47;
    position = (OptionalNumber){0};
    foo_qbe_text_find(&position, &searched, &missing_needle);
    if (position.present) return 48;

    Result result = {0};
    Slice key = {(const unsigned char *)"amber", 5};
    uint64_t value = 42;
    foo_qbe_table_create(&result);
    if (result.error || !result.value) return 1;
    void *map = (void *)(uintptr_t)result.value;
    result = (Result){0};
    foo_qbe_table_put(&result, map, &key, &value, sizeof(value));
    if (result.error) return 2;
    result = (Result){0};
    foo_qbe_table_get(&result, map, &key, sizeof(value), 8);
    if (result.error || result.value != value) return 3;
    result = (Result){0};
    foo_qbe_table_get(&result, map, &key, sizeof(uint32_t), 8);
    if (!result.error || strcmp(result.error, "InvalidValue")) return 4;
    result = (Result){0};
    foo_qbe_table_query(&result, map, &key, 1);
    if (result.error || !result.value) return 5;
    result = (Result){0};
    foo_qbe_table_get(&result, map, &key, sizeof(value), 8);
    if (!result.error || strcmp(result.error, "Missing")) return 6;
    for (int index = 0; index < 128; ++index) {
        char name[32];
        int length = snprintf(name, sizeof(name), "key-%d", index);
        Slice transient = {(const unsigned char *)name, (uint64_t)length};
        result = (Result){0};
        foo_qbe_table_put(&result, map, &transient, &value, sizeof(value));
        if (result.error) return 13;
        result = (Result){0};
        foo_qbe_table_query(&result, map, &transient, 1);
        if (result.error || !result.value) return 14;
    }
    result = (Result){0};
    foo_qbe_table_get(&result, map, &key, sizeof(value), 8);
    if (!result.error || strcmp(result.error, "Missing")) return 15;
    result = (Result){0};
    foo_qbe_table_close(&result, map);
    if (result.error) return 7;
    result = (Result){0};
    foo_qbe_table_close(&result, map);
    if (!result.error || strcmp(result.error, "Closed")) return 8;

    Result second = {0};
    uint64_t wide[2] = {17, 42};
    foo_qbe_table_create(&second);
    if (second.error || !second.value) return 16;
    void *wide_map = (void *)(uintptr_t)second.value;
    result = (Result){0};
    foo_qbe_table_put(&result, wide_map, &key, wide, sizeof(wide));
    if (result.error) return 17;
    WideResult wide_result = {0};
    foo_qbe_table_get(&wide_result, wide_map, &key, sizeof(wide), 16);
    if (wide_result.error || wide_result.value[0] != 17 ||
        wide_result.value[1] != 42) return 18;
    result = (Result){0};
    foo_qbe_table_close(&result, wide_map);
    if (result.error) return 19;

    SequenceResult sequence = {0};
    foo_qbe_sequence_sized(&sequence, 8, sizeof(uint64_t), 16);
    if (sequence.error || !sequence.value.data || sequence.value.length != 8)
        return 9;
    if ((uintptr_t)sequence.value.data % 16) return 20;
    const uint64_t *items = (const uint64_t *)sequence.value.data;
    for (int index = 0; index < 8; ++index)
        if (items[index]) return 10;
    result = (Result){0};
    foo_qbe_sequence_release(&result, &sequence.value, sizeof(uint64_t));
    if (result.error) return 11;
    result = (Result){0};
    foo_qbe_sequence_release(&result, &sequence.value, sizeof(uint64_t));
    if (!result.error || strcmp(result.error, "UnknownBuffer")) return 12;

    const uint8_t schema[] = {
        'R', 2, 0,
        0, 0, 0, 0, 2, 0, 'i', 'd', 'U', 8, 64,
        8, 0, 0, 0, 6, 0, 'a', 'c', 't', 'i', 'v', 'e', 'B'
    };
    Packet packet = {42, 1};
    SequenceResult encoded = {0};
    foo_qbe_codec_encode(&encoded, &packet, schema, sizeof(schema), 0);
    if (encoded.error || encoded.value.length != 23 ||
        memcmp(encoded.value.data, "{\"id\":42,\"active\":true}", 23))
        return 21;
    Slice equivalent = {(const unsigned char *)
        "{\"id\":42,\"active\":true}", 23};
    if (!foo_qbe_text_equal(&encoded.value, &equivalent)) return 39;
    PacketResult decoded = {0};
    foo_qbe_codec_decode(&decoded, &encoded.value, schema, sizeof(schema), 8);
    if (decoded.error || decoded.value.id != 42 || !decoded.value.active)
        return 22;
    result = (Result){0};
    foo_qbe_text_release(&result, &encoded.value);
    if (result.error) return 23;
    Slice malformed = {(const unsigned char *)"{\"id\":42}", 9};
    decoded = (PacketResult){0};
    foo_qbe_codec_decode(&decoded, &malformed, schema, sizeof(schema), 8);
    if (!decoded.error || strcmp(decoded.error, "MissingField")) return 24;
    const char maximum_json[] = "{\"id\":18446744073709551615,\"active\":true}";
    Slice maximum = {(const unsigned char *)maximum_json,
        sizeof(maximum_json) - 1};
    decoded = (PacketResult){0};
    foo_qbe_codec_decode(&decoded, &maximum, schema, sizeof(schema), 8);
    if (decoded.error || decoded.value.id != UINT64_MAX) return 25;
    packet.id = UINT64_MAX;
    encoded = (SequenceResult){0};
    foo_qbe_codec_encode(&encoded, &packet, schema, sizeof(schema), 0);
    if (encoded.error || encoded.value.length != maximum.length ||
        memcmp(encoded.value.data, maximum.data, maximum.length)) return 45;
    result = (Result){0};
    foo_qbe_text_release(&result, &encoded.value);
    if (result.error) return 46;
    packet.id = 42;
    const uint8_t signed_schema[] = {
        'R', 1, 0, 0, 0, 0, 0, 5, 0,
        'v', 'a', 'l', 'u', 'e', 'I', 8, 64
    };
    int64_t signed_minimum = INT64_MIN;
    const char signed_json[] = "{\"value\":-9223372036854775808}";
    encoded = (SequenceResult){0};
    foo_qbe_codec_encode(&encoded, &signed_minimum,
        signed_schema, sizeof(signed_schema), 0);
    if (encoded.error || encoded.value.length != sizeof(signed_json) - 1 ||
        memcmp(encoded.value.data, signed_json, sizeof(signed_json) - 1))
        return 47;
    SignedResult signed_decoded = {0};
    foo_qbe_codec_decode(&signed_decoded, &encoded.value,
        signed_schema, sizeof(signed_schema), 8);
    if (signed_decoded.error || signed_decoded.value != INT64_MIN) return 48;
    result = (Result){0};
    foo_qbe_text_release(&result, &encoded.value);
    if (result.error) return 49;
    const char negative_json[] = "{\"id\":-1,\"active\":true}";
    Slice negative = {(const unsigned char *)negative_json,
        sizeof(negative_json) - 1};
    decoded = (PacketResult){0};
    foo_qbe_codec_decode(&decoded, &negative, schema, sizeof(schema), 8);
    if (!decoded.error || strcmp(decoded.error, "NumberOverflow")) return 26;
    const char duplicate_json[] = "{\"id\":1,\"id\":2,\"active\":true}";
    Slice duplicate = {(const unsigned char *)duplicate_json,
        sizeof(duplicate_json) - 1};
    decoded = (PacketResult){0};
    foo_qbe_codec_decode(&decoded, &duplicate, schema, sizeof(schema), 8);
    if (!decoded.error || strcmp(decoded.error, "DuplicateField")) return 27;
    const char *valid_records[] = {
        "{\"active\":false,\"id\":0}",
        " { \"id\" : 42, \"active\" : true } ",
        "{\"id\":9,\"active\":true,\"extra\":0}"
    };
    const uint64_t valid_ids[] = {0, 42, 9};
    const int valid_active[] = {0, 1, 1};
    for (int index = 0; index < 3; ++index) {
        Slice source = {(const unsigned char *)valid_records[index],
            strlen(valid_records[index])};
        decoded = (PacketResult){0};
        foo_qbe_codec_decode(&decoded, &source, schema, sizeof(schema), 8);
        if (decoded.error || decoded.value.id != valid_ids[index] ||
            decoded.value.active != valid_active[index]) return 40;
    }
    const char *invalid_records[] = {
        "{\"id\":1,\"active\":1}",
        "{\"id\":1,\"active\":true"
    };
    for (int index = 0; index < 2; ++index) {
        Slice source = {(const unsigned char *)invalid_records[index],
            strlen(invalid_records[index])};
        decoded = (PacketResult){0};
        foo_qbe_codec_decode(&decoded, &source, schema, sizeof(schema), 8);
        if (!decoded.error) return 41;
    }

    const uint8_t sequence_schema[] = {
        'S', 8, 0, 0, 0, 8, 0, 0, 0, 3, 0, 0, 0, 'I', 8, 64
    };
    int64_t integers[3] = {1, 2, 3};
    Slice numbers = {(const unsigned char *)integers, 3};
    encoded = (SequenceResult){0};
    foo_qbe_codec_encode(&encoded, &numbers,
        sequence_schema, sizeof(sequence_schema), 0);
    if (encoded.error || encoded.value.length != 7 ||
        memcmp(encoded.value.data, "[1,2,3]", 7)) return 28;
    SequenceResult parsed_numbers = {0};
    foo_qbe_codec_decode(&parsed_numbers, &encoded.value,
        sequence_schema, sizeof(sequence_schema), 8);
    if (parsed_numbers.error || parsed_numbers.value.length != 3 ||
        ((const int64_t *)parsed_numbers.value.data)[2] != 3) return 29;
    result = (Result){0};
    foo_qbe_sequence_release(&result, &parsed_numbers.value, sizeof(int64_t));
    if (result.error) return 30;
    result = (Result){0};
    foo_qbe_text_release(&result, &encoded.value);
    if (result.error) return 31;

    const uint8_t optional_schema[] = {
        'O', 8, 0, 0, 0, 3, 0, 0, 0, 'U', 8, 64
    };
    OptionalNumber present = {1, {0}, 7};
    encoded = (SequenceResult){0};
    foo_qbe_codec_encode(&encoded, &present,
        optional_schema, sizeof(optional_schema), 0);
    if (encoded.error || encoded.value.length != 1 ||
        encoded.value.data[0] != '7') return 32;
    OptionalResult roundtrip = {0};
    foo_qbe_codec_decode(&roundtrip, &encoded.value,
        optional_schema, sizeof(optional_schema), 8);
    if (roundtrip.error || !roundtrip.value.present ||
        roundtrip.value.value != 7) return 33;
    result = (Result){0};
    foo_qbe_text_release(&result, &encoded.value);
    if (result.error) return 34;
    OptionalNumber absent = {0};
    encoded = (SequenceResult){0};
    foo_qbe_codec_encode(&encoded, &absent,
        optional_schema, sizeof(optional_schema), 0);
    if (encoded.error || encoded.value.length != 4 ||
        memcmp(encoded.value.data, "null", 4)) return 35;
    result = (Result){0};
    foo_qbe_text_release(&result, &encoded.value);
    if (result.error) return 36;
    encoded = (SequenceResult){0};
    foo_qbe_codec_encode(&encoded, &packet, schema, sizeof(schema), 1);
    if (encoded.error || encoded.value.length != 23) return 37;
    result = (Result){0};
    foo_qbe_sequence_release(&result, &encoded.value, 1);
    if (result.error) return 38;
    const uint8_t named_schema[] = {
        'R', 2, 0,
        0, 0, 0, 0, 4, 0, 'n', 'a', 'm', 'e', 'T',
        16, 0, 0, 0, 6, 0, 'a', 'c', 't', 'i', 'v', 'e', 'B'
    };
    const char partial_json[] = "{\"name\":\"allocated\",\"active\":1}";
    Slice partial = {(const unsigned char *)partial_json,
        sizeof(partial_json) - 1};
    NamedResult partial_result = {0};
    foo_qbe_codec_decode(&partial_result, &partial,
        named_schema, sizeof(named_schema), 8);
    if (!partial_result.error ||
        strcmp(partial_result.error, "ExpectedBoolean")) return 42;
    const char owned_json[] = "{\"name\":\"allocated\",\"active\":true}";
    Slice owned_source = {(const unsigned char *)owned_json,
        sizeof(owned_json) - 1};
    NamedResult owned_result = {0};
    foo_qbe_codec_decode(&owned_result, &owned_source,
        named_schema, sizeof(named_schema), 8);
    if (owned_result.error || !owned_result.value.active ||
        owned_result.value.name.length != 9 ||
        memcmp(owned_result.value.name.data, "allocated", 9)) return 43;
    result = (Result){0};
    foo_qbe_text_release(&result, &owned_result.value.name);
    if (result.error) return 44;
    puts("QBE shared runtime: ok");
    return 0;
}
