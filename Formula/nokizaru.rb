# frozen_string_literal: true

# Nokizaru implementation
class Nokizaru < Formula
  desc "Fast modular web recon CLI for bug bounty workflows"
  homepage "https://github.com/hakkuri01/nokizaru"
  url "https://github.com/hakkuri01/nokizaru/archive/refs/tags/v2.1.2.tar.gz"
  sha256 "7473530a5a456eaff7e68e314c0f6bf26a927d29fd23e917eac3cd7118ca34cd"
  license "MIT"
  head "https://github.com/hakkuri01/nokizaru.git", branch: "main"

  depends_on "pkgconf" => :build
  depends_on "ruby"
  depends_on "sqlite"

  def install
    configure_ruby_env
    configure_bundle
    built_gem = build_package
    install_package(built_gem)
    cleanup_build_artifacts
    install_bin_wrappers
    man1.install "man/nokizaru.1"
  end

  def configure_ruby_env
    ENV.prepend_path "PATH", Formula["ruby"].opt_bin
    ENV.prepend_path "PATH", Formula["pkgconf"].opt_bin
    ENV.prepend_path "PKG_CONFIG_PATH", Formula["sqlite"].opt_lib / "pkgconfig"
    ENV["GEM_HOME"] = bundle_path
    ENV["GEM_PATH"] = bundle_path
  end

  def bundle_path
    @bundle_path ||= begin
      ruby_bin = Formula["ruby"].opt_bin / "ruby"
      ruby_abi = Utils.safe_popen_read(ruby_bin, "-e", "print RbConfig::CONFIG[%q[ruby_version]]").strip
      odie "Unable to determine Ruby ABI version" if ruby_abi.empty?

      libexec / "ruby/#{ruby_abi}"
    end
  end

  def configure_bundle
    ENV["BUNDLE_PATH"] = libexec.to_s
    ENV["BUNDLE_WITHOUT"] = "development test"
    ENV["BUNDLE_DEPLOYMENT"] = "true" if (buildpath / "Gemfile.lock").exist?
    ENV["BUNDLE_VERSION"] = "system"
    ENV["BUNDLE_BUILD__SQLITE3"] = "--enable-system-libraries --with-sqlite3-dir=#{Formula["sqlite"].opt_prefix}"
    system "bundle", "install"
  end

  def build_package
    system "gem", "build", "nokizaru.gemspec"
    gem_file = Dir["nokizaru-*.gem"].first
    odie "Could not find built gem artifact" unless gem_file
    gem_file
  end

  def install_package(gem_file)
    system "gem", "install", gem_file, "--install-dir", bundle_path, "--bindir", bundle_path / "bin",
           "--ignore-dependencies", "--no-document"
  end

  def cleanup_build_artifacts
    Dir[bundle_path / "gems/*/ext/**/tmp"].each { |path| rm_r path }
    Dir[bundle_path / "gems/*/ext/**/mkmf.log"].each { |path| rm path }
  end

  def install_bin_wrappers
    bin.install bundle_path / "bin/nokizaru"
    bin.env_script_all_files(
      bundle_path / "bin",
      GEM_HOME: ENV.fetch("GEM_HOME", nil),
      GEM_PATH: ENV.fetch("GEM_PATH", nil),
      PATH:     "#{Formula["ruby"].opt_bin}:$PATH",
    )
  end

  test do
    output = shell_output("#{bin}/nokizaru --help")
    assert_match "Nokizaru - Recon Refined", output
    assert_match "--full", output
    assert_path_exists man1 / "nokizaru.1"
  end
end
