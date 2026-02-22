# frozen_string_literal: true

module Nokizaru
  class Workspace
    # Output suppression helpers around noisy database operations
    module DBOutputSilencer
      private

      def with_quiet_db_output
        return yield if ENV['NOKIZARU_DB_VERBOSE'] == '1'

        suppress_std_streams do
          state = silence_active_record_noise
          begin
            yield
          ensure
            restore_active_record_noise(state)
          end
        end
      end

      def suppress_std_streams
        require 'stringio'
        old_stdout = $stdout
        old_stderr = $stderr
        $stdout = StringIO.new
        $stderr = StringIO.new
        yield
      ensure
        $stdout = old_stdout
        $stderr = old_stderr
      end

      def silence_active_record_noise
        state = {
          migration_verbose: nil,
          ar_logger: nil,
          deprecation_silenced: :unset,
          deprecation_behavior: :unset
        }
        silence_migration_output!(state)
        silence_logger_output!(state)
        silence_deprecations!(state)
        state
      end

      def silence_migration_output!(state)
        return unless defined?(ActiveRecord::Migration)

        state[:migration_verbose] = ActiveRecord::Migration.verbose
        ActiveRecord::Migration.verbose = false
      end

      def silence_logger_output!(state)
        return unless defined?(ActiveRecord::Base)

        state[:ar_logger] = ActiveRecord::Base.logger
        ActiveRecord::Base.logger = nil
      end

      def silence_deprecations!(state)
        return unless defined?(ActiveSupport::Deprecation)

        deprecation = ActiveSupport::Deprecation
        silence_deprecation_flag!(deprecation, state)
        silence_deprecation_behavior!(deprecation, state)
      end

      def silence_deprecation_flag!(deprecation, state)
        return unless deprecation.respond_to?(:silenced) && deprecation.respond_to?(:silenced=)

        state[:deprecation_silenced] = deprecation.silenced
        deprecation.silenced = true
      end

      def silence_deprecation_behavior!(deprecation, state)
        return unless deprecation.respond_to?(:behavior) && deprecation.respond_to?(:behavior=)

        state[:deprecation_behavior] = deprecation.behavior
        deprecation.behavior = :silence
      end

      def restore_active_record_noise(state)
        restore_deprecations(state)
        restore_logger_output(state)
        restore_migration_output(state)
      end

      def restore_deprecations(state)
        return unless defined?(ActiveSupport::Deprecation)

        deprecation = ActiveSupport::Deprecation
        restore_deprecation_flag(deprecation, state[:deprecation_silenced])
        restore_deprecation_behavior(deprecation, state[:deprecation_behavior])
      end

      def restore_deprecation_flag(deprecation, previous)
        return if previous == :unset
        return unless deprecation.respond_to?(:silenced=)

        deprecation.silenced = previous
      end

      def restore_deprecation_behavior(deprecation, previous)
        return if previous == :unset
        return unless deprecation.respond_to?(:behavior=)

        deprecation.behavior = previous
      end

      def restore_logger_output(state)
        return unless defined?(ActiveRecord::Base)

        ActiveRecord::Base.logger = state[:ar_logger]
      end

      def restore_migration_output(state)
        return unless defined?(ActiveRecord::Migration)
        return if state[:migration_verbose].nil?

        ActiveRecord::Migration.verbose = state[:migration_verbose]
      end
    end
  end
end
