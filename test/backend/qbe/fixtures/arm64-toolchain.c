extern int foo_qbe_assembler_probe(void);

int main(void) {
    return foo_qbe_assembler_probe() == 42 ? 0 : 1;
}
