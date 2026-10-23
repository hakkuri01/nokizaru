require "../spec_helper"
require "../../src/nokizaru/tui/decoder"

private def names(messages)
  messages.map(&.name)
end

describe Nokizaru::Tui::Decoder do
  describe "#feed" do
    it "decodes plain printable characters one per byte" do
      decoder = Nokizaru::Tui::Decoder.new
      names(decoder.feed("abc".to_slice)).should eq(["a", "b", "c"])
    end

    it "maps named control bytes" do
      decoder = Nokizaru::Tui::Decoder.new
      names(decoder.feed(Bytes[3])).should eq(["ctrl+c"])
      names(decoder.feed(Bytes[9])).should eq(["tab"])
      names(decoder.feed(Bytes[13])).should eq(["enter"])
      names(decoder.feed(Bytes[10])).should eq(["enter"])
      names(decoder.feed(Bytes[127])).should eq(["backspace"])
      names(decoder.feed(Bytes[8])).should eq(["backspace"])
    end

    it "derives an unlisted control byte from its letter" do
      decoder = Nokizaru::Tui::Decoder.new
      names(decoder.feed(Bytes[1])).should eq(["ctrl+a"])
      names(decoder.feed(Bytes[21])).should eq(["ctrl+u"])
    end

    it "decodes CSI arrow and navigation finals" do
      decoder = Nokizaru::Tui::Decoder.new
      names(decoder.feed("\e[A".to_slice)).should eq(["up"])
      names(decoder.feed("\e[B".to_slice)).should eq(["down"])
      names(decoder.feed("\e[C".to_slice)).should eq(["right"])
      names(decoder.feed("\e[D".to_slice)).should eq(["left"])
      names(decoder.feed("\e[H".to_slice)).should eq(["home"])
      names(decoder.feed("\e[F".to_slice)).should eq(["end"])
      names(decoder.feed("\e[Z".to_slice)).should eq(["shift+tab"])
    end

    it "decodes tilde sequences, including ones with modifier parameters" do
      decoder = Nokizaru::Tui::Decoder.new
      names(decoder.feed("\e[3~".to_slice)).should eq(["delete"])
      names(decoder.feed("\e[5~".to_slice)).should eq(["pgup"])
      names(decoder.feed("\e[6~".to_slice)).should eq(["pgdn"])
      names(decoder.feed("\e[1;2~".to_slice)).should eq(["home"])
    end

    it "decodes SS3 sequences as the matching CSI key" do
      decoder = Nokizaru::Tui::Decoder.new
      names(decoder.feed("\eOA".to_slice)).should eq(["up"])
    end

    it "treats ESC before a non-introducer as a standalone key, then the char" do
      decoder = Nokizaru::Tui::Decoder.new
      names(decoder.feed("\ej".to_slice)).should eq(["esc", "j"])
    end

    it "holds an escape sequence split across reads" do
      decoder = Nokizaru::Tui::Decoder.new
      decoder.feed("\e".to_slice).should be_empty
      decoder.pending?.should be_true
      names(decoder.feed("[A".to_slice)).should eq(["up"])
      decoder.pending?.should be_false
    end

    it "holds a multibyte character split across reads" do
      decoder = Nokizaru::Tui::Decoder.new
      decoder.feed(Bytes[0xC3]).should be_empty
      names(decoder.feed(Bytes[0xA9])).should eq(["é"])
    end

    it "drops an invalid UTF-8 byte but still advances" do
      decoder = Nokizaru::Tui::Decoder.new
      names(decoder.feed(Bytes[0xFF, 0x61])).should eq(["a"])
    end

    it "drops an overlong incomplete CSI sequence" do
      decoder = Nokizaru::Tui::Decoder.new
      junk = Bytes.new(40, 0x3B_u8) # ';' params, never closed
      decoder.feed("\e[".to_slice).should be_empty
      decoder.feed(junk).should be_empty
      decoder.pending?.should be_false
    end
  end

  describe "#flush" do
    it "emits a lone pending ESC as the esc key" do
      decoder = Nokizaru::Tui::Decoder.new
      decoder.feed("\e".to_slice)
      names(decoder.flush).should eq(["esc"])
      decoder.pending?.should be_false
    end

    it "drops a partial sequence that is not a lone ESC" do
      decoder = Nokizaru::Tui::Decoder.new
      decoder.feed("\e[".to_slice)
      decoder.flush.should be_empty
    end
  end
end
