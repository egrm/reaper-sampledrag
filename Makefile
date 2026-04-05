CXX = clang++
CXXFLAGS = -std=c++17 -ObjC++ -O2 -Wall -Wextra -Wno-unused-parameter \
           -Wno-deprecated-declarations \
           -arch arm64 -dynamiclib -fvisibility=hidden \
           -Ivendor/WDL -Ivendor/reaper-sdk/sdk -DSWELL_PROVIDED_BY_APP
LDFLAGS = -framework Cocoa
TARGET = reaper_sampledrag-arm64.dylib
INSTALL_DIR ?= $(HOME)/Applications/REAPER/UserPlugins

WDL_SWELL_MODSTUB = vendor/WDL/WDL/swell/swell-modstub.mm
SRC = src/sampledrag.mm $(WDL_SWELL_MODSTUB)

# reaper_plugin.h includes ../WDL/swell/swell.h relative to itself.
# This symlink makes that path resolve via the WDL submodule.
# reaper_plugin.h includes ../WDL/swell/swell.h relative to itself.
# This symlink makes that path resolve via the WDL submodule.
WDL_LINK = vendor/reaper-sdk/WDL

.DEFAULT_GOAL := $(TARGET)

$(WDL_LINK):
	ln -s ../WDL/WDL $@

$(TARGET): $(WDL_LINK) $(SRC)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) -o $@ $(SRC)

install: $(TARGET)
	cp $(TARGET) $(INSTALL_DIR)/

clean:
	rm -f $(TARGET) $(WDL_LINK)

.PHONY: install clean
