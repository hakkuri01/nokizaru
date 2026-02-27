# frozen_string_literal: true

# Nokizaru implementation
class Nokizaru < Formula
  desc 'Fast modular web recon CLI for bug bounty workflows'
  homepage 'https://github.com/hakkuri01/nokizaru'
  url 'https://github.com/hakkuri01/nokizaru/archive/refs/tags/v1.11.9.tar.gz'
  sha256 'eaf7626f10b89566eca81e951e2fd663c08fe33d90c868f950b1c89f303aecfe'
  license 'MIT'
  head 'https://github.com/hakkuri01/nokizaru.git', branch: 'main'

  depends_on 'ruby@3.3'

  def install
    configure_ruby_env
    configure_bundle
    built_gem = build_package
    install_package(built_gem)
    install_bin_wrappers
    man1.install 'man/nokizaru.1'
  end

  def configure_ruby_env
    ENV.prepend_path 'PATH', Formula['ruby@3.3'].opt_bin
    ENV['GEM_HOME'] = bundle_path
    ENV['GEM_PATH'] = bundle_path
  end

  def bundle_path
    libexec / 'ruby/3.3.0'
  end

  def configure_bundle
    system 'bundle', 'config', 'set', '--local', 'path', libexec
    system 'bundle', 'config', 'set', '--local', 'without', 'development test'
    system 'bundle', 'config', 'set', '--local', 'deployment', 'true' if (buildpath / 'Gemfile.lock').exist?
    system 'bundle', 'install'
  end

  def build_package
    system 'gem', 'build', 'nokizaru.gemspec'
    gem_file = Dir['nokizaru-*.gem'].first
    odie 'Could not find built gem artifact' unless gem_file
    gem_file
  end

  def install_package(gem_file)
    system 'gem', 'install', gem_file, '--install-dir', bundle_path, '--bindir', bundle_path / 'bin',
           '--ignore-dependencies', '--no-document'
  end

  def install_bin_wrappers
    bin.install bundle_path / 'bin/nokizaru'
    bin.env_script_all_files(
      bundle_path / 'bin',
      GEM_HOME: ENV.fetch('GEM_HOME', nil),
      GEM_PATH: ENV.fetch('GEM_PATH', nil),
      PATH: "#{Formula['ruby@3.3'].opt_bin}:$PATH"
    )
  end

  test do
    output = shell_output("#{bin}/nokizaru --help")
    assert_match 'Nokizaru - Recon Refined', output
    assert_match '--full', output
    assert_path_exists man1 / 'nokizaru.1'
  end
end
