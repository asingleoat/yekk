/* Third-party declarations only. Application implementation is Zig. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <vips/vips.h>
#include <gio/gio.h>
#include <fontconfig/fontconfig.h>
#include <fontconfig/fcfreetype.h>
#include <SDL3/SDL.h>
#include <lcms2.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <sched.h>
#include <SDL3/SDL_system.h>
#include <X11/Xlib.h>
#include <X11/extensions/XInput2.h>
