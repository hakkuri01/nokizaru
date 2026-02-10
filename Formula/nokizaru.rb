class Nokizaru < Formula
  desc 'Fast modular web recon CLI for bug bounty workflows'
  homepage 'https://github.com/hakkuri01/nokizaru'
  url 'https://github.com/hakkuri01/nokizaru/archive/refs/tags/v1.6.2.tar.gz'
  sha256 '3917594863cded9a5838a4c57e9b9cc629fe14246e84377ee881d1c3f950ca6b'
  license 'MIT'
  head 'https://github.com/hakkuri01/nokizaru.git', branch: 'main'

  depends_on 'ruby'

  def install
    ENV['GEM_HOME'] = libexec
    ENV['GEM_PATH'] = libexec

    system 'bundle', 'config', 'set', '--local', 'path', libexec
    system 'bundle', 'config', 'set', '--local', 'without', 'development test'
    system 'bundle', 'install'

    system 'gem', 'build', 'nokizaru.gemspec'
    built_gem = Dir['nokizaru-*.gem'].first
    odie 'Could not find built gem artifact' unless built_gem

    system 'gem', 'install', built_gem, '--ignore-dependencies', '--no-document'

    bin.install libexec / 'bin/nokizaru'
    bin.env_script_all_files(libexec / 'bin', GEM_HOME: ENV.fetch('GEM_HOME', nil),
                                              GEM_PATH: ENV.fetch('GEM_PATH', nil))
    man1.install 'man/nokizaru.1'
  end

  test do
    output = shell_output("#{bin}/nokizaru --help")
    assert_match 'Nokizaru - Recon Refined', output
    assert_match '--full', output
    assert_path_exists man1 / 'nokizaru.1'
  end
end
