require "json"
require "./paths"

module Nokizaru
  # Scan configuration, loaded from config.json (XDG config dir) with built-in
  # defaults for any missing section or key. A typed value passed through the
  # context, not a global singleton. On a malformed config the file is backed up
  # and the defaults are rewritten, as the Ruby tool did.
  struct Settings
    include JSON::Serializable

    struct Common
      include JSON::Serializable
      getter timeout : Float64 = 30.0
      getter dns_servers : String = "8.8.8.8, 8.8.4.4, 1.1.1.1, 1.0.0.1"

      def initialize
      end
    end

    struct SslCert
      include JSON::Serializable
      getter ssl_port : Int32 = 443

      def initialize
      end
    end

    struct PortScan
      include JSON::Serializable
      getter threads : Int32 = 50

      def initialize
      end
    end

    struct DirEnum
      include JSON::Serializable
      getter threads : Int32 = 50
      getter? redirect : Bool = false
      getter extension : String = ""

      def initialize
      end
    end

    # Curated directory wordlists, embedded under data/wordlists; the dirrec
    # module resolves a size name to the embedded list, a custom -w to a disk path.
    WORDLISTS = {
      "small"  => "raft_small-dir_2k.txt",
      "medium" => "raft_med-dir_5k.txt",
      "large"  => "raft_big-dir_10k.txt",
    }
    DEFAULT_WORDLIST = "medium"

    getter common : Common = Common.new
    getter ssl_cert : SslCert = SslCert.new
    getter port_scan : PortScan = PortScan.new
    getter dir_enum : DirEnum = DirEnum.new

    def initialize
    end

    def self.load(path : String = Paths.config_file) : Settings
      if File.exists?(path)
        begin
          return from_json(File.read(path))
        rescue JSON::ParseException
          backup(path)
        end
      end
      write_default(path)
    end

    def self.write_default(path : String) : Settings
      settings = Settings.new
      Dir.mkdir_p(File.dirname(path), Paths::PRIVATE_DIR)
      File.write(path, "#{settings.to_pretty_json}\n", perm: File::Permissions.new(Paths::PRIVATE_FILE))
      settings
    end

    def self.backup(path : String) : Nil
      File.rename(path, "#{path}.bak.#{Time.utc.to_s("%Y%m%dT%H%M%SZ")}")
    rescue
      nil
    end

    # Normalizes a -w value: a curated size name stays a size name; anything else
    # is treated as a custom wordlist path.
    def self.wordlist(value : String) : String
      WORDLISTS.has_key?(value.downcase) ? value.downcase : value
    end
  end
end
