require "./spec_helper"
require "../src/nokizaru/terminal_text"

# Count-based complexity pins for the "text from outside" path (AGENTS Big O,
# rule 9). sanitize, width, and normal-density wrap must stay linear in input
# length. Allocated bytes are the deterministic count: quadrupling the input
# quadruples a linear path's allocation and sixteen-folds a quadratic one.
# Measured ratios sit near 4.0; the 8.0 bound rejects a quadratic without the
# flakiness of a wall-clock timing.
private def alloc_bytes(&) : Int64
  GC.collect
  before = GC.stats.total_bytes
  yield
  (GC.stats.total_bytes - before).to_i64
end

describe Nokizaru::TerminalText do
  it "sanitizes untrusted text in linear allocation (one pass, no quadratic)" do
    unit = "hello \e[31mworld\e[0m \a\e]0;title\a ok\n"
    small = unit * 2000
    large = unit * 8000
    Nokizaru::TerminalText.sanitize(small)
    base = alloc_bytes { Nokizaru::TerminalText.sanitize(small) }
    quad = alloc_bytes { Nokizaru::TerminalText.sanitize(large) }

    base.should be > 10_000
    (quad.to_f / base).should be < 8.0
  end

  it "measures the width of non-ASCII text in linear allocation" do
    unit = "café 日本語 \e[31mx\e[0m ★ foo "
    small = unit * 2000
    large = unit * 8000
    Nokizaru::TerminalText.width(small)
    base = alloc_bytes { Nokizaru::TerminalText.width(small) }
    quad = alloc_bytes { Nokizaru::TerminalText.width(large) }

    base.should be > 10_000
    (quad.to_f / base).should be < 8.0
  end

  it "wraps normal-density colored lines in linear allocation" do
    unit = "x" * 20 + "\e[31m" + "y" * 20 + "\e[0m "
    small = unit * 1000
    large = unit * 4000
    Nokizaru::TerminalText.wrap(small, 40)
    base = alloc_bytes { Nokizaru::TerminalText.wrap(small, 40) }
    quad = alloc_bytes { Nokizaru::TerminalText.wrap(large, 40) }

    base.should be > 10_000
    (quad.to_f / base).should be < 8.0
  end
end
