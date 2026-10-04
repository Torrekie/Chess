#include "MBCIOSGLBridge.h"

#include "../ThirdParty/gl4es/include/gl4esinit.h"
#include "../ThirdParty/gl4es/src/gl/gl4es.h"
#include "../ThirdParty/gl4es/src/gl/init.h"
#include "../ThirdParty/gl4es/src/gl/program.h"
#include "../ThirdParty/gl4es/src/gl/shader.h"

/* gl4es has no EAGL context manager. Keep its pinned internal state interface
 * confined to this file; each view uses an independent native context. */
extern void *NewGLState(void *shared_glstate, int es2only);
extern void ActivateGLState(void *state);
extern void DeleteGLState(void *state);

static bool initialized;
static int drawableWidth;
static int drawableHeight;

static void mainFramebufferSize(int *width, int *height)
{
    *width = drawableWidth;
    *height = drawableHeight;
}

bool MBCIOSGLInitialize(void)
{
    if (initialized) return true;
    if (!MBCIOSGLGetProcAddress("glGetString")) return false;
    set_getprocaddress(MBCIOSGLGetProcAddress);
    set_getmainfbsize(mainFramebufferSize);
    initialize_gl4es();
    /* EAGL presents its native color renderbuffer. Replacing that attachment
     * with a texture would render into storage that never reaches the layer. */
    globals4es.fboforcetex = 0;
    initialized = glstate != NULL;
    return initialized;
}

void *MBCIOSGLCreateState(void)
{
    return initialized ? NewGLState(NULL, 0) : NULL;
}

void *MBCIOSGLCurrentState(void)
{
    return glstate;
}

void MBCIOSGLActivateState(void *state)
{
    if (initialized) ActivateGLState(state);
}

void MBCIOSGLDestroyState(void *state)
{
    if (!state) return;
    glstate_t *ownedState = state;
    ActivateGLState(state);
    gl4es_glFinish();

    /* Upstream context disposal leaves the program/shader maps for its GLX
     * context manager. EAGL owns the native lifetime here. */
    if (ownedState->glsl) {
        if (ownedState->glsl->programs) {
            for (khint_t k = kh_begin(ownedState->glsl->programs);
                 k != kh_end(ownedState->glsl->programs); ++k) {
                if (kh_exist(ownedState->glsl->programs, k))
                    gl4es_glDeleteProgram(kh_key(ownedState->glsl->programs, k));
            }
            kh_destroy(programlist, ownedState->glsl->programs);
            ownedState->glsl->programs = NULL;
        }
        if (ownedState->glsl->shaders) {
            for (khint_t k = kh_begin(ownedState->glsl->shaders);
                 k != kh_end(ownedState->glsl->shaders); ++k) {
                if (kh_exist(ownedState->glsl->shaders, k))
                    gl4es_glDeleteShader(kh_key(ownedState->glsl->shaders, k));
            }
            kh_destroy(shaderlist, ownedState->glsl->shaders);
            ownedState->glsl->shaders = NULL;
        }
    }
    DeleteGLState(state);
}

bool MBCIOSGLProgramsLinked(void)
{
    if (!glstate || !glstate->glsl) return false;
    khash_t(programlist) *programs = glstate->glsl->programs;
    if (!programs) return true;
    for (khint_t k = kh_begin(programs); k != kh_end(programs); ++k) {
        if (kh_exist(programs, k) && !kh_value(programs, k)->linked) return false;
    }
    return true;
}

void MBCIOSGLSetDrawableSize(int width, int height)
{
    drawableWidth = width;
    drawableHeight = height;
}

void MBCIOSGLGetDrawableSize(int *width, int *height)
{
    *width = drawableWidth;
    *height = drawableHeight;
}

bool MBCIOSGLSyncRenderbufferStorage(uint32_t renderbuffer, uint32_t format,
                                   int width, int height)
{
    if (!glstate || !glstate->fbo.renderbufferlist) return false;
    khint_t k = kh_get(renderbufferlist_t, glstate->fbo.renderbufferlist, renderbuffer);
    if (k == kh_end(glstate->fbo.renderbufferlist)) return false;
    glrenderbuffer_t *storage = kh_value(glstate->fbo.renderbufferlist, k);
    storage->width = width;
    storage->height = height;
    storage->format = format;
    storage->actual = format;
    return true;
}
