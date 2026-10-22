static int parse(FooText host, int family, uint8_t *bytes) {
  if (!initialize()) return 0;
  char *name = string(host);
  if (!name || !host.len) { free(name); return 0; }
  int valid = inet_pton(family, name, bytes) == 1;
  free(name);
  return valid;
}
static uint64_t half(const uint8_t *bytes) {
  uint64_t value = 0;
  for (int index = 0; index < 8; index++) value = (value << 8) | bytes[index];
  return value;
}
FooResult foo_net_parse4(FooText host) {
  uint8_t bytes[4];
  if (!parse(host, AF_INET, bytes)) return failure(ARGUMENT);
  return (FooResult){.number = ((uint64_t)bytes[0] << 24) |
      ((uint64_t)bytes[1] << 16) | ((uint64_t)bytes[2] << 8) | bytes[3]};
}
FooResult foo_net_parse6high(FooText host) {
  uint8_t bytes[16];
  return parse(host, AF_INET6, bytes)
      ? (FooResult){.number = half(bytes)} : failure(ARGUMENT);
}
FooResult foo_net_parse6low(FooText host) {
  uint8_t bytes[16];
  return parse(host, AF_INET6, bytes)
      ? (FooResult){.number = half(bytes + 8)} : failure(ARGUMENT);
}
FooResult foo_net_format4(uint32_t bits) {
  if (!initialize()) return failure(SYSTEM);
  uint8_t bytes[4] = {(uint8_t)(bits >> 24), (uint8_t)(bits >> 16),
                      (uint8_t)(bits >> 8), (uint8_t)bits};
  char numeric[INET_ADDRSTRLEN];
  if (!inet_ntop(AF_INET, bytes, numeric, sizeof(numeric))) return failure(IO);
  return text(numeric, strlen(numeric));
}
FooResult foo_net_format6(uint64_t high, uint64_t low) {
  if (!initialize()) return failure(SYSTEM);
  uint8_t bytes[16];
  for (int index = 7; index >= 0; index--) {
    bytes[index] = (uint8_t)high;
    bytes[index + 8] = (uint8_t)low;
    high >>= 8;
    low >>= 8;
  }
  char numeric[INET6_ADDRSTRLEN];
  if (!inet_ntop(AF_INET6, bytes, numeric, sizeof(numeric))) return failure(IO);
  return text(numeric, strlen(numeric));
}
FooResult foo_net_lookup(FooText host, FooText family) {
  if (!initialize()) return failure(SYSTEM);
  int selected = family.len == 3 && !memcmp(family.data, "any", 3) ? AF_UNSPEC
      : family.len == 4 && !memcmp(family.data, "ipv4", 4) ? AF_INET
      : family.len == 4 && !memcmp(family.data, "ipv6", 4) ? AF_INET6 : -1;
  if (selected < 0 || !host.len) return failure(ARGUMENT);
  char *name = string(host);
  if (!name) return failure(ARGUMENT);
  struct addrinfo hints = {0}, *addresses = NULL;
  hints.ai_family = selected;
  hints.ai_socktype = SOCK_DGRAM;
  int problem = getaddrinfo(name, NULL, &hints, &addresses);
  free(name);
  if (problem) return failure(MISSING);
  char numeric[INET6_ADDRSTRLEN];
  const void *ip = addresses->ai_family == AF_INET
      ? (const void *)&((struct sockaddr_in *)addresses->ai_addr)->sin_addr
      : (const void *)&((struct sockaddr_in6 *)addresses->ai_addr)->sin6_addr;
  const char *converted = inet_ntop(addresses->ai_family, ip, numeric,
                                   sizeof(numeric));
  FooResult result = converted ? text(numeric, strlen(numeric)) : failure(IO);
  freeaddrinfo(addresses);
  return result;
}

typedef struct {
  char name[256];
  char value[512];
  char kind[6];
  uint32_t ttl;
} Record;
typedef struct {
  size_t count;
  Record entries[];
} Records;
static int classify(FooText kind) {
  if (kind.len == 1 && !memcmp(kind.data, "a", 1)) return 1;
  if (kind.len == 4 && !memcmp(kind.data, "aaaa", 4)) return 28;
  if (kind.len == 5 && !memcmp(kind.data, "cname", 5)) return 5;
  if (kind.len == 2 && !memcmp(kind.data, "ns", 2)) return 2;
  if (kind.len == 3 && !memcmp(kind.data, "ptr", 3)) return 12;
  if (kind.len == 2 && !memcmp(kind.data, "mx", 2)) return 15;
  if (kind.len == 3 && !memcmp(kind.data, "srv", 3)) return 33;
  if (kind.len == 3 && !memcmp(kind.data, "txt", 3)) return 16;
  return 0;
}
static const char *label(int kind) {
  return kind == 1 ? "a" : kind == 28 ? "aaaa" : kind == 5 ? "cname"
      : kind == 2 ? "ns" : kind == 12 ? "ptr" : kind == 15 ? "mx"
      : kind == 16 ? "txt" : "srv";
}
FooResult foo_net_records(FooText host, FooText kind) {
  if (!initialize()) return failure(SYSTEM);
  int selected = classify(kind);
  if (!selected || !host.len) return failure(ARGUMENT);
  char *name = string(host);
  if (!name) return failure(ARGUMENT);
#ifdef _WIN32
  DNS_RECORDA *answers = NULL;
  DNS_STATUS status = DnsQuery_A(name, (WORD)selected, DNS_QUERY_STANDARD,
                                 NULL, (PDNS_RECORD *)&answers, NULL);
  free(name);
  if (status != ERROR_SUCCESS) return failure(MISSING);
  size_t capacity = 0;
  for (DNS_RECORDA *item = answers; item; item = item->pNext) capacity++;
#else
  unsigned char answer[65536];
  int length = res_query(name, ns_c_in, selected, answer, sizeof(answer));
  free(name);
  if (length < 0) return failure(MISSING);
  ns_msg message;
  if (ns_initparse(answer, length, &message) < 0) return failure(IO);
  size_t capacity = (size_t)ns_msg_count(message, ns_s_an);
#endif
  if (capacity > (SIZE_MAX - sizeof(Records)) / sizeof(Record)) {
#ifdef _WIN32
    DnsRecordListFree(answers, DnsFreeRecordList);
#endif
    return failure(BOUNDS);
  }
  Records *set = owned(sizeof(*set) + capacity * sizeof(Record), DNS_SETS);
  if (!set) {
#ifdef _WIN32
    DnsRecordListFree(answers, DnsFreeRecordList);
#endif
    return failure(MEMORY);
  }
#ifdef _WIN32
  for (DNS_RECORDA *item = answers; item; item = item->pNext) {
    int type = item->wType;
    if (type != 1 && type != 28 && type != 5 && type != 2 && type != 12 &&
        type != 15 && type != 16 && type != 33) continue;
    Record *entry = &set->entries[set->count];
    const char *owner = item->pName ? item->pName : "";
    if (strlen(owner) >= sizeof(entry->name)) continue;
    memcpy(entry->name, owner, strlen(owner) + 1);
    strcpy(entry->kind, label(type));
    entry->ttl = item->dwTtl;
    if (type == 16) {
      size_t used = 0;
      bool valid = true;
      for (DWORD part = 0; part < item->Data.TXT.dwStringCount; part++) {
        const char *value = item->Data.TXT.pStringArray[part];
        if (!value) { valid = false; break; }
        size_t length = strlen(value);
        if (length > sizeof(entry->value) - used - 1) { valid = false; break; }
        memcpy(entry->value + used, value, length);
        used += length;
      }
      if (!valid) continue;
      entry->value[used] = 0;
    } else if (type == 5 || type == 2 || type == 12) {
      const char *target = item->Data.CNAME.pNameHost;
      if (!target || strlen(target) >= sizeof(entry->value)) continue;
      memcpy(entry->value, target, strlen(target) + 1);
    } else if (type == 15) {
      const char *target = item->Data.MX.pNameExchange;
      if (!target || snprintf(entry->value, sizeof(entry->value), "%u %s",
                              item->Data.MX.wPreference, target) >=
                         (int)sizeof(entry->value)) continue;
    } else if (type == 33) {
      const char *target = item->Data.SRV.pNameTarget;
      if (!target || snprintf(entry->value, sizeof(entry->value), "%u %u %u %s",
                              item->Data.SRV.wPriority, item->Data.SRV.wWeight,
                              item->Data.SRV.wPort, target) >=
                         (int)sizeof(entry->value)) continue;
    } else {
      const void *bytes = type == 1 ? (const void *)&item->Data.A.IpAddress
          : (const void *)&item->Data.AAAA.Ip6Address;
      if (!inet_ntop(type == 1 ? AF_INET : AF_INET6, bytes, entry->value,
                     sizeof(entry->value))) continue;
    }
    set->count++;
  }
  DnsRecordListFree(answers, DnsFreeRecordList);
#else
  for (size_t index = 0; index < capacity; index++) {
    ns_rr record;
    if (ns_parserr(&message, ns_s_an, (int)index, &record) < 0) continue;
    int type = ns_rr_type(record);
    if (type != 1 && type != 28 && type != 5 && type != 2 && type != 12 &&
        type != 15 && type != 16 && type != 33) continue;
    Record *entry = &set->entries[set->count];
    const char *owner = ns_rr_name(record);
    if (strlen(owner) >= sizeof(entry->name)) continue;
    memcpy(entry->name, owner, strlen(owner) + 1);
    strcpy(entry->kind, label(type));
    entry->ttl = (uint32_t)ns_rr_ttl(record);
    if (type == 16) {
      const uint8_t *data = ns_rr_rdata(record);
      size_t length = ns_rr_rdlen(record), cursor = 0, used = 0;
      while (cursor < length) {
        size_t part = data[cursor++];
        if (part > length - cursor || part > sizeof(entry->value) - used - 1) break;
        memcpy(entry->value + used, data + cursor, part);
        cursor += part;
        used += part;
      }
      if (cursor != length) continue;
      entry->value[used] = 0;
    } else if (type == 5 || type == 2 || type == 12) {
      if (dn_expand(answer, answer + length, ns_rr_rdata(record),
                    entry->value, sizeof(entry->value)) < 0) continue;
    } else if (type == 15 || type == 33) {
      int header = type == 15 ? 2 : 6;
      if (ns_rr_rdlen(record) < header) continue;
      const uint8_t *data = ns_rr_rdata(record);
      char target[256];
      if (dn_expand(answer, answer + length, data + header,
                    target, sizeof(target)) < 0) continue;
      if (type == 15) {
        unsigned preference = ((unsigned)data[0] << 8) | data[1];
        if (snprintf(entry->value, sizeof(entry->value), "%u %s",
                     preference, target) >= (int)sizeof(entry->value)) continue;
      } else {
        unsigned priority = ((unsigned)data[0] << 8) | data[1];
        unsigned weight = ((unsigned)data[2] << 8) | data[3];
        unsigned port = ((unsigned)data[4] << 8) | data[5];
        if (snprintf(entry->value, sizeof(entry->value), "%u %u %u %s",
                     priority, weight, port, target) >=
            (int)sizeof(entry->value)) continue;
      }
    } else {
      if (ns_rr_rdlen(record) != (type == 1 ? 4 : 16) ||
          !inet_ntop(type == 1 ? AF_INET : AF_INET6, ns_rr_rdata(record),
                     entry->value, sizeof(entry->value))) continue;
    }
    set->count++;
  }
#endif
  return (FooResult){.pointer = set};
}
FooResult foo_net_amount(void *pointer) {
  return resource(pointer, DNS_SETS)
      ? (FooResult){.number = ((Records *)pointer)->count} : failure(CLOSED);
}
static Record *record(void *pointer, uint64_t index) {
  if (!resource(pointer, DNS_SETS)) return NULL;
  Records *set = pointer;
  return index < set->count ? &set->entries[index] : NULL;
}
FooResult foo_net_domain(void *pointer, uint64_t index) {
  Record *entry = record(pointer, index);
  return entry ? (FooResult){.text = {(const uint8_t *)entry->name,
                                     strlen(entry->name)}} : failure(BOUNDS);
}
FooResult foo_net_datum(void *pointer, uint64_t index) {
  Record *entry = record(pointer, index);
  return entry ? (FooResult){.text = {(const uint8_t *)entry->value,
                                     strlen(entry->value)}} : failure(BOUNDS);
}
FooResult foo_net_classification(void *pointer, uint64_t index) {
  Record *entry = record(pointer, index);
  return entry ? (FooResult){.text = {(const uint8_t *)entry->kind,
                                     strlen(entry->kind)}} : failure(BOUNDS);
}
FooResult foo_net_ttl(void *pointer, uint64_t index) {
  Record *entry = record(pointer, index);
  return entry ? (FooResult){.number = entry->ttl} : failure(BOUNDS);
}
FooResult foo_net_forget(void *pointer) {
  Resource *entry = resource(pointer, DNS_SETS);
  if (!entry) return failure(CLOSED);
  entry->closed = 1;
  return (FooResult){0};
}

typedef struct {
  char name[256];
  char ip[INET6_ADDRSTRLEN];
  uint32_t index;
  uint32_t mtu;
  int family;
} Adapter;
typedef struct {
  size_t count;
  Adapter entries[];
} Adapters;
FooResult foo_net_adapters(void) {
  if (!initialize()) return failure(SYSTEM);
#ifdef _WIN32
  ULONG length = 15000;
  IP_ADAPTER_ADDRESSES *head = NULL;
  ULONG status = ERROR_BUFFER_OVERFLOW;
  for (int attempt = 0; attempt < 4 && status == ERROR_BUFFER_OVERFLOW; attempt++) {
    IP_ADAPTER_ADDRESSES *next = realloc(head, length);
    if (!next) { free(head); return failure(MEMORY); }
    head = next;
    status = GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_INCLUDE_PREFIX,
                                  NULL, head, &length);
    if (length > 1 << 20) { free(head); return failure(BOUNDS); }
  }
  if (status != NO_ERROR && status != ERROR_NO_DATA) {
    free(head);
    return failure(IO);
  }
  size_t capacity = 0;
  if (status == NO_ERROR)
    for (IP_ADAPTER_ADDRESSES *adapter = head; adapter; adapter = adapter->Next)
      for (IP_ADAPTER_UNICAST_ADDRESS *ip = adapter->FirstUnicastAddress;
           ip; ip = ip->Next)
        if (ip->Address.lpSockaddr &&
            (ip->Address.lpSockaddr->sa_family == AF_INET ||
             ip->Address.lpSockaddr->sa_family == AF_INET6)) capacity++;
#else
  struct ifaddrs *head = NULL;
  if (getifaddrs(&head)) return failure(IO);
  size_t capacity = 0;
  for (struct ifaddrs *item = head; item; item = item->ifa_next)
    if (item->ifa_addr && (item->ifa_addr->sa_family == AF_INET ||
                           item->ifa_addr->sa_family == AF_INET6)) capacity++;
#endif
  if (capacity > (SIZE_MAX - sizeof(Adapters)) / sizeof(Adapter)) {
#ifdef _WIN32
    free(head);
#else
    freeifaddrs(head);
#endif
    return failure(BOUNDS);
  }
  Adapters *list = owned(sizeof(*list) + capacity * sizeof(Adapter),
                            ADAPTER_LISTS);
  if (!list) {
#ifdef _WIN32
    free(head);
#else
    freeifaddrs(head);
#endif
    return failure(MEMORY);
  }
#ifdef _WIN32
  if (status == NO_ERROR)
    for (IP_ADAPTER_ADDRESSES *adapter = head; adapter; adapter = adapter->Next)
      for (IP_ADAPTER_UNICAST_ADDRESS *ip = adapter->FirstUnicastAddress;
           ip; ip = ip->Next) {
        struct sockaddr *address = ip->Address.lpSockaddr;
        if (!address || (address->sa_family != AF_INET &&
                         address->sa_family != AF_INET6)) continue;
        Adapter *entry = &list->entries[list->count];
        const void *bytes = address->sa_family == AF_INET
            ? (const void *)&((struct sockaddr_in *)address)->sin_addr
            : (const void *)&((struct sockaddr_in6 *)address)->sin6_addr;
        if (!inet_ntop(address->sa_family, bytes, entry->ip,
                       sizeof(entry->ip))) continue;
        snprintf(entry->name, sizeof(entry->name), "%s", adapter->AdapterName);
        entry->family = address->sa_family;
        entry->index = address->sa_family == AF_INET
            ? adapter->IfIndex : adapter->Ipv6IfIndex;
        entry->mtu = adapter->Mtu;
        list->count++;
      }
  free(head);
#else
  Socket probe = socket(AF_INET, SOCK_DGRAM, 0);
  for (struct ifaddrs *item = head; item; item = item->ifa_next) {
    if (!item->ifa_addr || (item->ifa_addr->sa_family != AF_INET &&
                            item->ifa_addr->sa_family != AF_INET6)) continue;
    Adapter *entry = &list->entries[list->count];
    const void *bytes = item->ifa_addr->sa_family == AF_INET
        ? (const void *)&((struct sockaddr_in *)item->ifa_addr)->sin_addr
        : (const void *)&((struct sockaddr_in6 *)item->ifa_addr)->sin6_addr;
    if (!inet_ntop(item->ifa_addr->sa_family, bytes, entry->ip,
                   sizeof(entry->ip))) continue;
    snprintf(entry->name, sizeof(entry->name), "%s", item->ifa_name);
    entry->family = item->ifa_addr->sa_family;
    entry->index = if_nametoindex(item->ifa_name);
    if (probe != INVALID) {
      struct ifreq request = {0};
      strncpy(request.ifr_name, item->ifa_name, sizeof(request.ifr_name) - 1);
      if (!ioctl(probe, SIOCGIFMTU, &request) && request.ifr_mtu > 0)
        entry->mtu = (uint32_t)request.ifr_mtu;
    }
    list->count++;
  }
  if (probe != INVALID) disconnect(probe);
  freeifaddrs(head);
#endif
  return (FooResult){.pointer = list};
}
static Adapter *adapter(void *pointer, uint64_t index) {
  if (!resource(pointer, ADAPTER_LISTS)) return NULL;
  Adapters *list = pointer;
  return index < list->count ? &list->entries[index] : NULL;
}
FooResult foo_net_census(void *pointer) {
  return resource(pointer, ADAPTER_LISTS)
      ? (FooResult){.number = ((Adapters *)pointer)->count} : failure(CLOSED);
}
FooResult foo_net_caption(void *pointer, uint64_t index) {
  Adapter *entry = adapter(pointer, index);
  return entry ? (FooResult){.text = {(const uint8_t *)entry->name,
                                     strlen(entry->name)}} : failure(BOUNDS);
}
FooResult foo_net_origin(void *pointer, uint64_t index) {
  Adapter *entry = adapter(pointer, index);
  return entry ? (FooResult){.text = {(const uint8_t *)entry->ip,
                                     strlen(entry->ip)}} : failure(BOUNDS);
}
FooResult foo_net_medium(void *pointer, uint64_t index) {
  Adapter *entry = adapter(pointer, index);
  if (!entry) return failure(BOUNDS);
  const char *kind = entry->family == AF_INET ? "ipv4" : "ipv6";
  return (FooResult){.text = {(const uint8_t *)kind, strlen(kind)}};
}
FooResult foo_net_slot(void *pointer, uint64_t index) {
  Adapter *entry = adapter(pointer, index);
  return entry ? (FooResult){.number = entry->index} : failure(BOUNDS);
}
FooResult foo_net_ceiling(void *pointer, uint64_t index) {
  Adapter *entry = adapter(pointer, index);
  return entry ? (FooResult){.number = entry->mtu} : failure(BOUNDS);
}
FooResult foo_net_retire(void *pointer) {
  Resource *entry = resource(pointer, ADAPTER_LISTS);
  if (!entry) return failure(CLOSED);
  entry->closed = 1;
  return (FooResult){0};
}

typedef struct {
  char destination[INET6_ADDRSTRLEN];
  char gateway[INET6_ADDRSTRLEN];
  uint32_t prefix;
  uint32_t index;
  uint32_t metric;
  int family;
} Route;
typedef struct {
  size_t count;
  Route entries[];
} Routes;
static int extend(Route **entries, size_t *count, size_t *capacity,
                        const Route *entry) {
  if (*count == *capacity) {
    if (*capacity > SIZE_MAX / (2 * sizeof(Route))) return 0;
    size_t next = *capacity ? *capacity * 2 : 16;
    Route *grown = realloc(*entries, next * sizeof(Route));
    if (!grown) return 0;
    *entries = grown;
    *capacity = next;
  }
  (*entries)[(*count)++] = *entry;
  return 1;
}
FooResult foo_net_routes(void) {
  if (!initialize()) return failure(SYSTEM);
  Route *entries = NULL;
  size_t count = 0, capacity = 0;
#ifdef _WIN32
  PMIB_IPFORWARD_TABLE2 table = NULL;
  if (GetIpForwardTable2(AF_UNSPEC, &table) != NO_ERROR) return failure(IO);
  int failed = 0;
  for (ULONG index = 0; index < table->NumEntries; index++) {
    const MIB_IPFORWARD_ROW2 *row = &table->Table[index];
    int family = row->DestinationPrefix.Prefix.si_family;
    if (family != AF_INET && family != AF_INET6) continue;
    Route entry = {0};
    const void *destination = family == AF_INET
        ? (const void *)&row->DestinationPrefix.Prefix.Ipv4.sin_addr
        : (const void *)&row->DestinationPrefix.Prefix.Ipv6.sin6_addr;
    if (!inet_ntop(family, destination, entry.destination,
                   sizeof(entry.destination))) continue;
    if (row->NextHop.si_family == family) {
      const void *gateway = family == AF_INET
          ? (const void *)&row->NextHop.Ipv4.sin_addr
          : (const void *)&row->NextHop.Ipv6.sin6_addr;
      if (!inet_ntop(family, gateway, entry.gateway,
                     sizeof(entry.gateway))) continue;
    }
    entry.family = family;
    entry.prefix = row->DestinationPrefix.PrefixLength;
    entry.index = row->InterfaceIndex;
    entry.metric = row->Metric;
    if (!extend(&entries, &count, &capacity, &entry)) { failed = 1; break; }
  }
  FreeMibTable(table);
  if (failed) { free(entries); return failure(MEMORY); }
#elif defined(__linux__)
  Socket route_socket = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
  if (route_socket == INVALID) return failure(IO);
  struct {
    struct nlmsghdr header;
    struct rtmsg route;
  } request = {0};
  request.header.nlmsg_len = NLMSG_LENGTH(sizeof(struct rtmsg));
  request.header.nlmsg_type = RTM_GETROUTE;
  request.header.nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
  request.header.nlmsg_seq = 1;
  request.route.rtm_family = AF_UNSPEC;
  if (send(route_socket, &request, request.header.nlmsg_len, 0) < 0) {
    disconnect(route_socket);
    return failure(IO);
  }
  int done = 0, failed = 0;
  while (!done && !failed) {
    char buffer[32768];
    ssize_t length = recv(route_socket, buffer, sizeof(buffer), 0);
    if (length < 0 && errno == EINTR) continue;
    if (length <= 0) { failed = 1; break; }
    int remaining = (int)length;
    for (struct nlmsghdr *header = (struct nlmsghdr *)buffer;
         NLMSG_OK(header, remaining); header = NLMSG_NEXT(header, remaining)) {
      if (header->nlmsg_type == NLMSG_DONE) { done = 1; break; }
      if (header->nlmsg_type == NLMSG_ERROR) { failed = 1; break; }
      if (header->nlmsg_type != RTM_NEWROUTE) continue;
      struct rtmsg *route = NLMSG_DATA(header);
      if (route->rtm_table != RT_TABLE_MAIN ||
          (route->rtm_family != AF_INET && route->rtm_family != AF_INET6))
        continue;
      Route entry = {0};
      entry.family = route->rtm_family;
      entry.prefix = route->rtm_dst_len;
      uint8_t destination[16] = {0}, gateway[16] = {0};
      int has_gateway = 0, attrs = RTM_PAYLOAD(header);
      for (struct rtattr *attr = RTM_RTA(route); RTA_OK(attr, attrs);
           attr = RTA_NEXT(attr, attrs)) {
        size_t width = entry.family == AF_INET ? 4 : 16;
        if (attr->rta_type == RTA_DST && RTA_PAYLOAD(attr) <= width)
          memcpy(destination, RTA_DATA(attr), RTA_PAYLOAD(attr));
        if (attr->rta_type == RTA_GATEWAY && RTA_PAYLOAD(attr) == width) {
          memcpy(gateway, RTA_DATA(attr), width);
          has_gateway = 1;
        }
        if (attr->rta_type == RTA_OIF && RTA_PAYLOAD(attr) >= sizeof(uint32_t))
          memcpy(&entry.index, RTA_DATA(attr), sizeof(uint32_t));
        if (attr->rta_type == RTA_PRIORITY &&
            RTA_PAYLOAD(attr) >= sizeof(uint32_t))
          memcpy(&entry.metric, RTA_DATA(attr), sizeof(uint32_t));
      }
      if (!inet_ntop(entry.family, destination, entry.destination,
                     sizeof(entry.destination))) continue;
      if (has_gateway && !inet_ntop(entry.family, gateway, entry.gateway,
                                    sizeof(entry.gateway))) continue;
      if (!extend(&entries, &count, &capacity, &entry)) {
        failed = 1;
        break;
      }
    }
  }
  disconnect(route_socket);
  if (failed) { free(entries); return failure(IO); }
#elif defined(__APPLE__)
  int query[6] = {CTL_NET, PF_ROUTE, 0, AF_UNSPEC, NET_RT_DUMP, 0};
  size_t length = 0;
  if (sysctl(query, 6, NULL, &length, NULL, 0)) return failure(IO);
  char *buffer = malloc(length ? length : 1);
  if (!buffer) return failure(MEMORY);
  if (sysctl(query, 6, buffer, &length, NULL, 0)) {
    free(buffer);
    return failure(IO);
  }
  int failed = 0;
  char *end = buffer + length;
  for (char *cursor = buffer; cursor + sizeof(struct rt_msghdr) <= end;) {
    struct rt_msghdr *message = (struct rt_msghdr *)cursor;
    if (message->rtm_msglen < sizeof(*message) ||
        cursor + message->rtm_msglen > end) { failed = 1; break; }
    char *message_end = cursor + message->rtm_msglen;
    struct sockaddr *addresses[RTAX_MAX] = {0};
    char *part = (char *)(message + 1);
    for (int index = 0; index < RTAX_MAX; index++) {
      if (!(message->rtm_addrs & (1 << index))) continue;
      if (part + 2 > message_end) { failed = 1; break; }
      struct sockaddr *address = (struct sockaddr *)part;
      size_t width = address->sa_len ? address->sa_len : sizeof(long);
      size_t aligned = (width + sizeof(long) - 1) & ~(sizeof(long) - 1);
      if (part + aligned > message_end) { failed = 1; break; }
      addresses[index] = address;
      part += aligned;
    }
    if (failed) break;
    struct sockaddr *destination = addresses[RTAX_DST];
    if (destination && (destination->sa_family == AF_INET ||
                        destination->sa_family == AF_INET6)) {
      Route entry = {0};
      entry.family = destination->sa_family;
      size_t offset = entry.family == AF_INET
          ? offsetof(struct sockaddr_in, sin_addr)
          : offsetof(struct sockaddr_in6, sin6_addr);
      size_t width = entry.family == AF_INET ? 4 : 16;
      uint8_t destination_bytes[16] = {0};
      if (destination->sa_len > offset) {
        size_t available = destination->sa_len - offset;
        if (available > width) available = width;
        memcpy(destination_bytes, (char *)destination + offset, available);
      }
      if (inet_ntop(entry.family, destination_bytes, entry.destination,
                    sizeof(entry.destination))) {
        struct sockaddr *gateway = addresses[RTAX_GATEWAY];
        if (gateway && gateway->sa_family == entry.family &&
            gateway->sa_len >= offset + width)
          inet_ntop(entry.family, (char *)gateway + offset, entry.gateway,
                    sizeof(entry.gateway));
        entry.prefix = (message->rtm_flags & RTF_HOST) ? (uint32_t)(width * 8) : 0;
        struct sockaddr *mask = addresses[RTAX_NETMASK];
        if (mask && mask->sa_len > offset) {
          size_t bytes = mask->sa_len - offset;
          if (bytes > width) bytes = width;
          const uint8_t *bits = (const uint8_t *)mask + offset;
          entry.prefix = 0;
          for (size_t index = 0; index < bytes; index++)
            for (int bit = 0; bit < 8; bit++)
              entry.prefix += (bits[index] >> bit) & 1;
        }
        entry.index = message->rtm_index;
        entry.metric = message->rtm_rmx.rmx_hopcount;
        if (!extend(&entries, &count, &capacity, &entry)) {
          failed = 1;
          break;
        }
      }
    }
    cursor = message_end;
  }
  free(buffer);
  if (failed) { free(entries); return failure(IO); }
#else
  return failure(SYSTEM);
#endif
  if (count > (SIZE_MAX - sizeof(Routes)) / sizeof(Route)) {
    free(entries);
    return failure(BOUNDS);
  }
  Routes *list = owned(sizeof(*list) + count * sizeof(Route),
                          ROUTE_LISTS);
  if (!list) { free(entries); return failure(MEMORY); }
  list->count = count;
  if (count) memcpy(list->entries, entries, count * sizeof(Route));
  free(entries);
  return (FooResult){.pointer = list};
}
static Route *route(void *pointer, uint64_t index) {
  if (!resource(pointer, ROUTE_LISTS)) return NULL;
  Routes *list = pointer;
  return index < list->count ? &list->entries[index] : NULL;
}
FooResult foo_net_tally(void *pointer) {
  return resource(pointer, ROUTE_LISTS)
      ? (FooResult){.number = ((Routes *)pointer)->count} : failure(CLOSED);
}
FooResult foo_net_target(void *pointer, uint64_t index) {
  Route *entry = route(pointer, index);
  return entry ? (FooResult){.text = {(const uint8_t *)entry->destination,
                                     strlen(entry->destination)}} : failure(BOUNDS);
}
FooResult foo_net_via(void *pointer, uint64_t index) {
  Route *entry = route(pointer, index);
  return entry ? (FooResult){.text = {(const uint8_t *)entry->gateway,
                                     strlen(entry->gateway)}} : failure(BOUNDS);
}
FooResult foo_net_protocol(void *pointer, uint64_t index) {
  Route *entry = route(pointer, index);
  if (!entry) return failure(BOUNDS);
  const char *kind = entry->family == AF_INET ? "ipv4" : "ipv6";
  return (FooResult){.text = {(const uint8_t *)kind, strlen(kind)}};
}
FooResult foo_net_mask(void *pointer, uint64_t index) {
  Route *entry = route(pointer, index);
  return entry ? (FooResult){.number = entry->prefix} : failure(BOUNDS);
}
FooResult foo_net_ordinal(void *pointer, uint64_t index) {
  Route *entry = route(pointer, index);
  return entry ? (FooResult){.number = entry->index} : failure(BOUNDS);
}
FooResult foo_net_cost(void *pointer, uint64_t index) {
  Route *entry = route(pointer, index);
  return entry ? (FooResult){.number = entry->metric} : failure(BOUNDS);
}
FooResult foo_net_dismiss(void *pointer) {
  Resource *entry = resource(pointer, ROUTE_LISTS);
  if (!entry) return failure(CLOSED);
  entry->closed = 1;
  return (FooResult){0};
}
