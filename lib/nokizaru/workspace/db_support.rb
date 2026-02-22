# frozen_string_literal: true

module Nokizaru
  class Workspace
    # Ronin::DB integration helpers for workspace ingestion and snapshots
    module DBSupport
      include DBOutputSilencer
      include DBRecords

      def db_available?
        defined?(Ronin::DB)
      end

      def connect_db!(migrate: true)
        unless db_available?
          set_db_unavailable_state
          return false
        end
        return true if connected_to_workspace_db?

        perform_workspace_db_connect(migrate: migrate)
        true
      rescue StandardError => e
        handle_db_error('connect failed', e, fallback: false)
      end

      def ingest_run!(run_hash)
        return false unless connect_db!(migrate: true)

        run = normalized_run_hash(run_hash)
        ip_obj = ingest_primary_identifiers(run['meta'])
        ingest_artifact_hostnames(run['artifacts'])
        ingest_artifact_urls(run['artifacts'], run['modules'])
        ingest_open_ports(run['artifacts'], ip_obj)
        @last_db_error = nil
        true
      rescue StandardError => e
        handle_db_error('ingest failed', e, fallback: false)
      end

      def db_snapshot
        return {} unless connect_db!(migrate: false)

        snapshot = {}
        add_snapshot_hostnames!(snapshot)
        add_snapshot_ip_addresses!(snapshot)
        add_snapshot_urls!(snapshot)
        add_snapshot_open_ports!(snapshot)
        @last_db_error = nil
        snapshot
      rescue StandardError => e
        handle_db_error('snapshot failed', e, fallback: {})
      end

      private

      def set_db_unavailable_state
        @last_db_error = 'ronin-db is unavailable'
      end

      def perform_workspace_db_connect(migrate:)
        migrate_now = migrate && !@db_migrated
        with_quiet_db_output { Ronin::DB.connect(db_connect_config, migrate: migrate_now) }
        @db_migrated ||= migrate_now
        @last_db_error = nil
      end

      def handle_db_error(context, error, fallback:)
        @last_db_error = "#{error.class}: #{error.message}"
        Log.write("[workspace.db] #{context}: #{error.class}: #{error}")
        backtrace = error.backtrace&.first
        Log.write("[workspace.db] first backtrace: #{backtrace}") if backtrace
        fallback
      end

      def db_connect_config
        { adapter: 'sqlite3', database: db_path }
      end

      def connected_to_workspace_db?
        return false unless db_connected?
        return true unless defined?(ActiveRecord::Base)

        config = (ActiveRecord::Base.connection_db_config if ActiveRecord::Base.respond_to?(:connection_db_config))
        return true unless config.respond_to?(:database)

        File.expand_path(config.database.to_s) == File.expand_path(db_path)
      rescue StandardError
        false
      end

      def db_connected?
        return false unless defined?(ActiveRecord::Base)
        return ActiveRecord::Base.connected? if ActiveRecord::Base.respond_to?(:connected?)

        ActiveRecord::Base.connection
        true
      rescue StandardError
        false
      end
    end
  end
end
