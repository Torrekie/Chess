#pragma once

#import <TargetConditionals.h>
#if TARGET_OS_IOS
#define GL_GLEXT_LEGACY 1
#include "../ThirdParty/gl4es/include/GL/gl.h"
#include "../ThirdParty/gl4es/include/GL/glext.h"
#undef GL_GLEXT_LEGACY
#else
#include <OpenGL/gl.h>
#include <OpenGL/glu.h>
#include <OpenGL/glext.h>
#endif
