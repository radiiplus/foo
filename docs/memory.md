 # Chapter 4: Data and Memory (Safe, Fast, and Automatic)

In many high-performance languages, managing memory (RAM) is a manual, error-prone nightmare. You have to remember to free every single byte you allocate, or your app will crash. 

FOO takes a completely different approach. It gives you the speed of manual memory management with the safety of automatic garbage collection, using two superpowers: **Regions** and **Sealing**.

Let’s look at how FOO stores your data.

---

## 1. Structuring Data: Records

A **Record** is FOO’s version of a `struct` or `class`. It groups related data together. 

FOO gives you three layout options depending on your needs:

### The Default `record` (Optimized for Speed)
By default, FOO aligns your data to match your CPU's natural preferences (using the `opt` engine we discussed earlier). This makes reading and writing fields lightning-fast.
```foo
public record User {
  id of type unsigned 64.
  name of type text.
  active of type boolean.
}
```

### The `packed` Record (Optimized for Space)
If you are talking to hardware or sending data over a network, you need every bit to be exactly where you expect it. A `packed` record strips out all the empty alignment space.
```foo
public packed record NetworkHeader {
  version of type integer 4.
  flags of type integer 4.
  length of type integer 16.
}
```

### The `c` Record (Optimized for Interoperability)
If you need to talk to a C library, FOO can match the C memory layout perfectly so you can pass data back and forth seamlessly.
```foo
public c record Point {
  x of type integer.
  y of type integer.
}
```

---

## 2. The Magic of Regions (Bulk Cleanup)

In languages like C or C++, if you allocate 100 objects, you have to manually free 100 objects. If you miss one, you have a **Memory Leak**.

FOO encourages **Region-Based Memory Management** (also known as Arenas). Think of a Region as a dedicated workbench. You build everything on that bench, and when you are done, you just sweep the entire bench clean in one motion.

```foo
function process_request() of type fallible nothing {
  -- 1. Create a temporary workspace (Region)
  constant arena is try memory.create().
  
  -- 2. Guarantee cleanup! This runs even if the function fails.
  after { memory.close(arena). }
  
  -- 3. Allocate data INSIDE the arena
  constant buffer is try memory.reserve(arena, 1024).
  constant image is try load_image(arena, "photo.png").
  
  -- Do work...
  
  give nothing.
  -- When we reach the end, 'memory.close(arena)' frees EVERYTHING at once!
}
```

**Why this is awesome:** 
1. **Speed:** Freeing one giant Region is thousands of times faster than freeing 1,000 individual objects.
2. **Safety:** It is mathematically impossible to leak memory because the Region cleanup is guaranteed by the `after` block.

---

## 3. Sealing: The Invisible Safety Net

You might be wondering: *"What if I try to use the buffer after I close the arena?"*

This is where FOO’s **Sealing** superpower kicks in. As the compiler builds your program, it creates a mathematical dependency map of your memory. It tracks exactly when memory is created, used, and destroyed.

If you try to access data after it has been sealed (closed), FOO will stop the build with a clear error:
```text
main.iv:15:10
  display buffer.
          ^^^^^^
  Cannot use 'buffer' after its owning region has been closed.
```

This means FOO prevents **Use-After-Free** bugs (one of the most dangerous security vulnerabilities in software) *before your code even runs*.

---

## 4. Smart Optimization (`opt`)

Because FOO knows exactly how your data is laid out (thanks to `record` and `packed`), its `opt` (optimization) engine can do incredible things for your specific hardware.

*   **Vectorization:** If you have an array of numbers, FOO will automatically align them so your CPU can process 4, 8, or 16 numbers at the same time using AVX or NEON instructions.
*   **Cache Friendliness:** FOO arranges your records so that the data you use most often sits close together in memory, making your CPU's cache work much more efficiently.

---

## Summary: The FOO Memory Philosophy

FOO believes that you shouldn't have to choose between safety and performance. 
By using **Regions** for bulk cleanup and **Sealing** for compile-time safety, FOO allows you to write high-performance systems code without ever worrying about memory leaks or segmentation faults.

In the next chapter, we will look at **Systems**, where we will learn how to talk to files, processes, and the operating system itself!
