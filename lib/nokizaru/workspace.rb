# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'securerandom'
require 'set'
require 'tempfile'
require 'time'

begin
  require 'ronin/db'
rescue LoadError
  # Ronin-db is optional, but recommended for workspace DB enrichment
end

require_relative 'paths'
require_relative 'log'
require_relative 'workspace/persistence'
require_relative 'workspace/db_output_silencer'
require_relative 'workspace/db_port_records'
require_relative 'workspace/db_records'
require_relative 'workspace/db_support'

module Nokizaru
  # File-backed workspace and optional Ronin::DB integration
  class Workspace
    include Persistence
    include DBSupport

    attr_reader :project_name, :target_host, :base_dir, :last_db_error

    def initialize(project_name, target_host)
      @project_name = sanitize(project_name)
      @target_host = sanitize(target_host)
      @last_db_error = nil
      @db_migrated = false
      @base_dir = File.join(Paths.workspace_dir, @project_name, @target_host)
      FileUtils.mkdir_p(@base_dir)
      FileUtils.mkdir_p(runs_dir)
      FileUtils.mkdir_p(cache_dir)
    end

    def runs_dir
      File.join(@base_dir, 'runs')
    end

    def cache_dir
      File.join(@base_dir, 'cache')
    end

    def db_path
      File.join(@base_dir, 'ronin.db')
    end

    def db_uri
      "sqlite3:#{db_path}"
    end

    def self.diff_snapshots(old_snap, new_snap)
      old_map = normalize_snapshot(old_snap)
      new_map = normalize_snapshot(new_snap)
      kinds = old_map.keys | new_map.keys
      kinds.each_with_object({}) do |kind, diff|
        snapshot_delta!(diff, kind, old_map[kind], new_map[kind])
      end
    end

    def self.normalize_snapshot(snapshot)
      snapshot.is_a?(Hash) ? snapshot : {}
    end

    def self.snapshot_delta!(diff, kind, old_values, new_values)
      old_set = Set.new(Array(old_values))
      new_set = Set.new(Array(new_values))
      added = (new_set - old_set).to_a
      removed = (old_set - new_set).to_a
      return if added.empty? && removed.empty?

      diff[kind] = { 'added' => added.sort, 'removed' => removed.sort }
    end

    private_class_method :normalize_snapshot, :snapshot_delta!

    private

    def sanitize(value)
      value.to_s.strip.gsub(%r{[\s/\\]+}, '_').gsub(/[^a-zA-Z0-9_.-]/, '_')
    end
  end
end
