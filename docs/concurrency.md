# Chapter 6: Concurrency (Doing Multiple Things at Once)

Modern applications are multitaskers. They download files, update the user interface, and listen for clicks—all at the same time. In many languages, writing code that does multiple things at once is dangerous and leads to messy bugs.

FOO makes concurrency safe, fast, and surprisingly easy.

---

## 1. Concurrency vs. Parallelism (The Simple Difference)

Before we write code, let's understand the goal:
*   **Concurrency** is like a chef in a kitchen managing multiple pots. They stir the soup, check the oven, and chop vegetables, switching between tasks quickly.
*   **Parallelism** is like having *two chefs* in the kitchen, both cooking at the exact same moment.

FOO gives you tools for both.

---

## 2. Tasks: The Lightweight Way (Async)

For most things—like reading files, waiting for user input, or downloading data—you should use **Tasks**. 

Tasks are incredibly lightweight. You can spawn thousands of them without slowing down your computer. FOO's **Task Backend** (which we saw in the source code) automatically detects your operating system and uses the most efficient method available (`epoll` on Linux, `kqueue` on Mac, `iocp` on Windows).

```foo
use task.

start() {
  -- Spawn a task that runs in the background
  task spawn {
    display "Downloading file...".
    -- Simulate waiting for a network
    time sleep 2 seconds.
    display "Download complete!".
  }.
  
  -- The main program continues immediately!
  display "I am not waiting for the download.".
  
  give nothing.
}
```

**Why this is awesome:** You don't have to manage complex threads or timers. You just tell FOO what to do, and it handles the scheduling efficiently.

---

## 3. Threads: The Heavyweight Way (Parallelism)

If you need to do heavy mathematical calculations or process video, you need true **Parallelism**. This is where **Threads** come in. Threads use your computer's multiple CPU cores to do actual work simultaneously.

```foo
use thread.

start() {
  -- Spawn a thread to do heavy math
  thread spawn {
    mutable total is 0.
    mutable i is 0.
    
    -- A standard FOO while loop
    while i less than 1000000 {
      set total to total plus i.
      set i to i plus 1.
    }.
    
    display "Math finished!".
  }.
  
  display "Main thread is still running.".
  
  give nothing.
}
```

---

## 4. Channels: Talking Safely

The hardest part of concurrency is sharing data. If two threads try to change the same variable at the same time, they can overwrite each other's work (a **Data Race**).

FOO solves this with **Channels**. Instead of sharing memory directly, you send messages between tasks.

```foo
use sync.
use thread.

start() {
  -- Create a channel to send text messages
  constant channel is sync.channel_text().
  
  thread spawn {
    -- Send a message into the channel
    sync.send(channel, "Hello from the worker thread!").
  }.
  
  -- Receive the message (this waits until a message arrives)
  constant msg is sync.receive(channel).
  display msg.
  
  give nothing.
}
```

**The Benefit:** This eliminates data races entirely. Only one task owns the data at a time, passing it along like a baton in a relay race.

---

## 5. Atomics: The Speed Demon

Sometimes you just need a simple counter that multiple threads can update safely, and you don't want the overhead of a full channel. FOO provides **Atomics** (operations that are guaranteed to complete without interruption).

Here is how to safely increment a counter from multiple threads using a standard FOO `while` loop:

```foo
use atomic.
use thread.

start() {
  mutable counter of type integer is 0.
  mutable thread_count is 0.
  
  -- Spawn 10 threads using a while loop
  while thread_count less than 10 {
    thread spawn {
      -- Safely add 1 to the counter from this thread
      atomic.add(counter, 1).
    }.
    set thread_count to thread_count plus 1.
  }.
  
  -- Wait a moment for threads to finish
  time sleep 100 milliseconds.
  
  display "Final count: " plus counter.
  give nothing.
}
```

---

## Summary: The FOO Concurrency Philosophy

FOO gives you a spectrum of tools:
1.  **Tasks** for waiting (I/O, UI, Network).
2.  **Threads** for heavy lifting (Math, Physics, Video).
3.  **Channels** for safe communication.
4.  **Atomics** for ultra-fast shared counters.

By choosing the right tool for the job, you can write programs that are fast, responsive, and crash-proof.

In the next chapter, we will look at **Packages**, where we will learn how to share our FOO code with the world!