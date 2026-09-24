# Chapter 2: Getting Started (Your First FOO Project)

Welcome to your first day writing FOO! Today, we are going to set up your computer, create a brand new project, and write some actual code. 

In many ecosystems, getting started means fighting with package managers, version conflicts, and messy environment setups. FOO completely eliminates that headache. It is distributed as a standalone, native application. You just install it, and it works.

Let’s get building!

---

## 1. The Magic Setup

First, head over to the official FOO Releases page and download the installer for your operating system (Windows, macOS, or Linux). Run the installer, and within seconds, the `foo` command will be available in your terminal.

Once it's installed, open your terminal (Command Prompt/PowerShell on Windows, or Terminal on Mac/Linux) and type this magic command:

```sh
foo doctor
```

**Why this is awesome:** `foo doctor` runs a complete health check on your computer. FOO uses powerful backend tools (like Zig and C) to compile your code into hyper-fast machine instructions. If `foo doctor` realizes you don't have these tools installed, **it will automatically download and configure them for you in the background**. You never have to manually install a C compiler or worry about missing dependencies!

---

## 2. Creating Your First Project

Let’s create a dedicated folder for our new app. FOO has a built-in **Scaffolding** tool (a command that instantly generates a clean, perfectly organized folder structure for you).

```sh
foo new my_first_app
cd my_first_app
```

If you look inside the `my_first_app` folder, you’ll see a `project.json` file (the ID card for your project) and a `main.iv` file. The `.iv` extension stands for FOO source code!

---

## 3. Writing Your First Sentences

Open `main.iv` in your favorite code editor. Let’s write a program that greets the user. 

Because FOO’s **Parser** (the brilliant part of the compiler that reads your code) is designed to understand natural, flowing sentences, you don't need to clutter your screen with messy semicolons or excessive parentheses. 

Type this out:

```foo
use io.

function greet(name of type text) of type nothing {
  display "Hello, " plus name plus "!".
  give nothing.
}

start() {
  constant my_name is "vibes".
  greet(my_name).
  give nothing.
}
```

### Let’s break down the brilliance here:
*   **`use io.`**: This tells FOO to import the Input/Output library, giving you access to the screen and keyboard.
*   **`of type text`**: FOO is strictly **Typed** (meaning it keeps strict track of what kind of data is stored in a variable, preventing math errors on text). But as you'll learn later, FOO is so smart it can often guess the type for you!
*   **`plus`**: Instead of forcing you to use the `+` symbol for everything, FOO lets you use the English word `plus` to glue text together.
*   **`give nothing.`**: This is FOO's way of saying "this function is finished and has no data to hand back."
*   **The Period (`.`)**: Notice how every action ends with a period? FOO reads your code like a book. A period tells the parser, *"This specific thought is complete."*

---

## 4. Running Your App

Now for the best part. In your terminal, simply type:

```sh
foo run
```

**What happens underneath:** 
When you hit Enter, FOO doesn't just slowly interpret your code line-by-line. FOO’s **Multiple Build Backends** kick into gear. It translates your beautiful English sentences into hyper-fast Native C or Zig code. It looks at your specific CPU and applies **Optimization** (tweaking the math to run as fast as physically possible on your exact hardware), compiles it into a standalone executable, and runs it instantly.

You should see:
```text
Hello, vibes!
```

---

## 5. Growing Your App: Adding a Second File

As your app grows, you’ll want to split your code into multiple files to keep things organized. FOO handles this beautifully using **Namespaces** (invisible walls that keep the code in one file from accidentally messing up the code in another file).

Create a new file named `math.iv` and add this:

```foo
public function add(left of type integer, right of type integer) of type integer {
  give left plus right.
}
```
*Notice the word `public`? This is the only way to let other files see this function. If you leave `public` off, the function becomes private and completely invisible to the rest of your app. This prevents messy "spaghetti code" (where everything is tangled together and hard to track).*

Now, go back to `main.iv` and use it:

```foo
use io.
use "math". -- This brings in our new file!

start() {
  constant total is add(10, 20).
  display total.
  give nothing.
}
```

---

## 6. The World's Most Helpful Error Messages

Everyone makes typos. When you make a mistake in FOO, the compiler doesn't just crash and give you a confusing wall of red text. It acts like a helpful teacher.

Try changing your code to this mistake:
```foo
constant age is "twenty". -- Oops! We used text instead of a number.
```

Run `foo check`. FOO will point exactly to the mistake and tell you how to fix it:

```text
main.iv:2:18

  constant age is "twenty".
                  ^^^^^^^
  This value is text, but age needs an integer.
  Try: constant age is 20.
```
Fix the first error it points out, save the file, and run it again!

---

## 7. Your Daily Cheat Sheet

Here are the commands you will use every single day as a FOO programmer:

*   **`foo check`**: The Safety Inspector. It reads all your code and mathematically proves it is safe, but doesn't actually run it. Perfect for catching typos quickly.
*   **`foo build`**: The Factory. It compiles your code into a final, standalone, highly-optimized application file that you can share with others.
*   **`foo run`**: The Quick Test. Builds the app and immediately runs it so you can see the results.
*   **`foo watch`**: The Tireless Assistant. It sits in the background, and every single time you hit "Save" in your code editor, it automatically re-checks and re-builds your app instantly.
*   **`foo fmt`**: The Beautifier. It automatically reformats your code to ensure perfect spacing and indentation, so your code always looks professional.

---

You are now officially a FOO programmer! In the next chapter, we will dive deeper into the **Language** itself, exploring how FOO handles decisions, loops, and data.