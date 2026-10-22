#include "getopt.h"
#include <stdio.h>
#include <string.h>

char *optarg;
int optind = 1;
int opterr = 1;
int optopt;

int isblank(int character) {
    return character == ' ' || character == '\t';
}

int getopt(int argc, char *const argv[], const char *options) {
    static const char *next;
    if (!next || !*next) {
        if (optind >= argc || argv[optind][0] != '-' || !argv[optind][1]) return -1;
        if (strcmp(argv[optind], "--") == 0) { ++optind; return -1; }
        next = argv[optind++] + 1;
    }
    int flag = (unsigned char)*next++;
    const char *option = strchr(options, flag);
    if (!option || flag == ':') {
        optopt = flag;
        if (opterr) fprintf(stderr, "unknown option -%c\n", flag);
        return '?';
    }
    if (option[1] == ':') {
        if (*next) optarg = (char *)next;
        else if (optind < argc) optarg = argv[optind++];
        else {
            optopt = flag;
            if (opterr) fprintf(stderr, "option -%c requires a value\n", flag);
            next = 0;
            return '?';
        }
        next = 0;
    } else optarg = 0;
    return flag;
}
