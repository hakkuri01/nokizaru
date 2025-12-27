# frozen_string_literal: true

require 'set'

module Nokizaru
  # Shared context passed through modules during a scan.
  #
  # Ethos: default to ephemeral runs (stdout) while enabling optional
  # persistence/export when the user asks for it.
  class Context
    attr_reader :run, :options, :workspace, :cache

    def initialize(run:, options:, workspace: nil, cache: nil)
      @run = run
      @options = options
      @workspace = workspace
      @cache = cache

      @run['modules'] ||= {}
      @run['artifacts'] ||= {}
      @run['findings'] ||= []
    end

    def add_artifact(kind, values)
      kind = kind.to_s
      @run['artifacts'][kind] ||= []
      return if values.nil?

      arr = Array(values).compact
      return if arr.empty?

      # Keep stable order but remove duplicates.
      existing = @run['artifacts'][kind]
      seen = existing.to_set
      arr.each do |v|
        next if v.nil?
        next if seen.include?(v)

        existing << v
        seen.add(v)
      end
    end

    def cache_fetch(key, ttl_s: 3600, &block)
      return yield unless @cache

      @cache.fetch(key, ttl_s: ttl_s, &block)
    end
  end
end
