#ifndef FOO_QBE_GETOPT_H
#define FOO_QBE_GETOPT_H

extern char *optarg;
extern int optind;
extern int opterr;
extern int optopt;

int getopt(int argc, char *const argv[], const char *options);

#endif
