#ifndef MBCIOSGLBridge_h
#define MBCIOSGLBridge_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

bool MBCIOSGLInitialize(void);
void *MBCIOSGLCreateState(void);
void *MBCIOSGLCurrentState(void);
void MBCIOSGLActivateState(void *state);
void MBCIOSGLDestroyState(void *state);
bool MBCIOSGLProgramsLinked(void);
void MBCIOSGLSetDrawableSize(int width, int height);
void MBCIOSGLGetDrawableSize(int *width, int *height);
bool MBCIOSGLSyncRenderbufferStorage(uint32_t renderbuffer, uint32_t format,
                                   int width, int height);

/* These functions are compiled against the system OpenGLES headers, outside
 * the desktop GL namespace used by the renderer. */
void *MBCIOSGLGetProcAddress(const char *name);
bool MBCIOSGLDriverHasExtension(const char *name);
int MBCIOSGLDriverMaximumSamples(void);
bool MBCIOSGLDriverAllocateStorage(uint32_t format, int samples, int width, int height);
bool MBCIOSGLDriverResolveMultisample(uint32_t source, uint32_t destination);
void MBCIOSGLDriverClearErrors(void);

#ifdef __cplusplus
}
#endif

#endif
