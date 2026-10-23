require "./paths"

module Nokizaru
  # The runtime log. Logging must never break the tool, so every failure is
  # swallowed. The file is owner-only: it can hold target data.
  module Log
    extend self

    def write(message : String) : Nil
      File.open(Paths.log_file, "a", File::Permissions.new(0o600)) do |file|
        file.print("[#{Time.utc.to_rfc3339}] #{message}\n")
      end
    rescue
      nil
    end
  end
end
