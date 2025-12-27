# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'securerandom'
require 'set'
require 'time'

begin
  require 'ronin/db'
rescue LoadError
  # ronin-db is optional, but recommended for workspace DB enrichment.
end

require_relative 'paths'
require_relative 'log'

module Nokizaru
  # File-based workspace + optional Ronin::DB sqlite database co-located in the workspace.
  #
  # When enabled, it supports:
  # - run directories (results.json, exports)
  # - caching directory
  # - Ronin::DB database (ronin.db)
  # - db snapshots + db diffing (diff_db)
  class Workspace
    attr_reader :project_name, :target_host, :base_dir

    def initialize(project_name, target_host)
      @project_name = sanitize(project_name)
      @target_host  = sanitize(target_host)

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

    def start_run(meta = {})
      run_id = "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}_#{SecureRandom.hex(4)}"
      dir = run_dir(run_id)
      FileUtils.mkdir_p(dir)

      meta = (meta || {}).dup
      meta['run_id'] = run_id

      File.write(File.join(dir, 'meta.json'), JSON.pretty_generate(meta))
      [run_id, dir]
    end

    def run_dir(run_id)
      File.join(runs_dir, run_id.to_s)
    end

    def results_path(run_id)
      File.join(run_dir(run_id), 'results.json')
    end

    def save_run(run_id, run_hash)
      FileUtils.mkdir_p(run_dir(run_id))
      File.write(results_path(run_id), JSON.pretty_generate(run_hash))
      true
    end

    def load_run(run_id)
      JSON.parse(File.read(results_path(run_id)))
    end

    def run_ids
      return [] unless Dir.exist?(runs_dir)

      Dir.children(runs_dir).select { |n| File.directory?(File.join(runs_dir, n)) }.sort
    end

    def previous_run_id(current_run_id = nil)
      ids = run_ids
      return nil if ids.empty?

      if current_run_id && ids.include?(current_run_id.to_s)
        idx = ids.index(current_run_id.to_s)
        return nil if idx.nil? || idx.zero?

        ids[idx - 1]
      else
        ids[-2] # previous to last
      end
    end

    # Ronin::DB integration

    def db_available?
      defined?(Ronin::DB)
    end

    def connect_db!(migrate: true)
      return false unless db_available?

      with_quiet_db_output do
        Ronin::DB.connect(db_uri, migrate: migrate)
      end

      true
    rescue StandardError => e
      Log.write("[workspace.db] connect failed: #{e.class}: #{e}")
      false
    end

    # Inserts a conservative subset of run outputs into Ronin::DB.
    def ingest_run!(run_hash)
      return false unless connect_db!(migrate: true)

      run = run_hash || {}
      meta = run['meta'] || {}
      artifacts = run['artifacts'] || {}
      modules = run['modules'] || {}

      host = meta['hostname'].to_s.strip
      ip   = meta['ip'].to_s.strip

      import_hostname(host) unless host.empty?
      ip_obj = import_ip(ip) unless ip.empty?

      Array(artifacts['subdomains']).each { |h| import_hostname(h) }

      (Array(artifacts['urls']) + Array(artifacts['wayback_urls'])).each { |u| import_url(u) }

      crawler = modules['crawler']
      if crawler.is_a?(Hash)
        Array(crawler['internal_links']).each { |u| import_url(u) }
        Array(crawler['external_links']).each { |u| import_url(u) }
      end

      Array(artifacts['open_ports']).each do |p|
        next unless ip_obj

        port_num = begin
          Integer(p)
        rescue StandardError
          nil
        end
        next unless port_num

        import_open_port(ip_obj, port_num)
      end

      true
    rescue StandardError => e
      Log.write("[workspace.db] ingest failed: #{e.class}: #{e}")
      false
    end

    # Snapshot DB state for diffing.
    def db_snapshot
      return {} unless connect_db!(migrate: false)

      snap = {}

      snap['hostnames'] = Ronin::DB::HostName.pluck(:name).sort if defined?(Ronin::DB::HostName)
      snap['ip_addresses'] = Ronin::DB::IPAddress.pluck(:address).sort if defined?(Ronin::DB::IPAddress)

      snap['urls'] = Ronin::DB::URL.all.map(&:to_s).uniq.sort if defined?(Ronin::DB::URL)

      if defined?(Ronin::DB::OpenPort)
        snap['open_ports'] = Ronin::DB::OpenPort.all.map(&:number).compact.map(&:to_i).uniq.sort
      end

      snap
    rescue StandardError => e
      Log.write("[workspace.db] snapshot failed: #{e.class}: #{e}")
      {}
    end

    def self.diff_snapshots(old_snap, new_snap)
      old_snap = old_snap.is_a?(Hash) ? old_snap : {}
      new_snap = new_snap.is_a?(Hash) ? new_snap : {}

      diff = {}

      (old_snap.keys | new_snap.keys).each do |kind|
        old_set = Set.new(Array(old_snap[kind]))
        new_set = Set.new(Array(new_snap[kind]))

        added = (new_set - old_set).to_a
        removed = (old_set - new_set).to_a

        next if added.empty? && removed.empty?

        diff[kind] = { 'added' => added.sort, 'removed' => removed.sort }
      end

      diff
    end

    private

    def sanitize(s)
      s.to_s.strip.gsub(%r{[\s/\\]+}, '_').gsub(/[^a-zA-Z0-9_.-]/, '_')
    end

    def import_hostname(hostname)
      h = hostname.to_s.strip
      return if h.empty?
      return unless defined?(Ronin::DB::HostName)

      Ronin::DB::HostName.find_or_create_by(name: h)
    end

    def import_ip(ip_str)
      ip = ip_str.to_s.strip
      return nil if ip.empty?
      return nil unless defined?(Ronin::DB::IPAddress)

      Ronin::DB::IPAddress.find_or_create_by(address: ip)
    end

    def import_url(url_str)
      u = url_str.to_s.strip
      return if u.empty?
      return unless defined?(Ronin::DB::URL)

      # Use import helper if present; otherwise skip (don’t guess schema).
      Ronin::DB::URL.find_or_import(u) if Ronin::DB::URL.respond_to?(:find_or_import)
    rescue StandardError
      nil
    end

    def with_quiet_db_output
      # Allow opt-in verbose mode for debugging:
      # NOKIZARU_DB_VERBOSE=1 bundle exec nokizaru ...
      return yield if ENV['NOKIZARU_DB_VERBOSE'] == '1'

      require 'stringio'

      old_stdout = $stdout
      old_stderr = $stderr
      $stdout = StringIO.new
      $stderr = StringIO.new

      # Also try to quiet ActiveRecord/ActiveSupport if loaded.
      old_migration_verbose = nil
      old_ar_logger = nil
      old_depr_silenced = nil
      old_depr_behavior = nil

      begin
        if defined?(ActiveRecord::Migration)
          old_migration_verbose = ActiveRecord::Migration.verbose
          ActiveRecord::Migration.verbose = false
        end

        if defined?(ActiveRecord::Base)
          old_ar_logger = ActiveRecord::Base.logger
          ActiveRecord::Base.logger = nil
        end

        if defined?(ActiveSupport::Deprecation)
          old_depr_silenced = ActiveSupport::Deprecation.silenced
          old_depr_behavior = ActiveSupport::Deprecation.behavior
          ActiveSupport::Deprecation.silenced = true
          ActiveSupport::Deprecation.behavior = :silence
        end

        yield
      ensure
        if defined?(ActiveSupport::Deprecation)
          ActiveSupport::Deprecation.silenced = old_depr_silenced unless old_depr_silenced.nil?
          ActiveSupport::Deprecation.behavior = old_depr_behavior unless old_depr_behavior.nil?
        end

        ActiveRecord::Base.logger = old_ar_logger if defined?(ActiveRecord::Base) && !old_ar_logger.nil?

        if defined?(ActiveRecord::Migration) && !old_migration_verbose.nil?
          ActiveRecord::Migration.verbose = old_migration_verbose
        end

        $stdout = old_stdout
        $stderr = old_stderr
      end
    end

    def import_open_port(ip_obj, port_num)
      return unless defined?(Ronin::DB::Port) && defined?(Ronin::DB::OpenPort)

      port =
        if Ronin::DB::Port.respond_to?(:find_or_import)
          Ronin::DB::Port.find_or_import(:tcp, port_num)
        else
          Ronin::DB::Port.find_or_create_by(protocol: 'tcp', number: port_num)
        end

      Ronin::DB::OpenPort.find_or_create_by(ip_address: ip_obj, port: port)
    end
  end
end
