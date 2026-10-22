/* Offline ABI/runtime probe for the controlled Linux static dependencies. */
#include <sodium.h>
#include <zlib.h>
#include <blake3.h>
#include <string.h>
#include <stdio.h>
int main(void) {
  static const unsigned char input[] = "offline dependency parity";
  unsigned char compressed[128], restored[128], digest[crypto_hash_sha256_BYTES];
  unsigned long packed = sizeof compressed, unpacked = sizeof restored;
  char hex[65];
  if (sodium_init() < 0 || strcmp(sodium_version_string(), "1.0.22") || strcmp(zlibVersion(), "1.3.1")) return 1;
  if (crypto_hash_sha256(digest, (const unsigned char *)"abc", 3)) return 2;
  sodium_bin2hex(hex, sizeof hex, digest, sizeof digest);
  if (strcmp(hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")) return 3;
  if (compress(compressed, &packed, input, sizeof input) != Z_OK) return 4;
  if (uncompress(restored, &unpacked, compressed, packed) != Z_OK || unpacked != sizeof input || memcmp(input, restored, sizeof input)) return 5;
  blake3_hasher hasher;
  blake3_hasher_init(&hasher);
  blake3_hasher_finalize(&hasher, digest, sizeof digest);
  sodium_bin2hex(hex, sizeof hex, digest, sizeof digest);
  if (strcmp(hex, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262")) return 6;
  puts("controlled native dependency ABI/runtime: ok");
  return 0;
}
