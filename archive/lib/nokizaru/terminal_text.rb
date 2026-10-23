# frozen_string_literal: true

module Nokizaru
  # Display-safe terminal text: sanitize untrusted output, measure cells, and wrap SGR-colored lines
  module TerminalText
    module_function

    RESET = "\e[0m"
    TAB = '    '
    ELLIPSIS = '…'

    SGR = /\A\e\[[0-9;]*m\z/
    SGR_TOKEN = /\e\[[0-9;]*m/
    TOKEN = /\e\[[0-9;]*m|./m

    # Security: terminal injection from target-supplied text (OSC 52 clipboard writes, title spoofing, cursor moves
    # that hide results) mitigated by keeping only SGR color and dropping every other escape, C0/C1 control, and
    # bidi override in one linear pass (cost acceptable because it is one regex scan per printed line)
    CONTROL = /
      \e\[[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]
      | \u009b[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]
      | \e[\]PX^_][^\a\e\u009c]*(?:\a|\e\\|\u009c)?
      | [\u0090\u0098\u009d\u009e\u009f][^\a\e\u009c]*(?:\a|\e\\|\u009c)?
      | \e[\x20-\x2f]*[\x30-\x7e]?
      | [\x00-\x1f\x7f\u0080-\u009f\u202a-\u202e\u2066-\u2069]
    /x

    # Cells taken by East Asian wide and fullwidth characters and emoji, sorted for binary search
    # ponytail: no grapheme clustering, so ZWJ emoji sequences can mismeasure by a cell; target text is mostly
    # ASCII, and unicode-display_width is the upgrade path if that ever matters
    WIDE = [
      [0x1100, 0x115F], [0x231A, 0x231B], [0x2329, 0x232A], [0x23E9, 0x23EC], [0x23F0, 0x23F0], [0x23F3, 0x23F3],
      [0x25FD, 0x25FE], [0x2614, 0x2615], [0x2648, 0x2653], [0x267F, 0x267F], [0x2693, 0x2693], [0x26A1, 0x26A1],
      [0x26AA, 0x26AB], [0x26BD, 0x26BE], [0x26C4, 0x26C5], [0x26CE, 0x26CE], [0x26D4, 0x26D4], [0x26EA, 0x26EA],
      [0x26F2, 0x26F3], [0x26F5, 0x26F5], [0x26FA, 0x26FA], [0x26FD, 0x26FD], [0x2705, 0x2705], [0x270A, 0x270B],
      [0x2728, 0x2728], [0x274C, 0x274C], [0x274E, 0x274E], [0x2753, 0x2755], [0x2757, 0x2757], [0x2795, 0x2797],
      [0x27B0, 0x27B0], [0x27BF, 0x27BF], [0x2B1B, 0x2B1C], [0x2B50, 0x2B50], [0x2B55, 0x2B55], [0x2E80, 0x303E],
      [0x3041, 0x33FF], [0x3400, 0x4DBF], [0x4E00, 0x9FFF], [0xA000, 0xA4CF], [0xA960, 0xA97F], [0xAC00, 0xD7A3],
      [0xF900, 0xFAFF], [0xFE10, 0xFE19], [0xFE30, 0xFE6F], [0xFF00, 0xFF60], [0xFFE0, 0xFFE6], [0x16FE0, 0x16FE4],
      [0x17000, 0x18AFF], [0x1B000, 0x1B2FF], [0x1F004, 0x1F004], [0x1F0CF, 0x1F0CF], [0x1F18E, 0x1F18E],
      [0x1F191, 0x1F19A], [0x1F200, 0x1F251], [0x1F300, 0x1F64F], [0x1F680, 0x1F6FF], [0x1F7E0, 0x1F7EB],
      [0x1F900, 0x1F9FF], [0x1FA70, 0x1FAFF], [0x20000, 0x2FFFD], [0x30000, 0x3FFFD]
    ].freeze

    ZERO = [
      [0x0300, 0x036F], [0x1AB0, 0x1AFF], [0x1DC0, 0x1DFF], [0x200B, 0x200F], [0x2060, 0x2064], [0x20D0, 0x20FF],
      [0xFE00, 0xFE0F], [0xFE20, 0xFE2F], [0xFEFF, 0xFEFF], [0xE0100, 0xE01EF]
    ].freeze

    def sanitize(text)
      utf8(text).gsub(CONTROL) do |sequence|
        next TAB if sequence == "\t"

        sequence.match?(SGR) ? sequence : ''
      end
    end

    def utf8(text)
      string = text.to_s
      unless [Encoding::UTF_8, Encoding::BINARY, Encoding::US_ASCII].include?(string.encoding)
        return string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
      end

      string = string.dup.force_encoding(Encoding::UTF_8)
      string.valid_encoding? ? string : string.scrub("\uFFFD")
    end

    def strip_sgr(text)
      text.to_s.gsub(SGR_TOKEN, '')
    end

    def width(text)
      plain = strip_sgr(text)
      return plain.bytesize if plain.ascii_only?

      plain.each_char.sum { |char| char_width(char.ord) }
    end

    def char_width(code)
      return 1 if code < 0x300
      return 0 if in_ranges?(ZERO, code)

      in_ranges?(WIDE, code) ? 2 : 1
    end

    # Ranges are sorted and disjoint, so the first range ending at or after code is the only candidate
    def in_ranges?(ranges, code)
      candidate = ranges.bsearch { |(_low, high)| high >= code }
      !candidate.nil? && candidate[0] <= code
    end

    # Hard-wraps at cols cells like a terminal does, reopening the active color on each continuation row
    def wrap(line, cols)
      return [line] if cols <= 0 || width(line) <= cols

      rows = []
      row = +''
      used = 0
      active = +''
      line.scan(TOKEN) do |token|
        if token.getbyte(0) == 27
          track_sgr(active, token)
          next row << token
        end
        cells = char_width(token.ord)
        if used + cells > cols
          rows << close(row, active)
          row = active.dup
          used = 0
        end
        row << token
        used += cells
      end
      rows << row
    end

    def truncate(line, cols)
      return line if width(line) <= cols
      return '' if cols <= 0
      return ELLIPSIS if cols == 1

      "#{wrap(line, cols - 1).first}#{RESET}#{ELLIPSIS}"
    end

    # The SGR state still open at the end of a line, so a multi-line colored write keeps its color per line
    def active_sgr(line)
      line.scan(SGR_TOKEN).each_with_object(+'') { |sequence, active| track_sgr(active, sequence) }
    end

    def track_sgr(active, sequence)
      if ["\e[0m", "\e[m"].include?(sequence)
        active.clear
      else
        active << sequence
      end
    end

    def close(row, active)
      active.empty? ? row : "#{row}#{RESET}"
    end
  end
end
