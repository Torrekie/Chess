# ---------------------------------------------------------------------------
# Linux IPA build: `make` (Scripts/build-ipa.sh is the macOS/Xcode path).
#
# Needs a theos tree with the Swift 5.8 iOS toolchain (for clang 13, ld64
# and ldid) and an iPhoneOS SDK:
#   $(THEOS)/toolchain/swift-5.8/linux/iphone/bin/{clang,ar,ldid}
#   $(THEOS)/sdks/iPhoneOS14.*.sdk (the owner's phone runs iOS 14)
# Output: build/Chess.ipa, ad-hoc signed with ldid for TrollStore installs,
# same bundle id and entitlements as build-ipa.sh.
# `make publish` copies it to $(PUBLISH_DIR) with an index.html whose link
# installs it through TrollStore (as in Opaline, Immich-14 and Battman).
#
# Without Xcode's tools: the Metal shaders ship as source and are compiled
# on the device (MBCMetalRenderer falls back to MBCShaders.metal when the
# bundle has no default.metallib), the launch screen comes from Info.plist's
# UILaunchScreen and the app icons are loose PNGs.
# ---------------------------------------------------------------------------

.PHONY: all ipa publish clean
.DELETE_ON_ERROR:

THEOS        ?= $(HOME)/theos
TOOLCHAIN    ?= $(THEOS)/toolchain/swift-5.8/linux/iphone
SDKROOT      ?= $(firstword $(wildcard $(THEOS)/sdks/iPhoneOS14.*.sdk) \
                $(wildcard $(THEOS)/sdks/iPhoneOS15.*.sdk))
SDK_VERSION  := $(patsubst iPhoneOS%.sdk,%,$(notdir $(SDKROOT)))
MIN_OS       ?= 13.0
BUNDLE_ID    := com.apple.Chess
VERSION      := $(shell sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);.*/\1/p' ChessIOS.xcodeproj/project.pbxproj | head -1)
COMMIT_HASH  := $(shell git rev-parse --short HEAD 2>/dev/null)
JOBS         ?= 16
MAKEFLAGS    += -j$(JOBS)
PUBLISH_ROOT ?= /srv/http/files
PUBLISH_DIR  := $(PUBLISH_ROOT)/chess
LOCAL_IP     := $(shell ip addr | sed -n "s/.*inet \([0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\)[ \/].*/\1/p" | grep -v '^127\.' | head -1)

CC   := $(TOOLCHAIN)/bin/clang
CXX  := $(TOOLCHAIN)/bin/clang++
AR   := $(TOOLCHAIN)/bin/ar
LDID := $(TOOLCHAIN)/bin/ldid

ARCHFLAGS := -target arm64-apple-ios$(MIN_OS) -isysroot $(SDKROOT)
OPTFLAGS  ?= -Os
COMMONFLAGS := $(ARCHFLAGS) $(OPTFLAGS) -g0 -DNS_BLOCK_ASSERTIONS=1 -MMD -MP \
	-fmodules -fno-autolink -fobjc-arc -Wno-deprecated-declarations -Wno-nullability-completeness \
	-Wno-unused-command-line-argument
CFLAGS    := $(COMMONFLAGS) -std=gnu11
CXXFLAGS  := $(COMMONFLAGS) -std=gnu++14 -fcxx-modules
# @available checks call into compiler-rt, which clang does not find itself here.
# Frameworks are listed explicitly (-fno-autolink): module autolinking would
# load AVFAudio.framework, which is only a top-level framework from iOS 14.5;
# before that its symbols come through AVFoundation, which re-exports it.
LDFLAGS   := $(ARCHFLAGS) -dead_strip -lc++ -Wl,-no_implicit_dylibs \
	$(TOOLCHAIN)/lib/clang/13.0.0/lib/darwin/libclang_rt.ios.a \
	-Wl,-rpath,@executable_path/Frameworks \
	$(addprefix -framework ,UIKit Foundation CoreFoundation CoreGraphics QuartzCore ImageIO \
	  OpenGLES Metal MetalKit MetalPerformanceShaders ModelIO AVFoundation \
	  ReplayKit CoreMedia GameKit) \
	-weak_framework UniformTypeIdentifiers

OUT := build/linux
APP := $(OUT)/Payload/Chess.app
IPA := build/Chess.ipa

# The Chess target's members in ChessIOS.xcodeproj (Sources/ also holds the
# macOS-only files of MBChess.xcodeproj, so this list is explicit).
APP_SRCS := $(addprefix Sources/, \
	ChessIOSAppDelegate.mm ChessIOSMain.mm ChessIOSSceneDelegate.mm \
	ChessIOSViewController.mm MBCBoardCommon.mm MBCBoard.mm \
	MBCBoardMTLViewAccessibilityIOS.mm MBCBoardMTLViewDraw.mm MBCBoardMTLView.mm \
	MBCBoardMTLViewTouch.mm MBCBoardViewDraw.mm MBCBoardViewIOSAccessibility.mm \
	MBCBoardViewIOS.mm MBCBoardViewIOSTouch.mm MBCBoardView.mm \
	MBCBoardViewModels.mm MBCBoardViewTextures.mm MBCDebug.cp MBCDrawStyle.m \
	MBCIOSAboutViewController.mm MBCIOSBoardBackend.mm MBCIOSChessEngine.mm \
	MBCIOSCompatibility.mm MBCIOSCoordinateEntryViewController.mm \
	MBCIOSDocumentController.mm MBCIOSGameCenterManager.mm \
	MBCIOSGameInfoViewController.mm MBCIOSGameLibrary.mm MBCIOSGameStore.mm \
	MBCIOSGLBridge.c MBCIOSGLDriver.c MBCIOSjeng.c MBCIOSOpenGLView.mm \
	MBCIOSRecordingController.mm MBCIOSRendererPreferences.mm \
	MBCIOSSpeechController.mm MBCMathUtilities.m MBCMeshLoader.mm \
	MBCMetalCamera.mm MBCMetalMaterials.mm MBCMetalRenderer.mm \
	MBCMoveGenerator.mm MBCRenderable.mm MBCUserDefaults.mm)
SHADERS := $(addprefix Sources/,MBCShaders.metal MBCShadersArrow.metal \
	MBCShadersDecal.metal MBCShadersGround.metal)

# gl4es and the GLU subset, as ThirdParty/CMakeLists.txt configures them.
GL4ES_SRCS := $(addprefix ThirdParty/gl4es/src/gl/, \
	arbconverter.c arbgenerator.c arbhelper.c arbparser.c array.c blit.c \
	blend.c buffers.c build_info.c debug.c decompress.c depth.c directstate.c \
	drawing.c enable.c envvars.c eval.c face.c fog.c fpe.c fpe_cache.c \
	fpe_shader.c framebuffers.c gl_lookup.c getter.c gl4es.c glstate.c hint.c \
	init.c light.c line.c list.c listdraw.c listrl.c loader.c logs.c matrix.c \
	matvec.c oldprogram.c pixel.c planes.c pointsprite.c preproc.c program.c \
	queries.c raster.c render.c samplers.c shader.c shaderconv.c \
	shader_hacks.c stack.c stencil.c string_utils.c stubs.c texenv.c texgen.c \
	texture.c texture_compressed.c texture_params.c texture_read.c \
	texture_3d.c uniform.c vertexattrib.c wrap/gl4eswraps.c wrap/gles.c \
	wrap/glstub.c math/matheval.c) ThirdParty/gl4es/src/glx/hardext.c
GLU_SRCS := ThirdParty/GLU/src/libutil/quad.c ThirdParty/GLU/src/libutil/project.c
GL4ES_FLAGS := $(ARCHFLAGS) -O3 -DNDEBUG -MMD -MP -std=gnu11 -funwind-tables \
	-fvisibility=hidden -ffile-prefix-map=$(CURDIR)/ThirdParty=ThirdParty \
	-DSTATICLIB -DNOX11 -DNOEGL -DEGL_NO_X11 -DNO_GBM -DDEFAULT_ES=2 \
	-DNO_LOADER -DHAS_BACKTRACE -IThirdParty/gl4es/include \
	-IThirdParty/gl4es/src/glx -Wno-deprecated-declarations -Wno-pointer-sign \
	-Wno-dangling-else
GLU_FLAGS := $(ARCHFLAGS) -O3 -DNDEBUG -MMD -MP -std=gnu11 \
	-IThirdParty/GLU/include -IThirdParty/gl4es/include -IThirdParty/GLU/src/include

APP_OBJS   := $(patsubst %,$(OUT)/obj/%.o,$(APP_SRCS))

# Per-file COMPILER_FLAGS from ChessIOS.xcodeproj.
GL_INCLUDES := -IThirdParty/gl4es/include -IThirdParty/GLU/include
MRC_SRCS := MBCBoard.mm MBCMoveGenerator.mm MBCBoardView.mm MBCBoardViewDraw.mm \
	MBCBoardViewModels.mm MBCBoardViewTextures.mm MBCBoardViewIOS.mm
GL_SRCS := MBCIOSBoardBackend.mm MBCIOSOpenGLView.mm MBCIOSGLBridge.c \
	MBCBoardView.mm MBCBoardViewDraw.mm MBCBoardViewModels.mm \
	MBCBoardViewTextures.mm MBCBoardViewIOS.mm MBCBoardViewIOSTouch.mm \
	MBCBoardViewIOSAccessibility.mm MBCDrawStyle.m
$(patsubst %,$(OUT)/obj/Sources/%.o,$(MRC_SRCS)): FILEFLAGS += -fno-objc-arc
$(patsubst %,$(OUT)/obj/Sources/%.o,$(GL_SRCS)): FILEFLAGS += $(GL_INCLUDES)
$(OUT)/obj/Sources/MBCIOSGLBridge.c.o: FILEFLAGS += -DNOX11 -DNOEGL
GL4ES_OBJS := $(patsubst %,$(OUT)/obj/%.o,$(GL4ES_SRCS))
GLU_OBJS   := $(patsubst %,$(OUT)/obj/%.o,$(GLU_SRCS))
GL4ES_LIB  := $(OUT)/lib/libChessGL4ES.a
GLU_LIB    := $(OUT)/lib/libChessGLU.a

all: ipa

$(OUT)/obj/Sources/%.mm.o: Sources/%.mm
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) $(FILEFLAGS) -x objective-c++ -c $< -o $@
$(OUT)/obj/Sources/%.cp.o: Sources/%.cp
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) $(FILEFLAGS) -x c++ -c $< -o $@
$(OUT)/obj/Sources/%.m.o: Sources/%.m
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(FILEFLAGS) -x objective-c -c $< -o $@
$(OUT)/obj/Sources/%.c.o: Sources/%.c
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(FILEFLAGS) -c $< -o $@
$(GL4ES_OBJS): $(OUT)/obj/%.o: %
	@mkdir -p $(@D)
	$(CC) $(GL4ES_FLAGS) -c $< -o $@
$(GLU_OBJS): $(OUT)/obj/%.o: %
	@mkdir -p $(@D)
	$(CC) $(GLU_FLAGS) -c $< -o $@

-include $(APP_OBJS:.o=.d) $(GL4ES_OBJS:.o=.d) $(GLU_OBJS:.o=.d)

$(GL4ES_LIB): $(GL4ES_OBJS)
	@mkdir -p $(@D)
	rm -f $@ && $(AR) rcs $@ $^
$(GLU_LIB): $(GLU_OBJS)
	@mkdir -p $(@D)
	rm -f $@ && $(AR) rcs $@ $^

$(OUT)/Chess: $(APP_OBJS) $(GL4ES_LIB) $(GLU_LIB) Makefile
	$(CXX) $(LDFLAGS) $(APP_OBJS) -L$(OUT)/lib -lChessGLU -lChessGL4ES -o $@

# One source for newLibraryWithSource:, with the shared header inlined
# because runtime compilation cannot resolve quoted includes.
$(OUT)/MBCShaders.metal: Sources/MBCShaderTypes.h $(SHADERS)
	@mkdir -p $(@D)
	{ cat Sources/MBCShaderTypes.h; for f in $(SHADERS); do \
		printf '\n#line 1 "%s"\n' "$${f#Sources/}"; \
		sed 's|^#include "MBCShaderTypes.h"|// &|' $$f; done; } > $@

# Packaging is cheap, so it always reruns.
ipa: $(OUT)/Chess $(OUT)/MBCShaders.metal
	rm -rf $(OUT)/Payload
	mkdir -p $(APP)
	for d in *.lproj; do [ "$$d" = Base.lproj ] || { mkdir -p $(APP)/$$d; \
		cp $$d/InfoPlist.strings $$d/Localizable.strings $$d/Spoken.strings $(APP)/$$d/ 2>/dev/null || true; }; done
	cp Resources/MTL/*/* Resources/irradiance.png Resources/Defaults.plist \
		Resources/Chess.txt Resources/ThirdPartyNotices.txt \
		Resources/*.loctable sjeng/sjeng.rc \
		$(addprefix sjeng/books/,normal.opn suicide.opn losers.opn bug.opn nbook.db zbook.db) \
		Assets.xcassets/AppIcon.appiconset/*.png $(APP)/
	cp -r Styles Textures Resources/Meshes $(APP)/
	cp $(OUT)/MBCShaders.metal $(APP)/
	python3 -I Scripts/linux-info-plist.py --source Resources/ChessIOS-Info.plist \
		--output $(APP)/Info.plist --executable Chess --min-os $(MIN_OS) \
		--sdk-version $(SDK_VERSION)
	printf 'APPL????' > $(APP)/PkgInfo
	cp $(OUT)/Chess $(APP)/Chess
	$(LDID) -SResources/ChessIOS-AdHoc.entitlements -I$(BUNDLE_ID) $(APP)/Chess
	rm -f $(IPA)
	cd $(OUT) && zip -qry $(CURDIR)/$(IPA) Payload
	@echo "Built $(IPA)"

publish: ipa
	@mkdir -p $(PUBLISH_DIR)
	cp $(IPA) $(PUBLISH_DIR)/Chess.ipa
	@printf '%s\n' \
		'<html><head><meta name=viewport content="width=device-width,initial-scale=1">' \
		'<title>Chess</title><style>a{font-size:80px}p{font-size:40px}</style></head><body>' \
		'<a href="apple-magnifier://install?url=http%3A%2F%2F$(LOCAL_IP)%2Ffiles%2Fchess%2FChess.ipa">Install</a>' \
		'<p>Chess $(VERSION) ($(COMMIT_HASH))</p>' \
		'<p>Latest Update: $(shell date)</p></body></html>' \
		> $(PUBLISH_DIR)/index.html
	@echo "Published: http://$(LOCAL_IP)/files/chess/  (tap Install -> TrollStore)"

clean:
	rm -rf $(OUT) $(IPA)
