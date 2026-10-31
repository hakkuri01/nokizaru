require "./terminal_text"

module Nokizaru
  # The output surface. Every module writes through here, to an injected sink
  # (`output`), so the interactive dashboard can capture module output by swapping
  # the sink instead of reassigning the process streams. Values often come from
  # the target, so only their SGR color survives (see TerminalText.sanitize).
  module UI
    extend self

    R = "\e[31m"
    G = "\e[32m"
    C = "\e[36m"
    W = "\e[0m"
    Y = "\e[33m"
    M = "\e[35m"

    enum Kind
      Plus
      Info
      Error
    end

    SYMBOLS = {Kind::Plus => "⟦+⟧", Kind::Info => "⟦!⟧", Kind::Error => "⟦✘⟧"}
    COLORS  = {Kind::Plus => G, Kind::Info => Y, Kind::Error => R}

    @@output : IO = STDOUT
    @@tui_mode = false

    def output : IO
      @@output
    end

    def output=(io : IO) : IO
      @@output = io
    end

    # The dashboard names each module on its tab and scaffold, so the per-module
    # header bar is dropped there.
    def tui_mode? : Bool
      @@tui_mode
    end

    def tui_mode=(value : Bool) : Bool
      @@tui_mode = value
    end

    def section(title : String, kind : Kind = :plus) : Nil
      output.puts
      output.puts("#{prefix(kind)} #{C}#{safe(title)}#{W}")
      output.puts
    end

    def module_header(title : String, kind : Kind = :plus) : Nil
      return if tui_mode?

      text = safe(title).strip
      width = {text.size + 6, 40}.max
      bar = "─" * width
      output.puts
      output.puts("#{R}#{bar}#{W}")
      output.puts("#{prefix(kind)} #{R}#{text}#{W}")
      output.puts("#{R}#{bar}#{W}")
    end

    def line(kind : Kind, text : String) : Nil
      output.puts("#{prefix(kind)} #{W}#{safe(text)}#{W}")
    end

    def blank_line : Nil
      output.puts
    end

    def row(kind : Kind, label : String, value : String?, label_width : Int32 = 0, min_dots : Int32 = 3) : Nil
      output.puts(formatted_row(kind, label, value, label_width, min_dots))
    end

    def formatted_row(kind : Kind, label : String, value : String?, label_width : Int32 = 0, min_dots : Int32 = 3) : String
      label_text = safe(label)
      value_text = normalized_value_text(value)
      width = {label_width, label_text.size}.max
      dots = "." * {min_dots, width - label_text.size + min_dots}.max
      "#{prefix(kind)} #{W}#{label_text}#{dots}#{W}⟦ #{C}#{value_text}#{W} ⟧"
    end

    def normalized_value_text(value : String?) : String
      return "-" if value.nil?

      text = safe(value)
      text.strip.empty? ? "-" : text
    end

    def rows(kind : Kind, pairs : Array(Tuple(String, String?)), min_dots : Int32 = 3) : Nil
      width = pairs.max_of?(&.[0].size) || 0
      pairs.each do |(label, value)|
        output.puts(formatted_row(kind, label, value, width, min_dots))
      end
    end

    # Plain string pairs, so a caller whose values are never nil does not widen
    # every tuple at the call site. The cast is the whole point of the overload:
    # a Tuple(String, String) is not a Tuple(String, String?).
    def rows(kind : Kind, pairs : Array(Tuple(String, String)), min_dots : Int32 = 3) : Nil
      rows(kind, pairs.map { |(label, value)| {label, value.as(String?)} }, min_dots)
    end

    def tree_header(label : String) : Nil
      output.puts("#{prefix(:info)} #{W}#{safe(label)}#{W}")
    end

    def tree_rows(pairs : Array(Tuple(String, String?)), min_dots : Int32 = 3) : Nil
      width = pairs.max_of?(&.[0].size) || 0
      pairs.each_with_index do |pair, idx|
        output.puts(format_tree_row(pair, idx, pairs.size, width, min_dots))
      end
    end

    # The same convenience as `rows` for callers with plain string values.
    def tree_rows(pairs : Array(Tuple(String, String)), min_dots : Int32 = 3) : Nil
      tree_rows(pairs.map { |(label, value)| {label, value.as(String?)} }, min_dots)
    end

    def format_tree_row(pair : Tuple(String, String?), idx : Int32, total : Int32, width : Int32, min_dots : Int32) : String
      label, value = pair
      branch = idx == total - 1 ? "└─◈" : "├─◈"
      label_text = safe(label)
      dots = "." * {min_dots, width - label_text.size + min_dots}.max
      value_text = normalized_value_text(value)
      " #{branch} #{W}#{label_text}#{dots}#{W}⟦ #{C}#{value_text}#{W} ⟧"
    end

    def prefix(kind : Kind) : String
      "#{COLORS[kind]}#{SYMBOLS[kind]}#{W}"
    end

    def safe(text : String) : String
      TerminalText.sanitize(text)
    end
  end
end
