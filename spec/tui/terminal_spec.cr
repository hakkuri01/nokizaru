require "../spec_helper"
require "../../src/nokizaru/tui/terminal"

private alias Terminal = Nokizaru::Tui::Terminal

{% if flag?(:darwin) %}
  # openpty creates a pty pair with a known window size, so the real size path
  # can be exercised without a controlling terminal. Fixed-signature, declared
  # with its real parameters.
  lib LibPty
    struct Winsize
      row : UInt16
      col : UInt16
      xpixel : UInt16
      ypixel : UInt16
    end

    fun openpty(amaster : Int32*, aslave : Int32*, name : UInt8*, termp : Void*, winp : Winsize*) : Int32
  end
{% end %}

describe Nokizaru::Tui::Terminal do
  it "reports a fallback size when the output is not a tty" do
    input_r, input_w = IO.pipe
    output_r, output_w = IO.pipe
    Terminal.new(input_r, output_w).size.should eq({80, 24})
    {input_r, input_w, output_r, output_w}.each(&.close)
  end

  it "enters and leaves the alternate screen around a session" do
    input_r, input_w = IO.pipe
    output_r, output_w = IO.pipe
    term = Terminal.new(input_r, output_w)
    term.open
    term.close
    output_w.close
    output = output_r.gets_to_end
    output.should contain("\e[?1049h") # enter alternate screen
    output.should contain("\e[?1049l") # leave alternate screen
    {input_r, input_w, output_r}.each(&.close)
  end

  it "skips the leave sequence when it was never opened" do
    input_r, input_w = IO.pipe
    output_r, output_w = IO.pipe
    Terminal.new(input_r, output_w).close
    output_w.close
    output_r.gets_to_end.should be_empty
    {input_r, input_w, output_r}.each(&.close)
  end

  {% if flag?(:darwin) %}
    # Regression (arm64): the winsize ioctl must be declared variadic, or on
    # Apple silicon the struct pointer lands in the wrong register and the call
    # fills nothing, collapsing every launch to the 80x24 fallback. A pty opened
    # at 120x40 must read back as 120x40, not the fallback.
    it "reads the real window size from a pty via the variadic ioctl" do
      master = 0
      slave = 0
      ws = LibPty::Winsize.new
      ws.row = 40_u16
      ws.col = 120_u16
      LibPty.openpty(pointerof(master), pointerof(slave), Pointer(UInt8).null, Pointer(Void).null, pointerof(ws)).should eq(0)

      master_io = IO::FileDescriptor.new(master)
      slave_io = IO::FileDescriptor.new(slave)
      begin
        Terminal.new(slave_io, slave_io).size.should eq({120, 40})
      ensure
        slave_io.close
        master_io.close
      end
    end
  {% end %}
end
