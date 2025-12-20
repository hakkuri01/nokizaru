# frozen_string_literal: true

require_relative 'lib/nokizaru/version'

Gem::Specification.new do |spec|
  spec.name        = 'nokizaru'
  spec.version     = Nokizaru::VERSION
  spec.authors     = ['hakkuri', 'Nokizaru contributors']
  spec.homepage    = 'https://github.com/hakkuri01/nokizaru'

  spec.metadata = {
    'homepage_uri'    => spec.homepage,
    'source_code_uri' => spec.homepage,
    'bug_tracker_uri' => "#{spec.homepage}/issues",
    'rubygems_mfa_required'  => 'true'
  }

  spec.summary     = 'Nokizaru - Recon Refined'
  spec.description = 'Fast, modular web recon CLI for bug bounty/pentest workflows the Ruby way.'
  spec.license     = 'MIT'

  spec.required_ruby_version = '>= 3.1'

  spec.files = Dir[
    'bin/*',
    'lib/**/*',
    'conf/*',
    'data/*',
    'wordlists/*',
    'man/*',
    'README.md',
    'LICENSE'
  ]

  spec.bindir        = 'bin'
  spec.executables   = ['nokizaru']
  spec.require_paths = ['lib']

  spec.add_dependency 'thor', '~> 1.3'

  spec.add_dependency 'httpx', '~> 1.3'
  spec.add_dependency 'nokogiri', '~> 1.16'
  spec.add_dependency 'concurrent-ruby', '~> 1.3'
  spec.add_dependency 'async', '~> 2.10'
  spec.add_dependency 'async-io', '~> 1.35'
  spec.add_dependency 'public_suffix', '~> 5.0'
  spec.add_dependency 'dnsruby', '~> 1.72'
  spec.add_dependency 'whois', '~> 5.0'
end
