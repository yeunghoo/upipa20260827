# TradPlus + Meta Audience Network (Facebook)
# Docs: https://docs.tradplusad.com/docs/integration_ios/download
# Demo: https://github.com/tradplus/tradplus-ios-demo

source 'https://cdn.cocoapods.org/'
platform :ios, '15.0'

def tradplus_pods
  pod 'TradPlusAdSDK', '15.13.0'
  pod 'TradPlusAdSDK/FacebookAdapter', '15.13.0'
  pod 'FBAudienceNetwork', '6.22.0'
  pod 'TradPlusAdSDK/TPCrossAdapter', '15.13.0'
end

# 广告 SDK 挂在 UnityFramework：Classes 下的原生插件在此编译
target 'UnityFramework' do
  use_frameworks!
  tradplus_pods
end

target 'Unity-iPhone' do
  use_frameworks!
  # 不要再挂一份 TradPlus：否则会同时编进 Billiard 主二进制与 UnityFramework，
  # 运行时出现 “Class XXX is implemented in both …” 并可能崩溃。
  # FBAudienceNetwork 会随 UnityFramework 的 Pod 依赖一起 Embed。
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
      config.build_settings['ENABLE_BITCODE'] = 'NO'
      config.build_settings['BUILD_LIBRARY_FOR_DISTRIBUTION'] = 'YES'
    end
  end
end
