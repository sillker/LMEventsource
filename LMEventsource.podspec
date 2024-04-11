Pod::Spec.new do |s|
	s.name         = "LMEventsource"
	s.version      = "1.1.0"
	s.summary      = "HTML5 Server-Sent Events in your Cocoa app."
	s.homepage     = 'https://github.com/sillker/LMEventsource'
	s.license      = { :type => 'MIT', :file => 'LICENSE' }
	s.author       = { "sillker" => "269055130@qq.com" }
	s.source       = { :git => 'https://github.com/sillker/LMEventsource.git', :tag => s.version }
	s.source_files = 'LMEventsource/**/*.{h,m}'
	s.platform     = :ios, "11.0"
	s.requires_arc = true
	s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
	s.xcconfig = { 'OTHER_LDFLAGS' => '-lobjc' }
end
