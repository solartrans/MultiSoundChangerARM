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
    end
  end
end
