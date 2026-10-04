/*
 * In-process Sjeng entry point for iOS.
 *
 * The original source is kept in sjeng/ and is included as one translation
 * unit with thread-local game/search state. stdin
 * and stdout are redirected through these per-engine FILE objects rather than
 * changing the application's process descriptors.
 */

#include <stdio.h>
#include <stdlib.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <sys/select.h>
#include <limits.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <ndbm.h>
#include "MBCIOSjeng.h"

struct MBCIOSjengSession {
    int inputFD;
    int outputFD;
    atomic_int stopRequested;
    char workingDirectory[PATH_MAX];
};

static _Thread_local MBCIOSjengSession *sjeng_session;
static _Thread_local unsigned sjeng_random_seed;

/* The desktop engine is a child process and may call exit() for its normal
 * xboard quit path.  In-process iOS execution must turn that into a return
 * from the engine thread instead of terminating ChessIOS. */
static _Thread_local jmp_buf sjeng_exit_jmp;
static _Thread_local int sjeng_exit_status;

void sjeng_exit(int status)
{
    sjeng_exit_status = status;
    longjmp(sjeng_exit_jmp, 1);
}

static _Thread_local FILE *sjeng_stdin;
static _Thread_local FILE *sjeng_stdout;

/* Sjeng's search interrupt normally peeks at xboard input. Crazyhouse may
 * deliberately ignore that input while searching, so a scene handoff needs
 * a separate request that the search thread can observe without a pipe. */
void MBCIOSjengRequestStop(MBCIOSjengSession *session)
{
    if (session) atomic_store_explicit(&session->stopRequested, 1, memory_order_relaxed);
}

static int MBCIOSjengStopRequested(void)
{
    return sjeng_session && atomic_load_explicit(&sjeng_session->stopRequested,
                                                 memory_order_relaxed);
}

/* A process-wide chdir would redirect other scenes and document operations.
 * Resolve the engine's relative resources and learning files per session. */
static const char *MBCIOSjengPath(const char *path, char *buffer, size_t length)
{
    if (!path || path[0] == '/' || !sjeng_session) return path;
    int count = snprintf(buffer, length, "%s/%s", sjeng_session->workingDirectory, path);
    if (count < 0 || (size_t)count >= length) {
        errno = ENAMETOOLONG;
        return NULL;
    }
    return buffer;
}

static FILE *MBCIOSjengFOpen(const char *path, const char *mode)
{
    char buffer[PATH_MAX];
    const char *resolved = MBCIOSjengPath(path, buffer, sizeof(buffer));
    return resolved ? fopen(resolved, mode) : NULL;
}

static DBM *MBCIOSjengDBMOpen(const char *path, int flags, int mode)
{
    char buffer[PATH_MAX];
    const char *resolved = MBCIOSjengPath(path, buffer, sizeof(buffer));
    return resolved ? dbm_open(resolved, flags, mode) : NULL;
}

static int MBCIOSjengRandom(void)
{
    return rand_r(&sjeng_random_seed);
}

static void MBCIOSjengSeedRandom(unsigned seed)
{
    sjeng_random_seed = seed;
}

int sjeng_printf(const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    int result = vfprintf(sjeng_stdout, format, arguments);
    va_end(arguments);
    return result;
}

int sjeng_putchar(int character)
{
    return fputc(character, sjeng_stdout);
}

/* Sjeng's historical interrupt poll assumes that its FILE *stdin is file
 * descriptor 0.  The embedded engine owns a pipe-backed FILE instead, so map
 * that poll to the descriptor behind sjeng_stdin without changing upstream
 * source files. */
static void MBCIOSjengFDSet(int ignored, fd_set *set)
{
    (void)ignored;
    FD_SET(fileno(sjeng_stdin), set);
}

static int MBCIOSjengFDIsSet(int ignored, const fd_set *set)
{
    (void)ignored;
    return FD_ISSET(fileno(sjeng_stdin), set);
}

static int MBCIOSjengSelect(int ignored, fd_set *readSet, fd_set *writeSet,
                            fd_set *exceptionSet, struct timeval *timeoutValue)
{
    (void)ignored;
    int inputFD = fileno(sjeng_stdin);
    return select(inputFD + 1, readSet, writeSet, exceptionSet, timeoutValue);
}

#define stdin sjeng_stdin
#define stdout sjeng_stdout
#define exit sjeng_exit
#define printf sjeng_printf
#define putchar sjeng_putchar
#define fopen MBCIOSjengFOpen
#define dbm_open MBCIOSjengDBMOpen
#define rand MBCIOSjengRandom
#define srand MBCIOSjengSeedRandom
#undef FD_SET
#undef FD_ISSET
#define FD_SET(fd, set) MBCIOSjengFDSet((fd), (set))
#define FD_ISSET(fd, set) MBCIOSjengFDIsSet((fd), (set))
#define select(nfds, readSet, writeSet, exceptionSet, timeoutValue) \
    MBCIOSjengSelect((nfds), (readSet), (writeSet), (exceptionSet), (timeoutValue))
#define main sjeng_main
#define MBC_IOS_IN_PROCESS_SJENG 1
#include "../sjeng/blob2.c"

MBCIOSjengSession *MBCIOSjengCreate(int inputFD, int outputFD,
                                  const char *workingDirectory)
{
    if (!workingDirectory || strlen(workingDirectory) >= PATH_MAX) return NULL;
    MBCIOSjengSession *session = calloc(1, sizeof(*session));
    if (!session) return NULL;
    session->inputFD = inputFD;
    session->outputFD = outputFD;
    atomic_init(&session->stopRequested, 0);
    strcpy(session->workingDirectory, workingDirectory);
    return session;
}

int MBCIOSjengRun(MBCIOSjengSession *session)
{
    sjeng_session = session;
    sjeng_stdin = fdopen(session->inputFD, "r");
    sjeng_stdout = fdopen(session->outputFD, "w");
    sjeng_exit_status = EXIT_FAILURE;
    if (sjeng_stdin && sjeng_stdout) {
        setbuf(sjeng_stdin, NULL);
        setbuf(sjeng_stdout, NULL);
        char argument[] = "sjeng (Chess Engine)";
        char *arguments[] = {argument, NULL};
        if (setjmp(sjeng_exit_jmp) == 0) sjeng_main(1, arguments);
    }
    if (sjeng_stdin) fclose(sjeng_stdin);
    else close(session->inputFD);
    if (sjeng_stdout) fclose(sjeng_stdout);
    else close(session->outputFD);
    sjeng_stdin = sjeng_stdout = NULL;
    sjeng_session = NULL;
    return sjeng_exit_status;
}

void MBCIOSjengDestroy(MBCIOSjengSession *session)
{
    free(session);
}
