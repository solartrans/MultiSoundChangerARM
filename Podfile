platform :osx, '11.0'

target 'MultiSoundChanger' do
  # Comment the next line if you don't want to use dynamic frameworks
  use_frameworks!

  pod 'SwiftLint', :inhibit_warnings => true
  # MediaKeyTap's fork still uses the deprecated `class` keyword for class-constrained
  # protocols and a few CFRelease-era patterns; inhibit the noise since it's third-party.
  pod 'MediaKeyTap', :git => 'https://github.com/the0neyouseek/MediaKeyTap.git', :branch => 'master', :inhibit_warnings => true
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '11.0'
      # Apply the same Xcode-recommended build hygiene to every Pods target that we apply to
      # the main MultiSoundChanger target. Clicking Xcode's "Perform Changes" would edit
      # Pods.xcodeproj, which CocoaPods regenerates on every `pod install` — so the only way
      # for these to stick across regenerations is right here.
      #
      # Drop the legacy Swift-runtime embed (Swift runtime ships with macOS 10.14.4+; we target
      # 11.0):
      config.build_settings.delete('ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES')
      config.build_settings.delete('EMBEDDED_CONTENT_CONTAINS_SWIFT')
      # Let Xcode auto-pick ARCHS based on the active platform (Xcode's "Automatically Select
      # Architectures" recommendation) — our universal binary still compiles for both arm64
      # and x86_64 via ARCHS_STANDARD:
      config.build_settings.delete('ARCHS')
      # Strip unreferenced code out of the release binary:
      config.build_settings['DEAD_CODE_STRIPPING'] = 'YES'
      # Xcode now complains about any explicit symbol-stripping overrides; reset to defaults:
      config.build_settings.delete('STRIP_INSTALLED_PRODUCT')
      config.build_settings.delete('STRIP_STYLE')
      config.build_settings.delete('STRIP_SWIFT_SYMBOLS')
    end
  end
  installer.pods_project.build_configurations.each do |config|
    # Project-level: allow `xcodebuild -target …` to build independent targets in parallel.
    config.build_settings['ENABLE_PARALLELIZATION_IN_CLI_BUILDS'] = 'YES'
  end
end
