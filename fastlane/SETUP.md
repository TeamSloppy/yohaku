# TestFlight setup

Install the pinned Fastlane dependency. Fastlane 2.226 requires Bundler 2.x:

```sh
gem install bundler -v 2.6.0
bundle _2.6.0_ install
```

Copy `fastlane/.env.example` to `fastlane/.env` and fill in the App Store
Connect API key values. The local `.env` and `.p8` files are ignored by Git.

Build a signed App Store IPA without uploading it:

```sh
bundle _2.6.0_ exec fastlane ios build
```

Build and upload to TestFlight:

```sh
bundle _2.6.0_ exec fastlane ios beta
```

The `beta` lane reads the latest TestFlight build number and uses the next one.
Set `BUILD_NUMBER` to override it, or `MARKETING_VERSION` to upload another app
version. Automatic signing requires the Apple Distribution certificate to be
available in the keychain and the team account to be configured in Xcode.
