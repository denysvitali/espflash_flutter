MISE := mise exec --

.PHONY: analyze test build-dev build-release release-key

analyze:
	$(MISE) flutter analyze --no-fatal-infos --no-fatal-warnings

test:
	$(MISE) flutter test --test-randomize-ordering-seed=random

build-dev:
	$(MISE) flutter build apk --debug --flavor development --target-platform android-arm64

build-release:
	$(MISE) flutter build apk --release --flavor production --target-platform android-arm64

# One-time: generate the stable release key + upload CI signing secrets.
release-key:
	scripts/setup-release-keystore.sh --upload
