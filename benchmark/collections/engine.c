/* Evaluation-only scalar-key models, never linked into production runtime.
 * Build as C11 and as C++20 to expose compiler/control differences.
 * Deliberately keep ordered map/set output separate from hash traversal.
 */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(_WIN32)
#include <windows.h>
#else
#include <time.h>
#endif
#if defined(__SSE2__) || defined(_M_X64)
#include <emmintrin.h>
#define SIMD 1
#else
#define SIMD 0
#endif

typedef struct { uint64_t allocations, bytes, live, peak, copied; } Metrics;
static Metrics m;
static volatile uint64_t sink;
static void *alloc(size_t bytes) {
  size_t *p = (size_t *)calloc(1, bytes + sizeof(size_t));
  if (!p) { fputs("allocation failed\n", stderr); exit(3); }
  *p = bytes; m.allocations++; m.bytes += bytes; m.live += bytes;
  if (m.live > m.peak) m.peak = m.live;
  return p + 1;
}
static void drop(void *p) {
  if (!p) return;
  size_t *base = (size_t *)p - 1;
  assert(m.live >= *base); m.live -= *base; free(base);
}
static void copy(void *to, const void *from, size_t bytes) {
  if (bytes) memcpy(to, from, bytes);
  m.copied += bytes;
}
static uint64_t now(void) {
#ifdef _WIN32
  LARGE_INTEGER t, f; QueryPerformanceCounter(&t); QueryPerformanceFrequency(&f);
  return (uint64_t)((double)t.QuadPart * 1e9 / (double)f.QuadPart);
#else
  struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * UINT64_C(1000000000) + t.tv_nsec;
#endif
}
static uint64_t mix(uint64_t x) {
  x ^= x >> 30; x *= UINT64_C(0xbf58476d1ce4e5b9);
  x ^= x >> 27; x *= UINT64_C(0x94d049bb133111eb);
  return x ^ (x >> 31);
}
static void reset(void) { m.allocations = m.bytes = m.copied = 0; m.peak = m.live; }

/* Baseline uses the runtime's cached FNV hash / 75% linear probing shape.
 * Keys contain an empty key, embedded zero bytes and length-distinct prefixes.
 * Swiss candidate keeps the same separately owned key and value payloads.
 * The seeded hash is experimental FNV+avalanche, not a security guarantee.
 */
typedef struct { uint64_t hash; unsigned char state; unsigned char *key;
  size_t len; uint64_t *value; } Entry;
typedef struct { Entry *entries; unsigned char *ctrl; size_t cap, count;
  int candidate, adversarial; } Table;
static void encode(uint64_t key, unsigned char bytes[16], size_t *len) {
  memset(bytes, 0, 16); memcpy(bytes, &key, 8);
  *len = key == 0 ? 0 : (key % 11 == 0 ? 16 : 8);
}
static uint64_t digest(Table *t, const unsigned char *p, size_t n) {
  uint64_t h = UINT64_C(14695981039346656037);
  for (size_t i = 0; i < n; i++) h = (h ^ p[i]) * UINT64_C(1099511628211);
  if (t->candidate) h = mix(h ^ UINT64_C(0xd1b54a32d192ed03));
  if (t->adversarial) h &= ~UINT64_C(255); /* common low eight bits, both sides */
  return h ? h : 1;
}
static unsigned mask(const unsigned char *p, unsigned char tag) {
#if SIMD
  return (unsigned)_mm_movemask_epi8(_mm_cmpeq_epi8(
    _mm_loadu_si128((const __m128i *)(const void *)p), _mm_set1_epi8((char)tag)));
#else
  unsigned mask = 0;
  for (unsigned i = 0; i < 16; i++) if (p[i] == tag) mask |= 1u << i;
  return mask;
#endif
}
static size_t slot(Table *t, uint64_t h, const unsigned char *p, size_t n, int put) {
  size_t first = SIZE_MAX, start = (size_t)h & (t->cap - 1);
  if (!t->candidate) {
    for (size_t step = 0; step < t->cap; step++) {
      size_t i = (start + step) & (t->cap - 1); Entry *e = t->entries + i;
      if (!e->state) return put && first != SIZE_MAX ? first : i;
      if (e->state == 1 && e->hash == h && e->len == n && (!n || !memcmp(e->key,p,n))) return i;
      if (put && e->state == 2 && first == SIZE_MAX) first = i;
    }
  } else {
    start &= ~(size_t)15;
    unsigned char tag = (unsigned char)(h >> 57);
    for (size_t step = 0; step < t->cap; step += 16) {
      size_t group = (start + step) & (t->cap - 1);
      unsigned match = mask(t->ctrl + group, tag);
      for (unsigned j = 0; j < 16; j++) if (match & (1u << j)) {
        size_t i = group + j; Entry *e = t->entries + i;
        if (e->hash == h && e->len == n && (!n || !memcmp(e->key,p,n))) return i;
      }
      unsigned empty = mask(t->ctrl + group, 128);
      unsigned removed = put ? mask(t->ctrl + group, 254) : 0;
      for (unsigned j = 0; j < 16; j++) {
        if ((removed & (1u << j)) && first == SIZE_MAX) first = group + j;
        if (empty & (1u << j)) return put && first != SIZE_MAX ? first : group + j;
      }
    }
  }
  /* A fully tombstoned table must terminate; production baseline needs its
   * own independent churn investigation, not a fix hidden in this redesign. */
  if (put && first != SIZE_MAX) return first;
  return SIZE_MAX;
}
static void grow(Table *t) {
  Table old = *t; t->cap = old.cap ? old.cap * 2 : 16;
  t->entries = (Entry *)alloc(t->cap * sizeof(Entry));
  t->ctrl = t->candidate ? (unsigned char *)alloc(t->cap) : NULL;
  if (t->ctrl) memset(t->ctrl,128,t->cap);
  for (size_t j = 0; j < old.cap; j++) if (old.entries[j].state == 1) {
    Entry e = old.entries[j]; size_t i = slot(t,e.hash,e.key,e.len,1);
    t->entries[i] = e; if (t->ctrl) t->ctrl[i] = (unsigned char)(e.hash >> 57);
  }
  drop(old.entries); drop(old.ctrl);
}
static void put(Table *t, uint64_t k, uint64_t value) {
  if (!t->cap || (t->count + 1) * 4 >= t->cap * 3) grow(t);
  unsigned char bytes[16]; size_t n; encode(k,bytes,&n);
  uint64_t h = digest(t,bytes,n); size_t i = slot(t,h,bytes,n,1);
  assert(i != SIZE_MAX); Entry *e = t->entries + i;
  uint64_t *payload = (uint64_t *)alloc(8); *payload = value;
  if (e->state == 1) { drop(e->value); e->value = payload; return; }
  e->key = (unsigned char *)alloc(n ? n : 1); copy(e->key,bytes,n);
  e->value = payload; e->len = n; e->hash = h; e->state = 1; t->count++;
  if (t->ctrl) t->ctrl[i] = (unsigned char)(h >> 57);
}
static int get(Table *t, uint64_t k, uint64_t *value) {
  unsigned char bytes[16]; size_t n; encode(k,bytes,&n);
  size_t i = slot(t,digest(t,bytes,n),bytes,n,0);
  if (i == SIZE_MAX || t->entries[i].state != 1) return 0;
  *value = *t->entries[i].value; return 1;
}
static void erase(Table *t, uint64_t k) {
  unsigned char bytes[16]; size_t n; encode(k,bytes,&n);
  size_t i = slot(t,digest(t,bytes,n),bytes,n,0);
  assert(i != SIZE_MAX && t->entries[i].state == 1);
  drop(t->entries[i].key); drop(t->entries[i].value);
  t->entries[i].state = 2; t->count--; if(t->ctrl) t->ctrl[i] = 254;
}
static void close(Table *t) {
  for (size_t i = 0; i < t->cap; i++) if (t->entries[i].state == 1) {
    drop(t->entries[i].key); drop(t->entries[i].value);
  }
  drop(t->entries); drop(t->ctrl);
}

/* Persistent 32-way trie, shared by vector and scalar-key HAMT experiments.
 * Fixed child arrays deliberately expose allocation/memory costs; this is
 * HAMT-style path sharing, not a compact CHAMP implementation.
 */
typedef struct Node { size_t refs; int leaf; struct Node *child[32]; uint64_t data[32]; } Node;
static Node *node(int leaf) { Node *n=(Node *)alloc(sizeof(Node)); n->refs=1; n->leaf=leaf; return n; }
static void retain(Node *n) { if(n) n->refs++; }
static void release(Node *n) {
  if(!n || --n->refs) return;
  if(!n->leaf) for(size_t i=0;i<32;i++) release(n->child[i]);
  drop(n);
}
static Node *updated(Node *old, uint64_t index, unsigned depth, uint64_t value) {
  Node *n=node(depth==0);
  if(old) { copy(n->data,old->data,sizeof(n->data));
    if(depth) for(size_t i=0;i<32;i++) { n->child[i]=old->child[i]; retain(n->child[i]); } }
  unsigned slot=(unsigned)((index >> (depth*5)) & 31);
  if(depth) { Node *next=updated(n->child[slot],index,depth-1,value);
    release(n->child[slot]); n->child[slot]=next; }
  else n->data[slot]=value;
  return n;
}
static uint64_t read(Node *n,uint64_t index,unsigned depth) {
  for(;;) { if(!n) return 0; unsigned slot=(unsigned)((index >> (depth*5))&31);
    if(!depth) return n->data[slot]; n=n->child[slot]; depth--; }
}
static unsigned levels(size_t n) { unsigned d=0; while(n>32) { n=(n+31)/32; d++; } return d; }
static Node *build(size_t n,unsigned depth,int hashed) {
  Node *root=NULL;
  for(size_t i=0;i<n;i++) { uint64_t k=hashed ? (uint32_t)(i*UINT32_C(2654435761)) : i;
    Node *next=updated(root,k,depth,i+1); release(root); root=next; }
  return root;
}

/* Baseline old-version append copies its prefix into geometric storage. */
static uint64_t sequence(int candidate,const char *shape,size_t n,size_t reps,uint64_t *duration) {
  unsigned depth=levels(n+1); Node *root=NULL;
  uint64_t *data=NULL; size_t cap=8; while(cap<n+1) cap*=2;
  if(candidate) root=build(n,depth,0);
  else { data=(uint64_t *)alloc(cap*8); for(size_t i=0;i<n;i++) data[i]=i+1; }
  reset(); uint64_t start=now(), sum=0;
  if(!strcmp(shape,"lookup") || !strcmp(shape,"iteration")) {
    for(size_t r=0;r<reps;r++) for(size_t i=0;i<n;i++) {
      size_t at=!strcmp(shape,"lookup") ? (i*8191)%n : i;
      sum+=candidate ? read(root,at,depth) : data[at];
    }
  } else if(!strcmp(shape,"newest")) {
    /* Independent builds retain the original root; geometric tail is newest. */
    for(size_t r=0;r<reps;r++) {
      if(candidate) { Node *next=NULL;
        for(size_t i=0;i<n;i++) { Node *p=updated(next,i,depth,i+1); release(next); next=p; }
        sum+=read(next,n-1,depth); release(next);
      } else { uint64_t *next=NULL; size_t capacity=0;
        for(size_t i=0;i<n;i++) { if(i==capacity) {
          size_t newcap=capacity ? capacity*2 : 8; uint64_t *p=(uint64_t *)alloc(newcap*8);
          copy(p,next,i*8); drop(next); next=p; capacity=newcap; }
          next[i]=i+1;
        } sum+=next[n-1]; drop(next);
      }
    }
  } else {
    for(size_t r=0;r<reps;r++) {
      if(candidate) { Node *next=updated(root,n,depth,r+1);
        assert(read(next,n-1,depth)==n); sum+=read(next,n,depth); release(next);
      } else { uint64_t *next=(uint64_t *)alloc(cap*8); copy(next,data,n*8);
        next[n]=r+1; assert(next[n-1]==n); sum+=next[n]; drop(next); }
    }
  }
  sink=sum; *duration=now()-start;
  if(candidate) { assert(read(root,n-1,depth)==n); release(root); }
  else { assert(data[n-1]==n); drop(data); }
  return sum;
}

static int contains(const uint64_t *values,size_t n,uint64_t key) {
  for(size_t i=0;i<n;i++) if(values[i]==key) return 1;
  return 0;
}
static uint64_t associate(int candidate,int set,const char *shape,size_t n,size_t reps,uint64_t *duration) {
  /* Bijective scalar hash for keys within 2^32; invalid for generic keys.
   * Order is separately materialized, never taken from trie traversal. */
  Node *root=candidate ? build(n,6,1) : NULL;
  Node *right=NULL;
  if(candidate && set) for(size_t i=n/2;i<n+n/2;i++) {
    Node *next=updated(right,(uint32_t)(i*UINT32_C(2654435761)),6,i+1);
    release(right); right=next;
  }
  uint64_t *keys=(uint64_t *)alloc(n*8),*values=(uint64_t *)alloc(n*8);
  for(size_t i=0;i<n;i++) { keys[i]=i; values[i]=i+1; }
  uint64_t *members=set ? (uint64_t *)alloc(n*8) : NULL;
  if(set) for(size_t i=0;i<n;i++) members[i]=i+n/2;
  reset(); uint64_t start=now(),sum=0;
  for(size_t r=0;r<reps;r++) {
    if(!strcmp(shape,"lookup")) {
      for(size_t i=0;i<n;i++) {
        if(candidate) sum+=read(root,(uint32_t)(i*UINT32_C(2654435761)),6);
        else { for(size_t j=0;j<n;j++) if(keys[j]==i) { sum+=values[j]; break; } }
      }
    } else if(set) {
      uint64_t *output=(uint64_t *)alloc(n*2*8); size_t count=0;
      /* Right starts halfway into left; deterministic left/right member order. */
      int intersect=!strcmp(shape,"intersection"),difference=!strcmp(shape,"difference");
      for(size_t i=0;i<n;i++) {
        int match=candidate ? read(right,(uint32_t)(i*UINT32_C(2654435761)),6)!=0 : contains(members,n,i);
        if((intersect && match)||(difference && !match)||(!intersect && !difference)) output[count++]=i;
      }
      if(!intersect && !difference) for(size_t i=n/2;i<n+n/2;i++) {
        int has=candidate ? read(root,(uint32_t)(i*UINT32_C(2654435761)),6)!=0 : contains(keys,n,i);
        if(!has) output[count++]=i;
      }
      /* No hash-order output; check every member and its position. */
      for(size_t i=0;i<count;i++) { uint64_t expect=intersect ? i+n/2 : i;
        assert(output[i]==expect); sum+=output[i]+1; }
      drop(output);
    } else {
      size_t at=r%n;
      if(candidate) { uint64_t hash=(uint32_t)(at*UINT32_C(2654435761));
        Node *next=updated(root,hash,6,n+r+1);
        sum+=read(next,hash,6); assert(read(root,hash,6)==at+1); release(next);
      } else { uint64_t *next=(uint64_t *)alloc(n*8); copy(next,values,n*8);
        next[at]=n+r+1; sum+=next[at]; assert(values[at]==at+1); drop(next); }
    }
  }
  sink=sum; *duration=now()-start; release(root); release(right); drop(keys); drop(values); drop(members); return sum;
}

/* Roaring-style 16-bit array/bitmap containers, conversion at 4096 members.
 * This is a deliberately bounded 2^20-bit model, not a new bitmap API. */
typedef struct { uint16_t *array; uint64_t *bits; size_t count; } Container;
static uint64_t bitmap(int candidate,const char *shape,size_t n,size_t reps,uint64_t *duration) {
  const size_t universe=1u<<20, words=universe/64;
  int dense=!strcmp(shape,"dense"); size_t count=dense ? universe/2 : n;
  Container containers[16]; memset(containers,0,sizeof(containers));
  uint64_t *bits=NULL;
  if(candidate) {
    for(size_t i=0;i<count;i++) { size_t at=dense ? i*2 : (i*65537)%universe; containers[at>>16].count++; }
    for(size_t c=0;c<16;c++) { Container *p=containers+c;
      if(p->count>4096) p->bits=(uint64_t *)alloc(1024*8);
      else if(p->count) p->array=(uint16_t *)alloc(p->count*2);
      p->count=0;
    }
    /* Traverse in numeric order; sorted arrays are part of the model contract. */
    for(size_t at=0;at<universe;at++) {
      int present=dense ? at%2==0 : (((at*65537)%universe)<count);
      if(present) { Container *p=containers+(at>>16); uint16_t lo=(uint16_t)at;
        if(p->bits) p->bits[lo/64]|=UINT64_C(1)<<(lo%64); else p->array[p->count]=lo;
        p->count++;
      }
    }
  } else {
    bits=(uint64_t *)alloc(words*8);
    for(size_t i=0;i<count;i++) { size_t at=dense ? i*2 : (i*65537)%universe;
      bits[at/64]|=UINT64_C(1)<<(at%64); }
  }
  reset(); uint64_t start=now(),sum=0;
  for(size_t r=0;r<reps;r++) {
    /* Persistent copy + cardinality. Full clone exposes dense/sparse tradeoff;
     * structural sharing single-container update is a separate future experiment. */
    if(candidate) {
      for(size_t c=0;c<16;c++) { Container *p=containers+c;
        size_t bytes=p->bits ? 8192 : p->count*2;
        if(!bytes) continue;
        void *clone=alloc(bytes); copy(clone,p->bits ? (const void *)p->bits : (const void *)p->array,bytes);
        if(p->bits) for(size_t i=0;i<1024;i++) sum+=(uint64_t)__builtin_popcountll(((uint64_t *)clone)[i]);
        else sum+=p->count;
        drop(clone);
      }
    } else {
      uint64_t *clone=(uint64_t *)alloc(words*8); copy(clone,bits,words*8);
      for(size_t i=0;i<words;i++) sum+=(uint64_t)__builtin_popcountll(clone[i]); drop(clone);
    }
  }
  assert(sum==count*reps); sink=sum; *duration=now()-start;
  for(size_t c=0;c<16;c++) { drop(containers[c].array); drop(containers[c].bits); }
  drop(bits); return sum;
}

static uint64_t table(int candidate,const char *shape,size_t n,size_t reps,uint64_t *duration) {
  Table t; memset(&t,0,sizeof(t)); t.candidate=candidate; t.adversarial=!strcmp(shape,"adversarial");
  for(size_t i=0;i<n;i++) put(&t,i,i+1);
  /* Full verification before measurement, including empty and binary keys. */
  for(size_t i=0;i<n;i++) { uint64_t v=0; assert(get(&t,i,&v)&&v==i+1); }
  reset(); uint64_t start=now(),sum=0;
  for(size_t r=0;r<reps;r++) for(size_t i=0;i<n;i++) {
    uint64_t value=0;
    if(!strcmp(shape,"churn")) { erase(&t,i); put(&t,i,i+1); }
    assert(get(&t,i,&value)); sum+=value;
  }
  sink=sum; *duration=now()-start; close(&t); return sum;
}

int collections_run(const char *family,const char *shape,size_t n,size_t reps,int candidate) {
  if(n<1 || n>16384 || reps<1 || reps>100000 || candidate<0 || candidate>1) return 2;
  assert(m.live==0); memset(&m,0,sizeof(m)); uint64_t duration=0,sum=0;
  if(!strcmp(family,"table")) sum=table(candidate,shape,n,reps,&duration);
  else if(!strcmp(family,"sequence")) sum=sequence(candidate,shape,n,reps,&duration);
  else if(!strcmp(family,"map")) sum=associate(candidate,0,shape,n,reps,&duration);
  else if(!strcmp(family,"set")) sum=associate(candidate,1,shape,n,reps,&duration);
  else if(!strcmp(family,"bitmap")) sum=bitmap(candidate,shape,n,reps,&duration);
  else return 2;
  assert(m.live==0);
  printf("{\"ns\":%llu,\"checksum\":%llu,\"allocations\":%llu,\"allocatedBytes\":%llu,\"peakBytes\":%llu,\"copiedBytes\":%llu,\"liveBytes\":%llu,\"simd\":%d}\n",
    (unsigned long long)duration,(unsigned long long)sum,(unsigned long long)m.allocations,
    (unsigned long long)m.bytes,(unsigned long long)m.peak,(unsigned long long)m.copied,
    (unsigned long long)m.live,SIMD);
  return 0;
}
/* Integer-only foreign ABI used by retained FOO fixtures. */
int collections_fixture(uint32_t family,uint32_t shape,uint32_t size,uint32_t reps,uint32_t candidate) {
  static const char *families[]={"table","sequence","map","set","bitmap"};
  static const char *shapes[]={"lookup","branch","newest","iteration","churn","adversarial","update","union","intersection","difference","sparse","dense"};
  if(family>=5 || shape>=12) return 2;
  return collections_run(families[family],shapes[shape],size,reps,candidate);
}
#ifndef COLLECTIONS_LIBRARY
int main(int argc,char **argv) {
  if(argc!=6) { fputs("usage: engine FAMILY SHAPE SIZE REPS old|new\n",stderr); return 2; }
  if(strcmp(argv[5],"old") && strcmp(argv[5],"new")) return 2;
  return collections_run(argv[1],argv[2],(size_t)strtoull(argv[3],NULL,10),
    (size_t)strtoull(argv[4],NULL,10),!strcmp(argv[5],"new"));
}
#endif
