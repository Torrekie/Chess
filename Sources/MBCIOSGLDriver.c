#include "MBCIOSGLBridge.h"

#include <OpenGLES/ES2/gl.h>
#include <OpenGLES/ES2/glext.h>
#include <stddef.h>
#include <string.h>

typedef struct {
    const char *name;
    void *address;
} MBCIOSGLFunction;

#define GL_FUNCTION(name) { #name, (void *)&name }
static const MBCIOSGLFunction functions[] = {
    GL_FUNCTION(glActiveTexture),
    GL_FUNCTION(glAttachShader),
    GL_FUNCTION(glBindAttribLocation),
    GL_FUNCTION(glBindBuffer),
    GL_FUNCTION(glBindFramebuffer),
    GL_FUNCTION(glBindRenderbuffer),
    GL_FUNCTION(glBindTexture),
    GL_FUNCTION(glBlendColor),
    GL_FUNCTION(glBlendEquation),
    GL_FUNCTION(glBlendEquationSeparate),
    GL_FUNCTION(glBlendFunc),
    GL_FUNCTION(glBlendFuncSeparate),
    GL_FUNCTION(glBufferData),
    GL_FUNCTION(glBufferSubData),
    GL_FUNCTION(glCheckFramebufferStatus),
    GL_FUNCTION(glClear),
    GL_FUNCTION(glClearColor),
    GL_FUNCTION(glClearDepthf),
    GL_FUNCTION(glClearStencil),
    GL_FUNCTION(glColorMask),
    GL_FUNCTION(glCompileShader),
    GL_FUNCTION(glCompressedTexImage2D),
    GL_FUNCTION(glCompressedTexSubImage2D),
    GL_FUNCTION(glCopyTexImage2D),
    GL_FUNCTION(glCopyTexSubImage2D),
    GL_FUNCTION(glCreateProgram),
    GL_FUNCTION(glCreateShader),
    GL_FUNCTION(glCullFace),
    GL_FUNCTION(glDeleteBuffers),
    GL_FUNCTION(glDeleteFramebuffers),
    GL_FUNCTION(glDeleteProgram),
    GL_FUNCTION(glDeleteRenderbuffers),
    GL_FUNCTION(glDeleteShader),
    GL_FUNCTION(glDeleteTextures),
    GL_FUNCTION(glDepthFunc),
    GL_FUNCTION(glDepthMask),
    GL_FUNCTION(glDepthRangef),
    GL_FUNCTION(glDetachShader),
    GL_FUNCTION(glDisable),
    GL_FUNCTION(glDisableVertexAttribArray),
    GL_FUNCTION(glDrawArrays),
    GL_FUNCTION(glDrawElements),
    GL_FUNCTION(glEnable),
    GL_FUNCTION(glEnableVertexAttribArray),
    GL_FUNCTION(glFinish),
    GL_FUNCTION(glFlush),
    GL_FUNCTION(glFramebufferRenderbuffer),
    GL_FUNCTION(glFramebufferTexture2D),
    GL_FUNCTION(glFrontFace),
    GL_FUNCTION(glGenBuffers),
    GL_FUNCTION(glGenerateMipmap),
    GL_FUNCTION(glGenFramebuffers),
    GL_FUNCTION(glGenRenderbuffers),
    GL_FUNCTION(glGenTextures),
    GL_FUNCTION(glGetActiveAttrib),
    GL_FUNCTION(glGetActiveUniform),
    GL_FUNCTION(glGetAttachedShaders),
    GL_FUNCTION(glGetAttribLocation),
    GL_FUNCTION(glGetBooleanv),
    GL_FUNCTION(glGetBufferParameteriv),
    GL_FUNCTION(glGetError),
    GL_FUNCTION(glGetFloatv),
    GL_FUNCTION(glGetFramebufferAttachmentParameteriv),
    GL_FUNCTION(glGetIntegerv),
    GL_FUNCTION(glGetProgramiv),
    GL_FUNCTION(glGetProgramInfoLog),
    GL_FUNCTION(glGetRenderbufferParameteriv),
    GL_FUNCTION(glGetShaderiv),
    GL_FUNCTION(glGetShaderInfoLog),
    GL_FUNCTION(glGetShaderPrecisionFormat),
    GL_FUNCTION(glGetShaderSource),
    GL_FUNCTION(glGetString),
    GL_FUNCTION(glGetTexParameterfv),
    GL_FUNCTION(glGetTexParameteriv),
    GL_FUNCTION(glGetUniformfv),
    GL_FUNCTION(glGetUniformiv),
    GL_FUNCTION(glGetUniformLocation),
    GL_FUNCTION(glGetVertexAttribfv),
    GL_FUNCTION(glGetVertexAttribiv),
    GL_FUNCTION(glGetVertexAttribPointerv),
    GL_FUNCTION(glHint),
    GL_FUNCTION(glIsBuffer),
    GL_FUNCTION(glIsEnabled),
    GL_FUNCTION(glIsFramebuffer),
    GL_FUNCTION(glIsProgram),
    GL_FUNCTION(glIsRenderbuffer),
    GL_FUNCTION(glIsShader),
    GL_FUNCTION(glIsTexture),
    GL_FUNCTION(glLineWidth),
    GL_FUNCTION(glLinkProgram),
    GL_FUNCTION(glPixelStorei),
    GL_FUNCTION(glPolygonOffset),
    GL_FUNCTION(glReadPixels),
    GL_FUNCTION(glReleaseShaderCompiler),
    GL_FUNCTION(glRenderbufferStorage),
    GL_FUNCTION(glSampleCoverage),
    GL_FUNCTION(glScissor),
    GL_FUNCTION(glShaderBinary),
    GL_FUNCTION(glShaderSource),
    GL_FUNCTION(glStencilFunc),
    GL_FUNCTION(glStencilFuncSeparate),
    GL_FUNCTION(glStencilMask),
    GL_FUNCTION(glStencilMaskSeparate),
    GL_FUNCTION(glStencilOp),
    GL_FUNCTION(glStencilOpSeparate),
    GL_FUNCTION(glTexImage2D),
    GL_FUNCTION(glTexParameterf),
    GL_FUNCTION(glTexParameterfv),
    GL_FUNCTION(glTexParameteri),
    GL_FUNCTION(glTexParameteriv),
    GL_FUNCTION(glTexSubImage2D),
    GL_FUNCTION(glUniform1f),
    GL_FUNCTION(glUniform1fv),
    GL_FUNCTION(glUniform1i),
    GL_FUNCTION(glUniform1iv),
    GL_FUNCTION(glUniform2f),
    GL_FUNCTION(glUniform2fv),
    GL_FUNCTION(glUniform2i),
    GL_FUNCTION(glUniform2iv),
    GL_FUNCTION(glUniform3f),
    GL_FUNCTION(glUniform3fv),
    GL_FUNCTION(glUniform3i),
    GL_FUNCTION(glUniform3iv),
    GL_FUNCTION(glUniform4f),
    GL_FUNCTION(glUniform4fv),
    GL_FUNCTION(glUniform4i),
    GL_FUNCTION(glUniform4iv),
    GL_FUNCTION(glUniformMatrix2fv),
    GL_FUNCTION(glUniformMatrix3fv),
    GL_FUNCTION(glUniformMatrix4fv),
    GL_FUNCTION(glUseProgram),
    GL_FUNCTION(glValidateProgram),
    GL_FUNCTION(glVertexAttrib1f),
    GL_FUNCTION(glVertexAttrib1fv),
    GL_FUNCTION(glVertexAttrib2f),
    GL_FUNCTION(glVertexAttrib2fv),
    GL_FUNCTION(glVertexAttrib3f),
    GL_FUNCTION(glVertexAttrib3fv),
    GL_FUNCTION(glVertexAttrib4f),
    GL_FUNCTION(glVertexAttrib4fv),
    GL_FUNCTION(glVertexAttribPointer),
    GL_FUNCTION(glViewport),
    GL_FUNCTION(glBindVertexArrayOES),
    GL_FUNCTION(glDeleteVertexArraysOES),
    GL_FUNCTION(glGenVertexArraysOES),
    GL_FUNCTION(glIsVertexArrayOES),
    GL_FUNCTION(glMapBufferOES),
    GL_FUNCTION(glUnmapBufferOES),
    GL_FUNCTION(glGetBufferPointervOES),
    GL_FUNCTION(glMapBufferRangeEXT),
    GL_FUNCTION(glFlushMappedBufferRangeEXT),
    GL_FUNCTION(glDrawArraysInstancedEXT),
    GL_FUNCTION(glDrawElementsInstancedEXT),
    GL_FUNCTION(glVertexAttribDivisorEXT),
    GL_FUNCTION(glDiscardFramebufferEXT),
    GL_FUNCTION(glRenderbufferStorageMultisampleAPPLE),
    GL_FUNCTION(glResolveMultisampleFramebufferAPPLE),
};
#undef GL_FUNCTION

void *MBCIOSGLGetProcAddress(const char *name)
{
    if (!name) return NULL;
    for (size_t i = 0; i < sizeof(functions) / sizeof(functions[0]); ++i) {
        if (strcmp(name, functions[i].name) == 0) return functions[i].address;
    }
    return NULL;
}

bool MBCIOSGLDriverHasExtension(const char *name)
{
    const char *extensions = (const char *)glGetString(GL_EXTENSIONS);
    if (!extensions || !name || !*name || strchr(name, ' ')) return false;
    size_t length = strlen(name);
    const char *position = extensions;
    while ((position = strstr(position, name))) {
        if ((position == extensions || position[-1] == ' ') &&
            (position[length] == '\0' || position[length] == ' ')) return true;
        position += length;
    }
    return false;
}

void MBCIOSGLDriverClearErrors(void)
{
    for (int i = 0; i < 32 && glGetError() != GL_NO_ERROR; ++i) {}
}

int MBCIOSGLDriverMaximumSamples(void)
{
    if (!MBCIOSGLDriverHasExtension("GL_APPLE_framebuffer_multisample")) return 1;
    GLint samples = 1;
    glGetIntegerv(GL_MAX_SAMPLES_APPLE, &samples);
    return samples;
}

bool MBCIOSGLDriverAllocateStorage(uint32_t format, int samples, int width, int height)
{
    MBCIOSGLDriverClearErrors();
    if (samples > 1)
        glRenderbufferStorageMultisampleAPPLE(GL_RENDERBUFFER, samples, format, width, height);
    else
        glRenderbufferStorage(GL_RENDERBUFFER, format, width, height);
    return glGetError() == GL_NO_ERROR;
}

bool MBCIOSGLDriverResolveMultisample(uint32_t source, uint32_t destination)
{
    MBCIOSGLDriverClearErrors();
    glBindFramebuffer(GL_READ_FRAMEBUFFER_APPLE, source);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER_APPLE, destination);
    glResolveMultisampleFramebufferAPPLE();
    return glGetError() == GL_NO_ERROR;
}
