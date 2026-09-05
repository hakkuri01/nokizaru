# frozen_string_literal: true

module Nokizaru
  # In-memory scan context shared across modules unless explicitly exported
  class Context
    attr_reader :run, :options
    attr_accessor :progress

    def initialize(run:, options:, progress: nil)
      @run = run
      @options = options
      @progress = progress

      @run['modules'] ||= {}
      @run['artifacts'] ||= {}
      @run['findings'] ||= []
    end

    def add_artifact(kind, values)
      kind = kind.to_s
      return if values.nil?

      existing = @run['artifacts'][kind] ||= []
      additions = Array(values).compact
      return if additions.empty?

      seen = existing.to_set
      additions.each { |value| existing << value if seen.add?(value) }
    end
  end
end
