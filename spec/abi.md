# Application Binary Interface (MVL-1)

## Calling Conventions
1. **tratio** (Default): 
   - Arguments 1-6 passed in registers (RDI, RSI, RDX, RCX, R8, R9 on x86_64; X0-X5 on AArch64).
   - Arguments 7+ passed on the stack.
   - Return value in RAX/XMM0 (x86_64) or X0/Q0 (AArch64).
   - Stack pointer is 16-byte aligned at call boundaries.
2. **c** (FFI): Strict adherence to the target platform's C ABI (System V AMD64, Windows x64, AAPCS, etc.).

## Layout Rules
- **Default**: Compiler may reorder struct fields for optimal packing and alignment.
- **`#[repr(c)]`**: Forces C-compatible layout. Fields are laid out in declaration order. Alignment matches the target C ABI. No padding is added between fields unless required by C alignment rules.

## Name Mangling
To ensure linker compatibility and backend swappability, all non-FFI, non-exported symbols are mangled deterministically:
`_T1_<module_length>_<module_name>_<symbol_length>_<symbol_name>`

Example: `mod net { pub fn connect() }` in `app` becomes `_T1_3_app_7_connect`.
Exported functions (`export fn`) and `extern "c"` functions are **unmangled**.