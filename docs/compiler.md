# Chapter 9: The Compiler (From English to Machine Code)

You have been writing beautiful, English-like sentences, but computers don't speak English. They speak machine code (1s and 0s). 

The FOO Compiler is the engine that bridges that gap. It reads your code, proves it is safe, and translates it into highly optimized instructions for your specific hardware. 

Let’s look at the three-step magic trick the compiler performs.

---

## 1. The Three-Step Pipeline

When you run `foo build`, the compiler goes through three distinct phases:

### Step 1: Parse & Check (The Proofreader)
First, the **Parser** reads your sentences and builds a grammar tree. Then, the **Type Checker** (the "Bouncer") verifies that your logic is sound. 
*   *Can you add text to a number?* No.
*   *Did you handle the error?* Yes.
If the code isn't perfect, the compiler stops you here, before it ever tries to run the program.

### Step 2: Lower to IR (The Blueprint)
Once your code is proven safe, FOO lowers it into an **Intermediate Representation (IR)**. Think of this as a strict, simplified blueprint of your program. It strips away the "English" words and converts everything into pure logic. 
This is where FOO applies **Sealing**—a mathematical process that guarantees your memory is read and written in the exact right order, eliminating entire categories of bugs.

### Step 3: Emit & Optimize (The Factory)
Finally, the compiler takes that blueprint and translates it into a language your computer can actually build: **C** or **Zig**. 
But it doesn't just translate it blindly. It applies **Optimization** (tuning) to make the code run as fast as physically possible on your specific CPU.

---

## 2. Multiple Backends: C and Zig

FOO is unique because it doesn't just target one backend. It can translate your code into two of the most powerful systems languages in the world.

### The C Backend (Universal)
Select the C11 backend with `--backend c`.
**The Benefit:** C runs on everything. If you want your FOO program to run on a massive cloud server, a Raspberry Pi, or a legacy Windows machine, the C backend is your best friend.

### The Zig Backend (Modern Speed)
FOO uses the Zig backend by default.
**The Benefit:** Zig is a modern language with incredible safety features and lightning-fast compilation times. It’s perfect for building standalone binaries that don't need any external dependencies.

```sh
# Build using the C backend
foo build --backend c

# Build using the default Zig backend
foo build
```

---

## 3. Optimization (`opt`): The Hardware Tuner

FOO’s `opt` engine is what makes it a true "systems language." It knows exactly what kind of CPU you are targeting.

*   **Intel/AMD (x86):** It will automatically use **AVX** instructions to copy memory and do math in massive, ultra-fast chunks.
*   **Apple/ARM (aarch64):** It will switch to ARM-specific instructions to save battery and boost speed.

You write the code once; FOO automatically shifts gears to match the exact hardware it's running on.

---

## 4. Caching: The Time Machine

You know how rebuilding a project can sometimes take minutes? FOO hates waiting.

FOO uses a **Build Planner** and a **Cache**. Every time you build, FOO records exactly what it did. If you haven't changed a specific file, FOO simply reuses the result from the last build.

This is why `foo watch` feels so instant. It only rebuilds the tiny parts of your code that actually changed, skipping everything else.

---

## 5. Native Interop: The Escape Hatch

Sometimes, standard code isn't enough. Maybe you need to talk directly to a graphics card, or use a specific CPU instruction.

FOO gives you an escape hatch. You can drop down into **Native C** or **Assembly** right inside your FOO file.

```foo
native c function addIntegers(a integer, b integer) giving integer {
  return a + b;
}
```

This allows you to write 99% of your app in safe, readable FOO, and the remaining 1% in raw, high-performance C.

---

## Summary: The Compiler Philosophy

The FOO Compiler is designed to be your **Safety Net** and your **Speed Demon**. 
*   It catches your mistakes before you run the code.
*   It optimizes your math for your specific CPU.
*   It gives you the choice between the universality of C and the modern speed of Zig.

In the next chapter, we will look at **Platforms**, where we will learn how to build FOO programs for Windows, Mac, Linux, and even the web!
