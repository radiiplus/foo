#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif
#include "service.h"
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#ifndef _WIN32
#include <unistd.h>
#endif

static void *mutex;
static void *condition;
static int ready;
static atomic_int total;
static atomic_int cancellation_started;
static atomic_int cancellation_finished;
static atomic_int timer_finished;

static void accumulate(int64_t value) {
  atomic_fetch_add_explicit(&total, (int)value, memory_order_relaxed);
}
static void add_metric(void *pointer) {
  for (int index = 0; index < 1000; index++)
    assert(!foo_metric_add(pointer, 1).error);
}

static void await_timer(void *value) {
  FooResult result = foo_timer_wait(value);
  assert(!result.error && result.number == 0);
  atomic_store(&timer_finished, 1);
}

static void await_cancellation(int64_t value) {
  (void)value;
  atomic_fetch_add(&cancellation_started, 1);
  while (!foo_task_cancelled().number)
    foo_time_sleep(1000000);
  atomic_fetch_add(&cancellation_finished, 1);
}

static void nested_cancellation(int64_t value) {
  (void)value;
  FooResult child = foo_task_scope();
  assert(!child.error);
  assert(foo_task_launch(child.pointer, await_cancellation, 0).number == 1);
  assert(!foo_task_join(child.pointer).error);
}

static void verify_cancellation(void) {
  atomic_store(&cancellation_started, 0);
  atomic_store(&cancellation_finished, 0);
  FooResult scope = foo_task_scope();
  assert(!scope.error);
  assert(foo_task_launch(scope.pointer, nested_cancellation, 0).number == 1);
  for (int attempt = 0; attempt < 5000 && !atomic_load(&cancellation_started); attempt++)
    foo_time_sleep(1000000);
  assert(atomic_load(&cancellation_started) == 1);
  assert(!foo_task_cancel(scope.pointer).error);
  assert(foo_task_launch(scope.pointer, accumulate, 1).number == 0);
  assert(!foo_task_join(scope.pointer).error);
  assert(atomic_load(&cancellation_finished) == 1);

  atomic_store(&cancellation_started, 0);
  atomic_store(&cancellation_finished, 0);
  FooResult pool = foo_task_pool();
  assert(!pool.error);
  for (int index = 0; index < 128; index++)
    assert(foo_task_submit(pool.pointer, await_cancellation, 0).number == 1);
  for (int attempt = 0; attempt < 5000 && !atomic_load(&cancellation_started); attempt++)
    foo_time_sleep(1000000);
  assert(atomic_load(&cancellation_started) > 0);
  assert(!foo_task_interrupt(pool.pointer).error);
  assert(foo_task_submit(pool.pointer, accumulate, 1).number == 0);
  assert(!foo_task_wait(pool.pointer).error);
  assert(atomic_load(&cancellation_finished) == atomic_load(&cancellation_started));
}

static void notify(void *context) {
  (void)context;
  assert(!foo_thread_lock(mutex).error);
  ready = 1;
  assert(!foo_thread_signal(condition).error);
  assert(!foo_thread_unlock(mutex).error);
}
static FooText value(const char *source) {
  return (FooText){(const uint8_t *)source, strlen(source)};
}
static void verify_storage(void) {
  FooText root = value("foo-service-storage");
  FooText child = value("foo-service-storage/sub");
  FooText leaf = value("foo-service-storage/sub/leaf");
  FooText draft = value("foo-service-storage/draft");
  FooText published = value("foo-service-storage/published");
  assert(!foo_fs_directory(root).error);
  assert(!foo_fs_directory(child).error);
  FooResult temporary = foo_fs_temporary(root, value("trial-"));
  assert(!temporary.error && !foo_fs_exists(temporary.text).error);
  FooResult metadata = foo_fs_metadata(temporary.text);
  assert(!metadata.error && foo_fs_measure(metadata.pointer).number == 0);
  FooResult kind = foo_fs_classify(metadata.pointer);
  assert(!kind.error && kind.text.len == 4 && !memcmp(kind.text.data, "file", 4));
  assert(foo_fs_timestamp(metadata.pointer, value("modified")).number >
         UINT64_C(1577836800000000000));
  assert(!foo_fs_restricted(metadata.pointer).number);
  assert(foo_fs_timestamp(metadata.pointer, value("invalid")).error);
  assert(!foo_fs_retire(metadata.pointer).error);
  assert(foo_fs_measure(metadata.pointer).error);
  FooResult stream = foo_fs_open(temporary.text, value("update"));
  assert(!stream.error);
  assert(!foo_fs_fault(value("write"), 2).error);
  FooResult partial = foo_fs_store(stream.pointer, 0, value("abcdef"));
  assert(!partial.error && partial.number == 2);
  assert(!foo_fs_fault(value("sync"), 0).error);
  assert(foo_fs_sync(stream.pointer).error);
  assert(!foo_fs_sync(stream.pointer).error);
  assert(!foo_io_close(stream.pointer).error);
  FooResult bytes = foo_fs_read(temporary.text);
  assert(!bytes.error && bytes.text.len == 2 && !memcmp(bytes.text.data, "ab", 2));
  assert(!foo_text_release(bytes.text).error);
  stream = foo_fs_open(draft, value("write"));
  assert(!stream.error);
  assert(!foo_fs_fault(value("write"), 1).error);
  assert(foo_io_write(stream.pointer, value("xyz")).error);
  assert(!foo_io_close(stream.pointer).error);
  bytes = foo_fs_read(draft);
  assert(!bytes.error && bytes.text.len == 1 && bytes.text.data[0] == 'x');
  assert(!foo_text_release(bytes.text).error);
  assert(!foo_fs_fault(value("replace"), 0).error);
  assert(foo_fs_replace(draft, published).error);
  assert(foo_fs_exists(draft).number == 1);
  assert(foo_fs_exists(published).number == 0);
  assert(!foo_fs_replace(draft, published).error);
  assert(!foo_fs_write(leaf, value("nested")).error);
#ifndef _WIN32
  FooText alias = value("foo-service-storage/alias");
  assert(!symlink("sub", "foo-service-storage/alias"));
  metadata = foo_fs_metadata(alias);
  assert(!metadata.error);
  kind = foo_fs_classify(metadata.pointer);
  assert(!kind.error && kind.text.len == 4 && !memcmp(kind.text.data, "link", 4));
  assert(!foo_fs_retire(metadata.pointer).error);
#endif
  FooResult walk = foo_fs_walk(root);
  assert(!walk.error);
  int found_sub = 0, found_leaf = 0, followed_alias = 0;
  for (;;) {
    FooResult entry = foo_fs_traverse(walk.pointer);
    assert(!entry.error);
    if (!entry.text.len) break;
    if (entry.text.len == 3 && !memcmp(entry.text.data, "sub", 3)) found_sub++;
    if (entry.text.len == 8 && !memcmp(entry.text.data, "sub/leaf", 8))
      found_leaf++;
    if (entry.text.len >= 6 && !memcmp(entry.text.data, "alias/", 6))
      followed_alias++;
    assert(!foo_text_release(entry.text).error);
  }
  assert(found_sub == 1 && found_leaf == 1 && followed_alias == 0);
  assert(!foo_fs_cease(walk.pointer).error);
  assert(foo_fs_traverse(walk.pointer).error);
#ifndef _WIN32
  assert(!foo_fs_remove(value("foo-service-storage/alias")).error);
#endif
  assert(!foo_fs_remove(leaf).error);
  assert(!foo_fs_remove(child).error);
  assert(!foo_fs_remove(published).error);
  assert(!foo_fs_remove(temporary.text).error);
  assert(!foo_text_release(temporary.text).error);
  assert(!foo_fs_remove(root).error);
  assert(!foo_fs_clear().error);
}

void verify(void) {
  verify_storage();
  FooResult wall = foo_time_wall();
  assert(!wall.error && wall.number > UINT64_C(1577836800000000000));
  const char *positioned = "foo-service-positioned.tmp";
  FooText positioned_path = {(const uint8_t *)positioned, strlen(positioned)};
  FooText write_mode = {(const uint8_t *)"write", 5};
  FooText read_mode = {(const uint8_t *)"read", 4};
  FooText create_mode = {(const uint8_t *)"create", 6};
  FooResult created = foo_fs_open(positioned_path, create_mode);
  assert(!created.error);
  assert(foo_fs_open(positioned_path, create_mode).error);
  assert(!foo_fs_lock(created.pointer,
      (FooText){(const uint8_t *)"exclusive", 9}).error);
  assert(!foo_fs_reserve(created.pointer, 4096).error);
  assert(foo_fs_size(created.pointer).number == 4096);
  assert(!foo_fs_truncate(created.pointer, 0).error);
  assert(foo_fs_size(created.pointer).number == 0);
  assert(!foo_fs_unlock(created.pointer).error);
  assert(!foo_io_close(created.pointer).error);
  FooResult output_at = foo_fs_open(positioned_path, write_mode);
  assert(!output_at.error);
  uint8_t binary[] = {65, 0, 66, 255};
  FooText source_at = {binary, sizeof(binary)};
  FooResult written_at = foo_fs_writeat(output_at.pointer, 0, source_at);
  assert(!written_at.error && written_at.number == sizeof(binary));
  assert(foo_fs_readat(output_at.pointer, 0, source_at).error);
  FooResult cursor_at = foo_fs_position(output_at.pointer);
  assert(!cursor_at.error && cursor_at.number == 0);
  assert(!foo_io_close(output_at.pointer).error);
  FooResult input_at = foo_fs_open(positioned_path, read_mode);
  assert(!input_at.error);
  uint8_t received_at[6] = {0};
  FooText destination_at = {received_at, sizeof(received_at)};
  FooResult read_at = foo_fs_readat(input_at.pointer, 0, destination_at);
  assert(!read_at.error && read_at.number == sizeof(binary));
  assert(!memcmp(binary, received_at, sizeof(binary)));
  cursor_at = foo_fs_position(input_at.pointer);
  assert(!cursor_at.error && cursor_at.number == 0);
  read_at = foo_fs_readat(input_at.pointer, 9, destination_at);
  assert(!read_at.error && read_at.number == 0);
  assert(foo_fs_readat(input_at.pointer, UINT64_MAX, destination_at).error);
  assert(foo_fs_writeat(input_at.pointer, 0, source_at).error);
  assert(foo_fs_truncate(input_at.pointer, 0).error);
  assert(foo_fs_reserve(input_at.pointer, 4096).error);
  assert(!foo_io_close(input_at.pointer).error);
  assert(foo_fs_readat(input_at.pointer, 0, destination_at).error);
  assert(!remove(positioned));

  FooText source = value("foo-service-map.tmp");
  assert(!foo_fs_write(source, value("XincludeZ")).error);
  FooResult mapping = foo_fs_map(source, 1, 7);
  assert(!mapping.error);
  FooResult mapped_bytes = foo_fs_mapped(mapping.pointer);
  assert(!mapped_bytes.error && mapped_bytes.text.len == 7);
  assert(!memcmp(mapped_bytes.text.data, "include", 7));
  assert(foo_fs_map(source, UINT64_MAX, 1).error);
  assert(!foo_fs_unmap(mapping.pointer).error);
  assert(foo_fs_mapped(mapping.pointer).error);
  assert(foo_fs_unmap(mapping.pointer).error);
  assert(!foo_fs_remove(source).error);
  FooText texts[1024];
  for (size_t index = 0; index < 1024; index++) {
    FooResult value = foo_text_concatenate(
        (FooText){(const uint8_t *)"a", 1},
        (FooText){(const uint8_t *)"b", 1});
    assert(!value.error && value.text.len == 2);
    texts[index] = value.text;
  }
  for (size_t index = 0; index < 1024; index += 2)
    assert(!foo_text_release(texts[index]).error);
  for (size_t index = 1; index < 1024; index += 2)
    assert(!foo_text_release(texts[index]).error);
  assert(foo_text_release(texts[0]).error);

  FooResult lock = foo_thread_mutex(), signal = foo_thread_condition();
  assert(!lock.error && !signal.error);
  mutex = lock.pointer;
  condition = signal.pointer;
  ready = 0;
  assert(!foo_thread_lock(mutex).error);
  FooResult worker = foo_thread_spawn(notify, NULL);
  assert(!worker.error);
  while (!ready) assert(!foo_thread_await(condition, mutex).error);
  assert(!foo_thread_unlock(mutex).error);
  assert(!foo_thread_wait(worker.pointer).error);
  assert(foo_thread_wait(worker.pointer).error);
  assert(!foo_thread_close(condition).error);
  assert(!foo_thread_close(mutex).error);
  assert(foo_thread_lock(mutex).error);
  assert(foo_thread_signal(condition).error);
  assert(foo_io_close(foo_io_output().pointer).error);
  assert(foo_process_argument(UINT64_MAX).error);
  FooText host = {(const uint8_t *)"127.0.0.1", 9};
  assert(foo_net_listen(host, 65536).error);
  FooResult listener = foo_net_listen(host, 0);
  assert(!listener.error);
  assert(!foo_net_handle(listener.pointer).error);
  assert(!foo_net_close(listener.pointer).error);
  assert(foo_net_handle(listener.pointer).error);
  FooText any = {(const uint8_t *)"any", 3};
  FooText ipv4 = {(const uint8_t *)"ipv4", 4};
  assert(foo_net_parse4(host).number == 0x7f000001u);
  FooResult formatted = foo_net_format4(0x7f000001u);
  assert(!formatted.error && formatted.text.len == host.len);
  assert(!memcmp(formatted.text.data, host.data, host.len));
  assert(!foo_text_release(formatted.text).error);
  FooText loopback6 = {(const uint8_t *)"::1", 3};
  assert(foo_net_parse6high(loopback6).number == 0);
  assert(foo_net_parse6low(loopback6).number == 1);
  formatted = foo_net_format6(0, 1);
  assert(!formatted.error && formatted.text.len == loopback6.len);
  assert(!memcmp(formatted.text.data, loopback6.data, loopback6.len));
  assert(!foo_text_release(formatted.text).error);
  assert(foo_net_parse4(loopback6).error);
  assert(foo_net_parse6high(host).error);
  FooResult listener6 = foo_net_host(0, 1, 0, 0);
  if (!listener6.error) {
    FooResult port6 = foo_net_port(listener6.pointer);
    assert(!port6.error && port6.number > 0);
    FooResult client6 = foo_net_establish(0, 1, port6.number, 0);
    assert(!client6.error);
    FooResult accepted6 = foo_net_accept(listener6.pointer);
    assert(!accepted6.error);
    assert(!foo_net_close(accepted6.pointer).error);
    assert(!foo_net_close(client6.pointer).error);
    assert(!foo_net_close(listener6.pointer).error);
  }
  assert(foo_net_records(host, (FooText){(const uint8_t *)"invalid", 7}).error);
  FooResult answers = foo_net_records((FooText){(const uint8_t *)"localhost", 9},
                                       (FooText){(const uint8_t *)"a", 1});
  if (!answers.error) {
    FooResult count = foo_net_amount(answers.pointer);
    assert(!count.error);
    for (uint64_t index = 0; index < count.number; index++) {
      assert(!foo_net_domain(answers.pointer, index).error);
      assert(!foo_net_datum(answers.pointer, index).error);
      assert(!foo_net_classification(answers.pointer, index).error);
      assert(!foo_net_ttl(answers.pointer, index).error);
    }
    assert(foo_net_datum(answers.pointer, count.number).error);
    assert(!foo_net_forget(answers.pointer).error);
    assert(foo_net_amount(answers.pointer).error);
  }
  FooResult adapters = foo_net_adapters();
  assert(!adapters.error);
  FooResult adapter_count = foo_net_census(adapters.pointer);
  assert(!adapter_count.error);
  for (uint64_t index = 0; index < adapter_count.number; index++) {
    assert(!foo_net_caption(adapters.pointer, index).error);
    assert(!foo_net_origin(adapters.pointer, index).error);
    assert(!foo_net_medium(adapters.pointer, index).error);
    assert(!foo_net_slot(adapters.pointer, index).error);
    assert(!foo_net_ceiling(adapters.pointer, index).error);
  }
  assert(foo_net_origin(adapters.pointer, adapter_count.number).error);
  assert(!foo_net_retire(adapters.pointer).error);
  assert(foo_net_census(adapters.pointer).error);
  FooResult routes = foo_net_routes();
  assert(!routes.error);
  FooResult route_count = foo_net_tally(routes.pointer);
  assert(!route_count.error);
  for (uint64_t index = 0; index < route_count.number; index++) {
    assert(!foo_net_target(routes.pointer, index).error);
    assert(!foo_net_via(routes.pointer, index).error);
    assert(!foo_net_protocol(routes.pointer, index).error);
    assert(!foo_net_mask(routes.pointer, index).error);
    assert(!foo_net_ordinal(routes.pointer, index).error);
    assert(!foo_net_cost(routes.pointer, index).error);
  }
  assert(foo_net_target(routes.pointer, route_count.number).error);
  assert(!foo_net_dismiss(routes.pointer).error);
  assert(foo_net_tally(routes.pointer).error);
  FooResult resolved = foo_net_lookup(host, ipv4);
  assert(!resolved.error && resolved.text.len == host.len);
  assert(!memcmp(resolved.text.data, host.data, host.len));
  assert(!foo_text_release(resolved.text).error);
  assert(foo_net_lookup(host, (FooText){(const uint8_t *)"bad", 3}).error);
  assert(foo_net_bind(host, 65536).error);
  FooResult receiver = foo_net_bind(host, 0);
  FooResult sender = foo_net_bind(host, 0);
  assert(!receiver.error && !sender.error);
  assert(!foo_net_broadcast(sender.pointer, true).error);
  assert(!foo_net_broadcast(sender.pointer, false).error);
  assert(!foo_net_choose4(sender.pointer, 0x7f000001u).error);
  assert(!foo_net_radius(sender.pointer, 1).error);
  assert(!foo_net_recirculate(sender.pointer, true).error);
  assert(foo_net_radius(sender.pointer, 256).error);
  assert(foo_net_choose6(sender.pointer, 0).error);
  assert(foo_net_membership4(receiver.pointer, 0x7f000001u, 0, true).error);
  assert(foo_net_membership6(receiver.pointer, 0xff02000000000000ULL,
                             1, 0, true).error);
  FooResult joined = foo_net_membership4(receiver.pointer, 0xe00000fbu, 0, true);
  if (!joined.error)
    assert(!foo_net_membership4(receiver.pointer, 0xe00000fbu, 0, false).error);
  FooResult port = foo_net_local(receiver.pointer);
  assert(!port.error && port.number > 0);
  uint8_t datagram_bytes[] = {0, 42, 255};
  FooText payload = {datagram_bytes, sizeof(datagram_bytes)};
  FooResult sent = foo_net_transmit(sender.pointer, host, port.number, payload);
  assert(!sent.error && sent.number == sizeof(datagram_bytes));
  FooResult packet = foo_net_collect(receiver.pointer, sizeof(datagram_bytes));
  assert(!packet.error);
  FooResult received = foo_net_raw(packet.pointer);
  assert(!received.error && received.text.len == sizeof(datagram_bytes));
  assert(!memcmp(received.text.data, datagram_bytes, sizeof(datagram_bytes)));
  FooResult peer = foo_net_peer(packet.pointer);
  assert(!peer.error && peer.text.len == host.len);
  assert(!memcmp(peer.text.data, host.data, host.len));
  assert(foo_net_source(packet.pointer).number == foo_net_local(sender.pointer).number);
  assert(foo_net_peer4(packet.pointer).number == 0x7f000001u);
  assert(foo_net_peer6high(packet.pointer).error);
  assert(!foo_net_discard(packet.pointer).error);
  assert(foo_net_raw(packet.pointer).error);
  assert(foo_net_discard(packet.pointer).error);
  sent = foo_net_transmit(sender.pointer, host, port.number, (FooText){NULL, 0});
  assert(!sent.error && sent.number == 0);
  packet = foo_net_collect(receiver.pointer, 0);
  assert(!packet.error && foo_net_raw(packet.pointer).text.len == 0);
  assert(!foo_net_discard(packet.pointer).error);
  assert(!foo_net_affiliate(sender.pointer, host, port.number).error);
  sent = foo_net_submit(sender.pointer, payload);
  assert(!sent.error && sent.number == payload.len);
  packet = foo_net_collect(receiver.pointer, payload.len);
  assert(!packet.error && foo_net_peer4(packet.pointer).number == 0x7f000001u);
  assert(!foo_net_discard(packet.pointer).error);
  assert(!foo_net_detach(sender.pointer).error);
  assert(!foo_net_detach(receiver.pointer).error);
  assert(foo_net_local(receiver.pointer).error);
  FooResult receiver6 = foo_net_bind(loopback6, 0);
  FooResult sender6 = foo_net_bind(loopback6, 0);
  if (!receiver6.error && !sender6.error) {
    assert(!foo_net_choose6(sender6.pointer, 0).error);
    assert(!foo_net_radius(sender6.pointer, 1).error);
    assert(!foo_net_recirculate(sender6.pointer, true).error);
    FooResult port6 = foo_net_local(receiver6.pointer);
    assert(!port6.error);
    sent = foo_net_transmit6(sender6.pointer, 0, 1, port6.number, 0, payload);
    assert(!sent.error && sent.number == payload.len);
    packet = foo_net_collect(receiver6.pointer, payload.len);
    assert(!packet.error && foo_net_raw(packet.pointer).text.len == payload.len);
    assert(foo_net_peer6high(packet.pointer).number == 0);
    assert(foo_net_peer6low(packet.pointer).number == 1);
    assert(foo_net_zone(packet.pointer).number == 0);
    assert(foo_net_peer4(packet.pointer).error);
    assert(!foo_net_discard(packet.pointer).error);
    assert(!foo_net_affiliate6(sender6.pointer, 0, 1, port6.number, 0).error);
    sent = foo_net_submit(sender6.pointer, payload);
    assert(!sent.error && sent.number == payload.len);
    packet = foo_net_collect(receiver6.pointer, payload.len);
    assert(!packet.error && foo_net_peer6low(packet.pointer).number == 1);
    assert(!foo_net_discard(packet.pointer).error);
    assert(!foo_net_detach(sender6.pointer).error);
    assert(!foo_net_detach(receiver6.pointer).error);
  } else {
    if (!receiver6.error) assert(!foo_net_detach(receiver6.pointer).error);
    if (!sender6.error) assert(!foo_net_detach(sender6.pointer).error);
  }
  resolved = foo_net_lookup(host, any);
  assert(!resolved.error && resolved.text.len > 0);
  assert(!foo_text_release(resolved.text).error);
  FooText invalid = {(const uint8_t *)"A\0B", 3};
  assert(foo_process_environment(invalid).error);
  FooText process_arguments[] = {
      {(const uint8_t *)"-e", 2},
      {(const uint8_t *)"process.exit(9)", 15},
  };
  FooResult executed = foo_process_execute(
      (FooText){(const uint8_t *)"node", 4},
      (FooText){(const uint8_t *)process_arguments, 2});
  assert(!executed.error && executed.number == 9);
  assert(foo_process_id().number > 0);
  assert(!foo_process_parent().error && foo_process_parent().number > 0);
  FooResult child = foo_process_spawn(
      (FooText){(const uint8_t *)"node", 4},
      (FooText){(const uint8_t *)process_arguments, 2});
  assert(!child.error && foo_process_identity(child.pointer).number > 0);
  assert(foo_process_wait(child.pointer).number == 9);
  assert(foo_process_active(child.pointer).number == 0);
  assert(!foo_process_close(child.pointer).error);
  assert(foo_process_wait(child.pointer).error);

  FooText pipe_arguments[] = {
      value("-e"),
      value("const a=[];process.stdin.on('data',x=>a.push(x));"
            "process.stdin.on('end',()=>{process.stdout.write(Buffer.concat(a));"
            "process.stderr.write(Buffer.from([9,8]));})"),
  };
  FooText pipe_items = {(const uint8_t *)pipe_arguments, 2};
  assert(foo_process_pipe(value("foo-missing-program-7f19"), pipe_items).error);
  FooResult piped = foo_process_pipe(value("node"), pipe_items);
  assert(!piped.error);
  uint8_t piped_bytes[] = {0, 255, 42};
  FooText piped_content = {piped_bytes, sizeof(piped_bytes)};
  FooResult piped_sent = foo_process_write(piped.pointer, piped_content);
  assert(!piped_sent.error && piped_sent.number == sizeof(piped_bytes));
  assert(!foo_process_seal(piped.pointer).error);
  assert(foo_process_write(piped.pointer, piped_content).error);
  for (size_t index = 0; index < sizeof(piped_bytes); index++) {
    FooResult chunk = foo_process_read(piped.pointer, value("output"), 1);
    assert(!chunk.error && chunk.text.len == 1 &&
           chunk.text.data[0] == piped_bytes[index]);
    assert(!foo_process_release(chunk.text).error);
  }
  FooResult eof = foo_process_read(piped.pointer, value("output"), 1);
  assert(!eof.error && eof.text.len == 0);
  assert(!foo_process_release(eof.text).error);
  FooResult report = foo_process_read(piped.pointer, value("error"), 2);
  assert(!report.error && report.text.len == 2 &&
         report.text.data[0] == 9 && report.text.data[1] == 8);
  assert(!foo_process_release(report.text).error);
  assert(foo_process_wait(piped.pointer).number == 0);
  assert(!foo_process_close(piped.pointer).error);
  assert(foo_process_read(piped.pointer, value("output"), 1).error);

  {
    uint64_t edges[] = {10, 20};
    FooResult meter = foo_metric_create(value("latency"), value("histogram"),
        (FooText){(const uint8_t *)edges, 2});
    assert(!meter.error);
    assert(!foo_metric_observe(meter.pointer, 10).error);
    assert(!foo_metric_observe(meter.pointer, 11).error);
    assert(!foo_metric_observe(meter.pointer, 99).error);
    assert(foo_metric_count(meter.pointer).number == 3);
    assert(foo_metric_sum(meter.pointer).number == 120);
    assert(foo_metric_bucket(meter.pointer, 0).number == 1);
    assert(foo_metric_bucket(meter.pointer, 1).number == 1);
    assert(foo_metric_bucket(meter.pointer, 2).number == 1);
    assert(foo_metric_bucket(meter.pointer, 3).error);
    FooResult label = foo_metric_name(meter.pointer);
    assert(!label.error && label.text.len == 7 &&
           !memcmp(label.text.data, "latency", 7));
    assert(!foo_text_release(label.text).error);
    assert(!foo_metric_close(meter.pointer).error);
    assert(foo_metric_observe(meter.pointer, 1).error);
    FooResult counter = foo_metric_create(value("jobs"), value("counter"),
                                         (FooText){0});
    assert(!counter.error);
    FooResult workers[4];
    for (size_t index = 0; index < 4; index++) {
      workers[index] = foo_thread_spawn(add_metric, counter.pointer);
      assert(!workers[index].error);
    }
    for (size_t index = 0; index < 4; index++)
      assert(!foo_thread_wait(workers[index].pointer).error);
    assert(foo_metric_value(counter.pointer).number == 4000);
    assert(!foo_metric_close(counter.pointer).error);

    FooResult outer = foo_trace_begin(value("outer"));
    assert(!outer.error);
    uint64_t parent = foo_trace_identity(outer.pointer).number;
    FooResult inner = foo_trace_begin(value("inner"));
    assert(!inner.error && foo_trace_parent(inner.pointer).number == parent);
    assert(foo_trace_finish(outer.pointer).error);
    FooResult elapsed = foo_trace_finish(inner.pointer);
    assert(!elapsed.error && foo_trace_elapsed(inner.pointer).number == elapsed.number);
    assert(!foo_trace_close(inner.pointer).error);
    assert(foo_trace_current().number == parent);
    assert(!foo_trace_finish(outer.pointer).error);
    assert(!foo_trace_close(outer.pointer).error);
    assert(foo_trace_current().number == 0);

    assert(!foo_limit_available(value("unknown")).number);
    assert(foo_limit_soft(value("unknown")).error);
    if (foo_limit_available(value("files")).number) {
      FooResult soft = foo_limit_soft(value("files"));
      FooResult hard = foo_limit_hard(value("files"));
      assert(!soft.error && !hard.error && soft.number <= hard.number);
      assert(!foo_limit_set(value("files"), soft.number).error);
    } else assert(foo_limit_soft(value("files")).error);
  }

  FooResult timer = foo_timer_create();
  assert(!timer.error);
  assert(!foo_timer_arm(timer.pointer, 1000000000).error);
  atomic_store(&timer_finished, 0);
  FooResult waiter = foo_thread_spawn(await_timer, timer.pointer);
  assert(!waiter.error);
  assert(!foo_time_sleep(10000000).error);
  assert(!foo_timer_cancel(timer.pointer).error);
  assert(!foo_thread_wait(waiter.pointer).error);
  assert(atomic_load(&timer_finished) == 1);
  assert(!foo_timer_arm(timer.pointer, 0).error);
  assert(foo_timer_wait(timer.pointer).number == 1);
  assert(!foo_timer_close(timer.pointer).error);
  assert(foo_timer_wait(timer.pointer).error);

  const char *path = "foo-service-read.tmp";
  FILE *file = fopen(path, "wb");
  assert(file);
  for (int index = 0; index < 10000; index++)
    assert(fputc('a' + index % 26, file) != EOF);
  assert(!fclose(file));
  FooResult content = foo_fs_read((FooText){(const uint8_t *)path, strlen(path)});
  assert(!content.error && content.text.len == 10000);
  for (size_t index = 0; index < content.text.len; index++)
    assert(content.text.data[index] == (uint8_t)('a' + index % 26));
  assert(!foo_text_release(content.text).error);
  assert(!remove(path));

  const char *draft = "foo-service-draft.tmp";
  const char *live = "foo-service-live.tmp";
  FooText bytes = {(const uint8_t *)"A\0B\xff", 4};
  FooResult output = foo_fs_open(
      (FooText){(const uint8_t *)draft, strlen(draft)},
      (FooText){(const uint8_t *)"write", 5});
  assert(!output.error);
  FooResult native = foo_fs_handle(output.pointer);
  assert(!native.error);
  assert(!foo_io_write(output.pointer, bytes).error);
  assert(!foo_fs_sync(output.pointer).error);
  assert(!foo_io_close(output.pointer).error);
  assert(foo_fs_handle(output.pointer).error);
  assert(!foo_fs_replace(
      (FooText){(const uint8_t *)draft, strlen(draft)},
      (FooText){(const uint8_t *)live, strlen(live)}).error);
  FooResult exists = foo_fs_exists(
      (FooText){(const uint8_t *)live, strlen(live)});
  assert(!exists.error && exists.number == 1);
  FooResult kind = foo_fs_kind(
      (FooText){(const uint8_t *)live, strlen(live)});
  assert(!kind.error && kind.text.len == 4 &&
         !memcmp(kind.text.data, "file", 4));
  assert(!foo_text_release(kind.text).error);
  FooResult working = foo_fs_working();
  assert(!working.error && working.text.len > 0);
  assert(!foo_text_release(working.text).error);
  const char *copy = "foo-service-copy.tmp";
  assert(!foo_fs_copy(
      (FooText){(const uint8_t *)live, strlen(live)},
      (FooText){(const uint8_t *)copy, strlen(copy)}).error);
  assert(!foo_fs_remove(
      (FooText){(const uint8_t *)copy, strlen(copy)}).error);
  content = foo_fs_load(
      (FooText){(const uint8_t *)live, strlen(live)});
  assert(!content.error && content.text.len == bytes.len);
  assert(!memcmp(content.text.data, bytes.data, bytes.len));
  assert(!foo_fs_release(content.text).error);
  assert(!foo_fs_remove(
      (FooText){(const uint8_t *)live, strlen(live)}).error);
  exists = foo_fs_exists((FooText){(const uint8_t *)live, strlen(live)});
  assert(!exists.error && exists.number == 0);
  assert(foo_fs_read(
      (FooText){(const uint8_t *)live, strlen(live)}).error);

  FooText haystack = {(const uint8_t *)"short searchable text", 21};
  FooText needle = {(const uint8_t *)"search", 6};
  FooResult found = foo_text_find(haystack, needle);
  assert(found.pointer && found.number == 6);
  uint8_t large[4096];
  memset(large, 'x', sizeof(large));
  memcpy(large + 3000, "adaptive", 8);
  found = foo_text_find((FooText){large, sizeof(large)},
                        (FooText){(const uint8_t *)"adaptive", 8});
  assert(found.pointer && found.number == 3000);
  found = foo_text_find((FooText){large, sizeof(large)},
                        (FooText){(const uint8_t *)"missing", 7});
  assert(!found.pointer);

  FooResult pool = foo_task_pool();
  assert(!pool.error);
  atomic_store(&total, 0);
  for (int value = 1; value <= 200; value++)
    assert(foo_task_submit(pool.pointer, accumulate, value).number == 1);
  assert(!foo_task_wait(pool.pointer).error);
  assert(atomic_load(&total) == 20100);
  verify_cancellation();
}

#ifdef FOO_SERVICE_TEST_MAIN
int main(int argc, char **argv) {
  foo_service_init(argc, argv);
  verify();
  FooResult pool = foo_task_pool();
  assert(!pool.error);
  atomic_store(&total, 0);
  for (int value = 1; value <= 200; value++)
    assert(foo_task_submit(pool.pointer, accumulate, value).number == 1);
  foo_service_close();
  assert(atomic_load(&total) == 20100);
  puts("native service parity: ok");
  return 0;
}
#endif
