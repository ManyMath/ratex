#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint ratex_flutter.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'ratex_flutter'
  s.version          = '0.0.1'
  s.summary          = 'KaTeX-compatible math rendering for Flutter via the Rust RaTeX engine.'
  s.description      = <<-DESC
KaTeX-compatible math rendering for Flutter. Builds the ratex_ffi Rust crate
automatically via cargokit and renders RaTeX display lists onto a Canvas.
                       DESC
  s.homepage         = 'https://github.com/ManyMath/ratex'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'ManyMath' => 'https://github.com/ManyMath' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'

  # Build the shared `ratex_ffi` Rust crate (static lib) via cargokit and
  # force-link it into the plugin framework.
  s.script_phase = {
    :name => 'Build ratex_ffi',
    :script => 'sh "$PODS_TARGET_SRCROOT/../cargokit/build_pod.sh" ../../../native/ratex-ffi ratex_ffi',
    :execution_position => :before_compile,
    :input_files => ['${BUILT_PRODUCTS_DIR}/cargokit_phony'],
    :output_files => ['${BUILT_PRODUCTS_DIR}/libratex_ffi.a'],
  }

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.11'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'OTHER_LDFLAGS' => '-force_load ${BUILT_PRODUCTS_DIR}/libratex_ffi.a',
  }
  s.swift_version = '5.0'
end
