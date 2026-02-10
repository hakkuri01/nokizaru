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

module Nokizaru
  # File-based workspace + optional Ronin::DB sqlite database co-located in the workspace
  # Explain this block so future maintainers understand its intent
  # When enabled, it supports:
  # Run directories (results.json, exports)
  # Caching directory
  # Ronin::DB database (ronin.db)
  # Db snapshots + db diffing (diff_db)
  class Workspace
    attr_reader :project_name, :target_host, :base_dir, :last_db_error

    # Capture runtime options and prepare shared state used by this object
    def initialize(project_name, target_host)
      @project_name = sanitize(project_name)
      @target_host  = sanitize(target_host)
      @last_db_error = nil
      @db_migrated = false

      @base_dir = File.join(Paths.workspace_dir, @project_name, @target_host)
      FileUtils.mkdir_p(@base_dir)
      FileUtils.mkdir_p(runs_dir)
      FileUtils.mkdir_p(cache_dir)
    end

    # Resolve the runs directory for this workspace
    def runs_dir
      File.join(@base_dir, 'runs')
    end

    # Resolve the cache directory used by workspace scoped caching
    def cache_dir
      File.join(@base_dir, 'cache')
    end

    # Resolve the workspace database path under the project directory
    def db_path
      File.join(@base_dir, 'ronin.db')
    end

    # Build a database URI string for tooling and diagnostics
    def db_uri
      "sqlite3:#{db_path}"
    end

    # Create run directory structure and initialize metadata for this execution
    def start_run(meta = {})
      run_id = "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}_#{SecureRandom.hex(4)}"
      dir = run_dir(run_id)
      FileUtils.mkdir_p(dir)

      meta = (meta || {}).dup
      meta['run_id'] = run_id

      write_json_atomic(File.join(dir, 'meta.json'), meta)
      [run_id, dir]
    end

    # Resolve run directory path for a specific run identifier
    def run_dir(run_id)
      File.join(runs_dir, run_id.to_s)
    end

    # Resolve results file path for a specific run identifier
    def results_path(run_id)
      File.join(run_dir(run_id), 'results.json')
    end

    # Persist final run output atomically to avoid partial result files
    def save_run(run_id, run_hash)
      FileUtils.mkdir_p(run_dir(run_id))
      write_json_atomic(results_path(run_id), run_hash)
      true
    end

    # Load a prior run result for diffing and historical comparisons
    def load_run(run_id)
      JSON.parse(File.read(results_path(run_id)))
    end

    # List known run identifiers in deterministic order for stable diffs
    def run_ids
      return [] unless Dir.exist?(runs_dir)

      Dir.children(runs_dir).select { |n| File.directory?(File.join(runs_dir, n)) }.sort
    end

    # Resolve the prior run identifier used by default diff behavior
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

    # Establish workspace database connectivity with graceful degradation
    def connect_db!(migrate: true)
      unless db_available?
        @last_db_error = 'ronin-db is unavailable'
        return false
      end

      return true if connected_to_workspace_db?

      migrate_now = migrate && !@db_migrated

      with_quiet_db_output do
        Ronin::DB.connect(db_connect_config, migrate: migrate_now)
      end

      @db_migrated ||= migrate_now
      @last_db_error = nil
      true
    rescue StandardError => e
      @last_db_error = "#{e.class}: #{e.message}"
      Log.write("[workspace.db] connect failed: #{e.class}: #{e}")
      Log.write("[workspace.db] first backtrace: #{e.backtrace&.first}") if e.backtrace&.first
      false
    end

    # Inserts a conservative subset of run outputs into Ronin::DB
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

      @last_db_error = nil
      true
    rescue StandardError => e
      @last_db_error = "#{e.class}: #{e.message}"
      Log.write("[workspace.db] ingest failed: #{e.class}: #{e}")
      false
    end

    # Snapshot DB state for diffing
    def db_snapshot
      return {} unless connect_db!(migrate: false)

      snap = {}

      snap['hostnames'] = Ronin::DB::HostName.pluck(:name).sort if defined?(Ronin::DB::HostName)
      snap['ip_addresses'] = Ronin::DB::IPAddress.pluck(:address).sort if defined?(Ronin::DB::IPAddress)

      snap['urls'] = Ronin::DB::URL.all.map(&:to_s).uniq.sort if defined?(Ronin::DB::URL)

      if defined?(Ronin::DB::OpenPort)
        snap['open_ports'] = Ronin::DB::OpenPort.all.filter_map do |op|
          number = op.respond_to?(:number) ? op.number : nil
          next unless number

          ip_str = begin
            ip_obj = op.respond_to?(:ip_address) ? op.ip_address : nil
            ip_obj&.respond_to?(:address) ? ip_obj.address.to_s : nil
          rescue StandardError
            nil
          end

          if ip_str && !ip_str.empty?
            "#{ip_str}:#{number.to_i}"
          else
            number.to_i.to_s
          end
        end.uniq.sort
      end

      @last_db_error = nil
      snap
    rescue StandardError => e
      @last_db_error = "#{e.class}: #{e.message}"
      Log.write("[workspace.db] snapshot failed: #{e.class}: #{e}")
      {}
    end

    # Diff database snapshots by collection to highlight ingest changes
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

    # Sanitize values before database ingestion to avoid malformed records
    def sanitize(s)
      s.to_s.strip.gsub(%r{[\s/\\]+}, '_').gsub(/[^a-zA-Z0-9_.-]/, '_')
    end

    # Build database connection options from runtime environment and defaults
    def db_connect_config
      {
        adapter: 'sqlite3',
        database: db_path
      }
    end

    # Report workspace database connectivity state for diagnostics
    def connected_to_workspace_db?
      return false unless db_connected?
      return true unless defined?(ActiveRecord::Base)

      cfg = (ActiveRecord::Base.connection_db_config if ActiveRecord::Base.respond_to?(:connection_db_config))
      return true unless cfg && cfg.respond_to?(:database)

      File.expand_path(cfg.database.to_s) == File.expand_path(db_path)
    rescue StandardError
      false
    end

    # Return whether the database client is currently connected
    def db_connected?
      return false unless defined?(ActiveRecord::Base)

      return ActiveRecord::Base.connected? if ActiveRecord::Base.respond_to?(:connected?)

      ActiveRecord::Base.connection
      true
    rescue StandardError
      false
    end

    # Import hostname artifacts into the workspace database when available
    def import_hostname(hostname)
      h = hostname.to_s.strip
      return if h.empty?
      return unless defined?(Ronin::DB::HostName)

      Ronin::DB::HostName.find_or_create_by(name: h)
    end

    # Import IP artifacts into the workspace database when available
    def import_ip(ip_str)
      ip = ip_str.to_s.strip
      return nil if ip.empty?
      return nil unless defined?(Ronin::DB::IPAddress)

      Ronin::DB::IPAddress.find_or_create_by(address: ip)
    end

    # Import URL artifacts into the workspace database when available
    def import_url(url_str)
      u = url_str.to_s.strip
      return if u.empty?
      return unless defined?(Ronin::DB::URL)

      # Use import helper if present; otherwise skip (don’t guess schema)
      Ronin::DB::URL.find_or_import(u) if Ronin::DB::URL.respond_to?(:find_or_import)
    rescue StandardError
      nil
    end

    # Run database imports with reduced console noise for clean UX
    def with_quiet_db_output
      # Allow opt-in verbose mode for debugging
      # Example command: NOKIZARU_DB_VERBOSE=1 bundle exec nokizaru --full --url https://example.com
      return yield if ENV['NOKIZARU_DB_VERBOSE'] == '1'

      require 'stringio'

      old_stdout = $stdout
      old_stderr = $stderr
      $stdout = StringIO.new
      $stderr = StringIO.new

      # Also try to quiet ActiveRecord/ActiveSupport if loaded
      old_migration_verbose = nil
      old_ar_logger = nil
      sentinel = Object.new
      old_depr_silenced = sentinel
      old_depr_behavior = sentinel

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
          deprecation = ActiveSupport::Deprecation

          if deprecation.respond_to?(:silenced) && deprecation.respond_to?(:silenced=)
            old_depr_silenced = deprecation.silenced
            deprecation.silenced = true
          end

          if deprecation.respond_to?(:behavior) && deprecation.respond_to?(:behavior=)
            old_depr_behavior = deprecation.behavior
            deprecation.behavior = :silence
          end
        end

        yield
      ensure
        if defined?(ActiveSupport::Deprecation)
          deprecation = ActiveSupport::Deprecation

          if old_depr_silenced != sentinel && deprecation.respond_to?(:silenced=)
            deprecation.silenced = old_depr_silenced
          end

          if old_depr_behavior != sentinel && deprecation.respond_to?(:behavior=)
            deprecation.behavior = old_depr_behavior
          end
        end

        ActiveRecord::Base.logger = old_ar_logger if defined?(ActiveRecord::Base) && !old_ar_logger.nil?

        if defined?(ActiveRecord::Migration) && !old_migration_verbose.nil?
          ActiveRecord::Migration.verbose = old_migration_verbose
        end

        $stdout = old_stdout
        $stderr = old_stderr
      end
    end

    # Import open port artifacts into the workspace database when available
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

    # Write JSON using a temp file and rename to avoid partial writes
    def write_json_atomic(path, obj)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)

      temp = Tempfile.new(['.nokizaru', '.json'], dir)
      moved = false

      begin
        temp.binmode
        temp.write(JSON.pretty_generate(obj))
        temp.flush
        temp.fsync
        temp.close

        File.rename(temp.path, path)
        moved = true
      ensure
        unless moved
          temp.close unless temp.closed?
          FileUtils.rm_f(temp.path)
        end
      end
    end
  end
end
