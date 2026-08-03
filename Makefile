MISE := mise exec --

.PHONY: analyze test build-dev build-release

analyze:
	$(MISE) flutter analyze --no-fatal-infos --no-fatal-warnings

test:
	$(MISE) flutter test --test-randomize-ordering-seed=random

build-dev:
	$(MISE) flutter build apk --debug --flavor development --target-platform android-arm64

build-release:
	$(MISE) flutter build apk --release --flavor production --target-platform android-arm64
