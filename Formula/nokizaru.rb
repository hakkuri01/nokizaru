class Nokizaru < Formula
  desc 'Fast modular web recon CLI for bug bounty workflows'
  homepage 'https://github.com/hakkuri01/nokizaru'
  url 'https://github.com/hakkuri01/nokizaru/archive/refs/tags/v1.8.7.tar.gz'
  sha256 '9de8c5888dfab076ebfaf0b000f05c9f750813eb78b66e202693664d95cb11c6'
  license 'MIT'
  head 'https://github.com/hakkuri01/nokizaru.git', branch: 'main'

  depends_on 'ruby@3.3'

  def install
    ENV.prepend_path 'PATH', Formula['ruby@3.3'].opt_bin
    bundle_path = libexec / 'ruby/3.3.0'
    ENV['GEM_HOME'] = bundle_path
    ENV['GEM_PATH'] = bundle_path

    system 'bundle', 'config', 'set', '--local', 'path', libexec
    system 'bundle', 'config', 'set', '--local', 'without', 'development test'
    system 'bundle', 'config', 'set', '--local', 'deployment', 'true' if (buildpath / 'Gemfile.lock').exist?
    system 'bundle', 'install'

    system 'gem', 'build', 'nokizaru.gemspec'
    built_gem = Dir['nokizaru-*.gem'].first
    odie 'Could not find built gem artifact' unless built_gem

    system 'gem', 'install', built_gem, '--install-dir', bundle_path, '--bindir', bundle_path / 'bin',
           '--ignore-dependencies', '--no-document'

    bin.install bundle_path / 'bin/nokizaru'
    bin.env_script_all_files(bundle_path / 'bin', GEM_HOME: ENV.fetch('GEM_HOME', nil),
                                                  GEM_PATH: ENV.fetch('GEM_PATH', nil),
                                                  PATH: "#{Formula['ruby@3.3'].opt_bin}:$PATH")
    man1.install 'man/nokizaru.1'
  end

  test do
    output = shell_output("#{bin}/nokizaru --help")
    assert_match 'Nokizaru - Recon Refined', output
    assert_match '--full', output
    assert_path_exists man1 / 'nokizaru.1'
  end
end
