PRODUCT     := BaconTrackerMenu
APP         := $(PRODUCT).app
BINARY      := .build/release/$(PRODUCT)
BUNDLE_BIN  := $(APP)/Contents/MacOS/$(PRODUCT)
PLIST       := Resources/Info.plist
INSTALL_DIR := $(HOME)/Applications

.PHONY: build test app install run clean

build:
	swift build -c release

test:
	swift test

# Ad-hoc signed: a valid local signature, which Apple silicon requires to run
# the bundle. It is not a Developer ID signature - see README "Installation".
app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BINARY) $(BUNDLE_BIN)
	cp $(PLIST) $(APP)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	codesign --force --sign - $(APP)

install: app
	mkdir -p $(INSTALL_DIR)
	rm -rf $(INSTALL_DIR)/$(APP)
	cp -R $(APP) $(INSTALL_DIR)/$(APP)
	@echo "Installed to $(INSTALL_DIR)/$(APP)"
	@echo "Run: open $(INSTALL_DIR)/$(APP)"

run: build
	$(BINARY)

clean:
	rm -rf .build $(APP)
