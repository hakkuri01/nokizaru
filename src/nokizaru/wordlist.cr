module Nokizaru
  # The curated directory wordlists, embedded at compile time so the single
  # binary carries them (the same convention as the PSL list and the banner). A
  # -w size name resolves to its embedded list; any other value is a path read
  # from disk. Replaces the Ruby Settings.curated_wordlist, which joined
  # project_root/wordlists/<file> — a compiled binary has no such directory, so
  # the lists ride inside it.
  module Wordlist
    extend self

    SMALL  = {{ read_file("#{__DIR__}/../../data/wordlists/raft_small-dir_2k.txt") }}
    MEDIUM = {{ read_file("#{__DIR__}/../../data/wordlists/raft_med-dir_5k.txt") }}
    LARGE  = {{ read_file("#{__DIR__}/../../data/wordlists/raft_big-dir_10k.txt") }}

    EMBEDDED = {"small" => SMALL, "medium" => MEDIUM, "large" => LARGE}

    # The words for a -w value: the embedded curated list for a size name, or the
    # lines of a custom file otherwise. Blank lines are dropped and duplicates
    # removed with first-seen order kept. A missing or unreadable custom file
    # yields an empty list (the dir module treats that as "seeds only"), matching
    # the Ruby fallback. Complexity: one O(n) pass over the list plus the O(n)
    # dedupe, once per scan.
    def load(value : String) : Array(String)
      embedded = EMBEDDED[value.downcase]?
      embedded ? split(embedded) : read_path(value)
    end

    private def split(content : String) : Array(String)
      words = [] of String
      content.each_line do |line|
        stripped = line.strip
        words << stripped unless stripped.empty?
      end
      words.uniq!
      words
    end

    private def read_path(path : String) : Array(String)
      split(File.read(path))
    rescue
      [] of String
    end
  end
end
