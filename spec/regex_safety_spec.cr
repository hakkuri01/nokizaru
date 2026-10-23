require "./spec_helper"

# Most patterns in src/ run on text from a target or a provider, so every regex
# must match in linear time (AGENTS.md, Algorithmic Complexity rule 5). PCRE2
# gives no linear-time guarantee, so the backtracking-prone constructs,
# lookaround and named/subroutine references, are banned from src/ outright and
# this spec walks the source to enforce it. The check is deliberately
# conservative: it forbids these tokens anywhere in src/, which keeps every regex
# linear and is simpler than parsing out each literal. Numeric backreferences are
# forbidden by convention (use the block form of gsub, never a backreference
# replacement string).
describe "regex safety" do
  it "has no backtracking-prone regex constructs in src/" do
    forbidden = {
      "(?="  => "positive lookahead",
      "(?!"  => "negative lookahead",
      "(?<=" => "positive lookbehind",
      "(?<!" => "negative lookbehind",
      "\\k<" => "named backreference",
      "\\g<" => "subroutine reference",
    }

    files = Dir.glob(File.join(__DIR__, "..", "src", "**", "*.cr"))
    files.should_not be_empty

    offenders = [] of String
    files.each do |path|
      File.read(path).each_line.each_with_index(1) do |line, number|
        forbidden.each do |token, name|
          offenders << "#{path}:#{number} #{name} (#{token})" if line.includes?(token)
        end
      end
    end

    offenders.should be_empty
  end
end
