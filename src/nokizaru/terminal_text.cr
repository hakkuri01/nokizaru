module Nokizaru
  # Display-safe terminal text: sanitize untrusted output, measure cells, and wrap
  # SGR-colored lines. All target-supplied text passes through `sanitize` before it
  # reaches the terminal.
  module TerminalText
    extend self

    RESET    = "\e[0m"
    TAB      = "    "
    ELLIPSIS = "…"

    SGR       = /\A\e\[[0-9;]*m\z/
    SGR_TOKEN = /\e\[[0-9;]*m/
    # An SGR sequence, or any single character (including a newline).
    TOKEN = /\e\[[0-9;]*m|[\s\S]/

    # Security: terminal injection from target-supplied text (OSC 52 clipboard writes, title spoofing, cursor
    # moves that hide results) is mitigated by keeping only SGR color and dropping every other escape, C0/C1
    # control, and bidi override in one linear pass. No backreference or lookaround, so it matches in linear time.
    CONTROL = /\e\[[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]|\x{9b}[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]|\e[\]PX^_][^\a\e\x{9c}]*(?:\a|\e\\|\x{9c})?|[\x{90}\x{98}\x{9d}\x{9e}\x{9f}][^\a\e\x{9c}]*(?:\a|\e\\|\x{9c})?|\e[\x20-\x2f]*[\x30-\x7e]?|[\x00-\x1f\x7f\x{80}-\x{9f}\x{202a}-\x{202e}\x{2066}-\x{2069}]/
    # Cells taken by East Asian wide and fullwidth characters and emoji, sorted for binary search.
    # ponytail: no grapheme clustering, so a ZWJ emoji sequence can mismeasure by a cell; target text is mostly
    # ASCII, and a width-table shard is the upgrade path if that ever matters.
    WIDE = [
      {0x1100, 0x115F}, {0x231A, 0x231B}, {0x2329, 0x232A}, {0x23E9, 0x23EC}, {0x23F0, 0x23F0}, {0x23F3, 0x23F3},
      {0x25FD, 0x25FE}, {0x2614, 0x2615}, {0x2648, 0x2653}, {0x267F, 0x267F}, {0x2693, 0x2693}, {0x26A1, 0x26A1},
      {0x26AA, 0x26AB}, {0x26BD, 0x26BE}, {0x26C4, 0x26C5}, {0x26CE, 0x26CE}, {0x26D4, 0x26D4}, {0x26EA, 0x26EA},
      {0x26F2, 0x26F3}, {0x26F5, 0x26F5}, {0x26FA, 0x26FA}, {0x26FD, 0x26FD}, {0x2705, 0x2705}, {0x270A, 0x270B},
      {0x2728, 0x2728}, {0x274C, 0x274C}, {0x274E, 0x274E}, {0x2753, 0x2755}, {0x2757, 0x2757}, {0x2795, 0x2797},
      {0x27B0, 0x27B0}, {0x27BF, 0x27BF}, {0x2B1B, 0x2B1C}, {0x2B50, 0x2B50}, {0x2B55, 0x2B55}, {0x2E80, 0x303E},
      {0x3041, 0x33FF}, {0x3400, 0x4DBF}, {0x4E00, 0x9FFF}, {0xA000, 0xA4CF}, {0xA960, 0xA97F}, {0xAC00, 0xD7A3},
      {0xF900, 0xFAFF}, {0xFE10, 0xFE19}, {0xFE30, 0xFE6F}, {0xFF00, 0xFF60}, {0xFFE0, 0xFFE6}, {0x16FE0, 0x16FE4},
      {0x17000, 0x18AFF}, {0x1B000, 0x1B2FF}, {0x1F004, 0x1F004}, {0x1F0CF, 0x1F0CF}, {0x1F18E, 0x1F18E},
      {0x1F191, 0x1F19A}, {0x1F200, 0x1F251}, {0x1F300, 0x1F64F}, {0x1F680, 0x1F6FF}, {0x1F7E0, 0x1F7EB},
      {0x1F900, 0x1F9FF}, {0x1FA70, 0x1FAFF}, {0x20000, 0x2FFFD}, {0x30000, 0x3FFFD},
    ] of Tuple(Int32, Int32)

    ZERO = [
      {0x0300, 0x036F}, {0x1AB0, 0x1AFF}, {0x1DC0, 0x1DFF}, {0x200B, 0x200F}, {0x2060, 0x2064}, {0x20D0, 0x20FF},
      {0xFE00, 0xFE0F}, {0xFE20, 0xFE2F}, {0xFEFF, 0xFEFF}, {0xE0100, 0xE01EF},
    ] of Tuple(Int32, Int32)

    # Renders one line of untrusted text: a newline would forge a second line, so
    # it goes with the other controls. `keep_newline` is for text whose breaks are
    # content (a WHOIS record), which AGENTS Security 1 preserves.
    def sanitize(text : String, keep_newline : Bool = false) : String
      utf8(text).gsub(CONTROL) do |match|
        next TAB if match == "\t"
        next match if keep_newline && match == "\n"

        match.matches?(SGR) ? match : ""
      end
    end

    # A value on its way into a result, a report file, or a filename. Color goes
    # too: a stored value is read back as data, not rendered.
    def plain(text : String) : String
      strip_sgr(sanitize(text))
    end

    # The same for a multi-line record, keeping its line breaks.
    def plain_block(text : String) : String
      strip_sgr(sanitize(text, keep_newline: true))
    end

    def utf8(text : String) : String
      text.valid_encoding? ? text : text.scrub
    end

    def strip_sgr(text : String) : String
      text.gsub(SGR_TOKEN, "")
    end

    def width(text : String) : Int32
      plain = strip_sgr(text)
      return plain.bytesize if plain.ascii_only?

      plain.each_char.sum { |char| char_width(char.ord) }
    end

    def char_width(code : Int32) : Int32
      return 1 if code < 0x300
      return 0 if in_ranges?(ZERO, code)

      in_ranges?(WIDE, code) ? 2 : 1
    end

    # Ranges are sorted and disjoint, so the first range ending at or after code is the only candidate.
    def in_ranges?(ranges : Array(Tuple(Int32, Int32)), code : Int32) : Bool
      candidate = ranges.bsearch { |range| range[1] >= code }
      !candidate.nil? && candidate[0] <= code
    end

    # Hard-wraps at cols cells like a terminal does, reopening the active color on each continuation row.
    # ponytail: reopening the open SGR state on each continuation row is O(rows x open-SGR length), so one
    # line packed with distinct non-reset SGR codes is O(n^2 / cols) (measured ~13x allocation at 4x input).
    # The bound is the caller: the TUI feed caps line bytes before a line reaches
    # wrap, so n is bounded; the upgrade path is collapsing the active state to a canonical fg/bg/attrs set,
    # which is O(1) however many SGR codes the target sent.
    def wrap(line : String, cols : Int32) : Array(String)
      return [line] if cols <= 0 || width(line) <= cols

      rows = [] of String
      row = IO::Memory.new
      used = 0
      active = IO::Memory.new
      line.scan(TOKEN) do |match|
        token = match[0]
        if token.starts_with?('\e')
          track_sgr(active, token)
          row << token
          next
        end
        cells = char_width(token[0].ord)
        if used + cells > cols
          rows << close(row.to_s, active.to_s)
          row = IO::Memory.new
          row << active.to_s
          used = 0
        end
        row << token
        used += cells
      end
      rows << row.to_s
      rows
    end

    def truncate(line : String, cols : Int32) : String
      return line if width(line) <= cols
      return "" if cols <= 0
      return ELLIPSIS if cols == 1

      "#{wrap(line, cols - 1).first}#{RESET}#{ELLIPSIS}"
    end

    # The SGR state still open at the end of a line, so a multi-line colored write keeps its color per line.
    def active_sgr(line : String) : String
      active = IO::Memory.new
      line.scan(SGR_TOKEN) { |match| track_sgr(active, match[0]) }
      active.to_s
    end

    def track_sgr(active : IO::Memory, sequence : String) : Nil
      if sequence == "\e[0m" || sequence == "\e[m"
        active.clear
      else
        active << sequence
      end
    end

    def close(row : String, active : String) : String
      active.empty? ? row : "#{row}#{RESET}"
    end
  end
end
