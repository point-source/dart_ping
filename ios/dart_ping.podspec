#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint dart_ping.podspec' to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'dart_ping'
  s.version          = '2.0.0'
  s.summary          = 'Multi-platform network ping utility for Dart applications.'
  s.description      = <<-DESC
  Multi-platform network ping utility for Dart applications.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '9.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end

# Pod::Spec.new do |s|
#   s.name             = 'SwiftyPing'
#   s.version          = '1.1.7'
#   s.summary          = 'ICMP ping client for Swift 5.'
#   s.description      = <<-DESC
#   ICMP ping client for Swift 5.
#                        DESC
#   s.homepage         = 'https://github.com/samiyr/SwiftyPing'
#   s.license          = 'https://github.com/samiyr/SwiftyPing/blob/master/LICENSE'
#   s.author           = { 'samiyr' => '' }
#   s.source           = { :git => 'https://github.com/samiyr/SwiftyPing.git', :tag => 'v1.1.7' }
#   s.source_files = 'Sources/SwiftyPing/*'
#   s.platform = :ios, '9.0'

#   # Flutter.framework does not contain a i386 slice.
#   s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
#   s.swift_version = '5.0'
# end
