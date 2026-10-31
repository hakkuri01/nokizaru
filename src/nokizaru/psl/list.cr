require "../psl"

module Nokizaru::PSL
  # Hand-rolled Public Suffix List matcher over the embedded list, replacing the
  # public_suffix gem. The list is parsed once into a rule table keyed by
  # suffix string; a lookup then finds the public suffix of a host by the
  # publicsuffix.org algorithm: an exception rule (`!foo.bar`) wins, else the
  # matching rule with the most labels, and a wildcard label (`*`) matches any
  # one label. No matching rule falls back to the implicit `*` (the rightmost
  # label).
  class List
    enum Rule
      Normal
      Wildcard
      Exception
    end

    # RFC 1035: a hostname holds at most 253 octets. Hosts arrive from server
    # data (crawled links, redirect targets), so the bound is enforced here
    # rather than assumed: it keeps the label count under 128, which is what
    # makes the suffix walk below cheap.
    MAX_HOST_BYTES = 253

    @@default : List?

    # Shared instance over the embedded list, parsed once off the hot path.
    def self.default : List
      @@default ||= new(PSL::DATA)
    end

    def initialize(data : String = PSL::DATA)
      @rules = {} of String => Rule
      parse(data)
    end

    def rule_count : Int32
      @rules.size
    end

    # The public suffix (eTLD) of a host, e.g. "co.uk" for "www.example.co.uk".
    # Returns nil for an empty host.
    def public_suffix(host : String) : String?
      labels = normalize_labels(host)
      return nil if labels.empty?

      suffix_labels(labels).join(".")
    end

    # The registrable domain (eTLD+1), e.g. "example.co.uk". Returns nil when the
    # host is itself a public suffix (no registrable part) or is empty.
    def registrable_domain(host : String) : String?
      labels = normalize_labels(host)
      return nil if labels.empty?

      suffix = suffix_labels(labels)
      return nil if labels.size <= suffix.size

      labels[(labels.size - suffix.size - 1)..].join(".")
    end

    private def normalize_labels(host : String) : Array(String)
      value = host.strip.downcase
      value = value[0...-1] if value.ends_with?('.')
      return [] of String if value.empty? || value.bytesize > MAX_HOST_BYTES

      value.split('.')
    end

    # Labels of the prevailing rule's public suffix. Each step is an O(1) Hash
    # lookup but builds its candidate key, so the walk is O(L squared) in the
    # label count; MAX_HOST_BYTES caps L at 127, which keeps it a few hundred
    # byte copies per host.
    private def suffix_labels(labels : Array(String)) : Array(String)
      best : Array(String)? = nil
      best_size = -1
      best_exception = false
      labels.size.times do |i|
        candidate = labels[i..]
        type = @rules[candidate.join(".")]? || @rules[wildcard_key(labels, i)]?
        next if type.nil?

        exception = type.exception?
        wins = exception == best_exception ? candidate.size > best_size : exception
        next unless wins

        best = exception ? candidate[1..] : candidate
        best_size = candidate.size
        best_exception = exception
      end
      best || [labels[-1]]
    end

    private def wildcard_key(labels : Array(String), index : Int32) : String
      (["*"] + labels[(index + 1)..]).join(".")
    end

    private def parse(data : String) : Nil
      data.each_line do |line|
        rule = line.strip
        next if rule.empty? || rule.starts_with?("//")

        if rule.starts_with?('!')
          @rules[rule[1..].downcase] = Rule::Exception
        elsif rule.includes?('*')
          @rules[rule.downcase] = Rule::Wildcard
        else
          @rules[rule.downcase] = Rule::Normal
        end
      end
    end
  end
end
