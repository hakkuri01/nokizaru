module Nokizaru
  # The startup banner art: the braille mark above the figlet wordmark, embedded
  # at compile time. One source for the classic banner and the TUI opening screen.
  module Banner
    TEXT = {{ read_file("#{__DIR__}/../../data/banner.txt") }}
  end
end
