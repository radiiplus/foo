#include <windows.h>
#include <stdio.h>

typedef int (*Answer)(void);
typedef int (*Add)(int);

int main(int argc, char **argv) {
    if (argc != 2) return 1;
    HMODULE library = LoadLibraryA(argv[1]);
    if (!library) return 2;
    Answer answer = (Answer)GetProcAddress(library, "answer");
    Add add = (Add)GetProcAddress(library, "add");
    Answer native_answer = (Answer)GetProcAddress(library, "foo.native_answer");
    if (!answer || !add || !native_answer || answer() != 42 ||
        add(41) != 42 || native_answer() != 43 ||
        GetProcAddress(library, "foo_qbe_panic")) return 3;
    FreeLibrary(library);
    puts("QBE shared library: ok");
    return 0;
}
