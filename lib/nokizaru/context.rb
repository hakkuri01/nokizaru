# frozen_string_literal: true

require 'set'

module Nokizaru
  # Shared context passed through modules during a scan
  # Explain this block so future maintainers understand its intent
  # Ethos: default to ephemeral runs (stdout) while enabling optional
  # Persistence/export when the user asks for it
  class Context
    attr_reader :run, :options, :workspace, :cache

    # Capture runtime options and prepare shared state used by this object
    def initialize(run:, options:, workspace: nil, cache: nil)
      @run = run
      @options = options
      @workspace = workspace
      @cache = cache

      @run['modules'] ||= {}
      @run['artifacts'] ||= {}
      @run['findings'] ||= []
    end

    # Add normalized artifacts to the run for export and diffing
    def add_artifact(kind, values)
      kind = kind.to_s
      return if values.nil?

      existing = @run['artifacts'][kind] ||= []
      additions = Array(values).compact
      return if additions.empty?

      seen = existing.to_set
      append_missing(existing, additions, seen)
    end

    def append_missing(existing, additions, seen)
      additions.each do |value|
        next if seen.include?(value)

        existing << value
        seen.add(value)
      end
    end

    private :append_missing

    # Read from cache first and compute values only on cache miss
    def cache_fetch(key, ttl_s: 3600, &block)
      return yield unless @cache

      @cache.fetch(key, ttl_s: ttl_s, &block)
    end
  end
end
