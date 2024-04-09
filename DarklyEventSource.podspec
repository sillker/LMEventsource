Pod::Spec.new do |s|
	s.name         = "DarklyEventSource"
	s.version      = "1.0.0"
	s.summary      = "HTML5 Server-Sent Events in your Cocoa app."
	s.homepage     = "https://github.com/sillker/LMEventsource"
	s.license      = 'MIT'
	s.author       = { "sillker" => "269055130@qq.com" }
	s.source       = { :git => "https://github.com/sillker/LMEventsource.git", :tag => s.version.to_s }
	s.source_files = 'LDEventSource/**/*.{h,m}'
	s.ios.deployment_target = '11.0'
	s.requires_arc = true
	s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
	s.xcconfig = { 'OTHER_LDFLAGS' => '-lobjc' }
end
