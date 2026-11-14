#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dirent.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdlib.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/resource.h>
#include <spawn.h>
#include <signal.h>
#include <sys/wait.h>
#include <poll.h>
#include <stdio.h>
#include <time.h>
