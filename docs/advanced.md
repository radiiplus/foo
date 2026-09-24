# Chapter 12: Advanced (Bending the Hardware to Your Will)

You have mastered the basics of FOO. You can write safe, readable, and fast applications. But what happens when you need to write a device driver, a game engine, or a piece of code that squeezes every last drop of performance out of a specific CPU?

This is where FOO’s **Advanced** features shine. FOO doesn't hide the hardware from you; it gives you a safe, structured way to talk directly to it.

---

## 1. Compile-Time Execution (`eval`)

In most languages, your code runs *after* the program is built. But in FOO, you can run code *while* the program is being built. This is called **Compile-Time Execution**.

### The Benefit: Zero Runtime Cost
Imagine you need to calculate a massive lookup table, read a configuration file, or format a huge block of text. If you do this at runtime, your app has to waste time doing it every time it starts. 

With `eval`, FOO does the math *during compilation* and bakes the result directly into the final executable. Your app starts instantly and uses zero extra memory.

```foo
eval {
  -- This math happens ONLY once, during compilation.
  -- The result (42) is hardcoded into your app.
  constant answer is 40 plus 2.
}

start() {
  -- Instantly prints 42, no math required at runtime!
  display answer.
  give nothing.
}
```

---

## 2. Custom Allocators (Memory Chefs)

In Chapter 4, we learned about **Regions** (bulk cleanup). But sometimes, you need even more control. Maybe you want a special memory pool for a game engine, or a memory buffer that lives on a specific hardware device.

FOO allows you to create custom **Allocators**.

```foo
use memory.

start() {
  -- Create a specialized arena with a specific size limit
  constant arena is try memory.arena(10 megabytes).
  after { memory.close(arena). }
  
  -- Allocate data inside your custom arena
  constant buffer is try memory.reserve(arena, 1024).
  
  give nothing.
}
```

**The Benefit:** You can dictate exactly *where* your memory lives, ensuring your high-performance app never suffers from fragmentation or slow allocation delays.

---

## 3. Native C and Assembly (The Escape Hatch)

Sometimes, FOO's high-level abstractions just aren't enough. Maybe you need to use a specific CPU instruction, or talk to a legacy C library that has no FOO bindings.

FOO gives you an **Escape Hatch**. You can drop down into raw C or Assembly right inside your FOO file.

### Native C
```foo
native c function add_ints(a of type integer, b of type integer) of type integer {
  return a + b;
}
```

### Inline Assembly
```foo
asm {
  // Raw assembly instructions go here.
  // This is for the truly brave!
}
```

**The Benefit:** You can write 99% of your app in safe, readable FOO, and the remaining 1% in raw, high-performance C or Assembly, all in the same file.

---

## 4. Hardware Tuning (`opt`)

You know FOO automatically optimizes your code for your CPU. But what if you want to build an app for a *very specific* piece of silicon, like an Apple M1 chip or a specific Intel server?

You can use the `-mcpu` flag to tell FOO's `opt` engine exactly what hardware to target.

```sh
-- Build for Apple Silicon
foo build -mcpu apple_m1

-- Build for a modern Intel/AMD chip with AVX2
foo build -mcpu x86-64-v3
```

**The Benefit:** FOO will automatically generate vector instructions, tune memory alignment, and optimize math operations to match the exact physical wiring of your target CPU.

---

## Summary: The Advanced Philosophy

FOO believes that you should never be trapped by your language. 
*   Need speed? Use `eval` to bake math into the binary.
*   Need memory control? Use custom allocators.
*   Need raw power? Use `native c` or `asm`.
*   Need hardware tuning? Use `-mcpu`.

FOO gives you the safety of a high-level language, with the raw power of a low-level systems language. You are never forced to choose.