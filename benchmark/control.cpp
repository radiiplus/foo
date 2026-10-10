#include <algorithm>
#include <bit>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <vector>

int main(int argc, char **argv) {
  if (argc != 2) return 2;
  const char mode = argv[1][0];
  if (mode == 'a') {
    std::vector<std::uint64_t> first(30000), second(30000);
    for (std::size_t i = 0; i < first.size(); ++i) {
      first[i] = i * UINT64_C(1234567891234);
      second[i] = i * UINT64_C(9876543212345);
    }
    std::uint64_t checksum = 0;
    const auto started = std::chrono::steady_clock::now();
    for (unsigned pass = 0; pass < 2; ++pass) {
      std::vector<std::uint64_t> merged(first.size());
      std::vector<std::uint64_t> common(first.size());
      std::vector<std::uint64_t> removed(first.size());
      for (std::size_t i = 0; i < first.size(); ++i) {
        merged[i] = first[i] | second[i];
        common[i] = first[i] & second[i];
        removed[i] = first[i] & ~second[i];
      }
      for (std::size_t i = 0; i < first.size(); ++i)
        checksum += std::popcount(merged[i]) + std::popcount(common[i]) +
                    std::popcount(removed[i]);
    }
    const auto elapsed = std::chrono::steady_clock::now() - started;
    if (checksum == 0) return 3;
    std::printf("%lld %llu\n", static_cast<long long>(
      std::chrono::duration_cast<std::chrono::nanoseconds>(elapsed).count()),
      static_cast<unsigned long long>(checksum));
    return 0;
  }
  if (mode == 'b') {
    std::vector<std::uint64_t> words(500000);
    for (std::size_t i = 0; i < words.size(); ++i)
      words[i] = i * UINT64_C(1234567891234);
    std::uint64_t total = 0;
    const auto started = std::chrono::steady_clock::now();
    for (unsigned pass = 0; pass < 5; ++pass) {
      for (auto word : words) total += std::popcount(word);
      ++words[0];
    }
    const auto elapsed = std::chrono::steady_clock::now() - started;
    if (total != UINT64_C(72322775)) return 3;
    std::printf("%lld %llu\n", static_cast<long long>(
      std::chrono::duration_cast<std::chrono::nanoseconds>(elapsed).count()),
      static_cast<unsigned long long>(total));
    return 0;
  }
  if (mode == 'r' || mode == 's') {
    std::vector<std::uint64_t> values(200000);
    for (std::size_t i = 0; i < values.size(); ++i)
      values[i] = i * UINT64_C(48271) % UINT64_C(1000003);
    const auto started = std::chrono::steady_clock::now();
    auto sorted = values;
    if (mode == 'r') std::sort(sorted.begin(), sorted.end());
    else std::stable_sort(sorted.begin(), sorted.end());
    const auto elapsed = std::chrono::steady_clock::now() - started;
    if (!std::is_sorted(sorted.begin(), sorted.end())) return 3;
    if (sorted[sorted.size() / 2] != UINT64_C(499996)) return 3;
    std::printf("%lld %llu\n", static_cast<long long>(
      std::chrono::duration_cast<std::chrono::nanoseconds>(elapsed).count()),
      static_cast<unsigned long long>(sorted[sorted.size() / 2]));
    return 0;
  }
  return 2;
}
