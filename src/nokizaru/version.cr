# Nokizaru: fast, modular web reconnaissance with an interactive terminal dashboard.
module Nokizaru
  # version read from shard.yml at compile time so the two cannot drift
  VERSION = {{ read_file("#{__DIR__}/../../shard.yml").lines.find(&.starts_with?("version:")).split(":").last.strip }}
end
