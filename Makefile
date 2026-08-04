MISE := mise exec --

.PHONY: analyze test build-dev build-release release-key icons

# Render launcher-icon PNGs from assets/icon/*.svg (needs rsvg-convert,
# resvg, inkscape, or magick; CI installs librsvg2-bin).
icons:
	scripts/generate-icons.sh

analyze:
	$(MISE) flutter analyze --no-fatal-infos --no-fatal-warnings

test:
	$(MISE) flutter test --test-randomize-ordering-seed=random

build-dev: icons
	$(MISE) flutter build apk --debug --flavor development --target-platform android-arm64

build-release: icons
	$(MISE) flutter build apk --release --flavor production --target-platform android-arm64

# One-time: generate the stable release key + upload CI signing secrets.
release-key:
	scripts/setup-release-keystore.sh --upload
