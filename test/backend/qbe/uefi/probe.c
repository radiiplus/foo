static void efi_output(unsigned char value) {
    __asm__ volatile("outb %0, $0xe9" : : "a"(value));
}

static void (*volatile efi_dispatch)(unsigned char) = efi_output;

void efi_debug(void *image, void *system, unsigned char value) {
    efi_dispatch(image && system ? value : '!');
}
