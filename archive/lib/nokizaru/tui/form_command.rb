# frozen_string_literal: true

module Nokizaru
  module TUI
    # Turns the form's state into what the rest of the app consumes: the enabled modules, the Runner options,
    # the HUD profile, and the live command segments. Header values ride along to the Runner but are only ever
    # shown as a count, so no secret can reach the command line or the HUD
    module FormCommand
      # Options with no form field, carried from the invocation as given
      CARRIED_OPTIONS = %i[sp d].freeze

      def module_keys
        Form.run_order.select { |key| @modules.include?(key) }
      end

      def enabled_modules
        @modules.include?(:full) ? Form.run_order.dup : module_keys
      end

      # The options hash and argv a Runner consumes; only set switches are included, so defaults still apply. The
      # invocation's argv rides along because the Runner reads -H and --no-MODULE from argv, as in the classic run
      def to_request
        { options: build_options.merge(@carried), argv: @argv }
      end

      # What the top HUD cluster shows while composing
      def profile
        { target: @values[:target].to_s.empty? ? '(enter a target)' : @values[:target], ip: 'pending run',
          modules: modules_summary, switches: switches_summary, notice: nil, modules_enabled: enabled_modules }
      end

      # The live command segments: [text, role] where role is :cmd, :flag, :value, :mod
      def command_segments
        segments = [['nokizaru', :cmd]]
        if @modules.include?(:full)
          segments << ['--full', :mod]
        else
          module_keys.each { |key| segments << ["--#{key}", :mod] }
        end
        segments << ['--target', :flag] << [@values[:target], :value] unless @values[:target].to_s.strip.empty?
        command_switches(segments)
        segments.concat(carried_segments)
      end

      private

      def build_options
        options = { target: @values[:target].to_s.strip }
        apply_modules(options)
        %i[w e p].each { |key| text_switch(options, key) }
        %i[dt pt T].each { |key| number_switch(options, key) }
        options[:r] = true if @values[:r]
        options[:s] = true if @values[:s]
        apply_export(options)
        options
      end

      def apply_modules(options)
        if @modules.include?(:full)
          options[:full] = true
        else
          module_keys.each { |key| options[key] = true }
        end
      end

      def apply_export(options)
        return unless @values[:export]

        options[:export] = true
        %i[o cd of].each { |key| text_switch(options, key) }
      end

      # A shell would expand a leading ~ in a path, so the form does too
      def text_switch(options, key)
        value = @values[key].to_s.strip
        return if value.empty?

        options[key] = %i[w cd].include?(key) && value.start_with?('~') ? File.expand_path(value) : value
      end

      # Parsed like the CLI's numeric flags (7.5 stays 7.5); text that is not a number passes through so the
      # Runner rejects it with its own message instead of the run silently using a default
      def number_switch(options, key)
        value = @values[key].to_s.strip
        return if value.empty?

        options[key] = Integer(value, 10, exception: false) || Float(value, exception: false) || value
      end

      def modules_summary
        skips = skip_flags.map { |flag| flag.delete_prefix('--') }
        return (['full'] + skips).join('  ') if @modules.include?(:full)
        return '(none selected)' if module_keys.empty?

        (module_keys + skips).join('  ')
      end

      def switches_summary
        parts = Form::FIELDS.reject { |f| %i[target modules].include?(f.key) }
                            .select { |f| field_shown?(f) }.filter_map { |f| switch_text(f) }
        parts.concat(carried_switches)
        parts.empty? ? 'none' : parts.join('  ')
      end

      # The export formats, directory, and filename only matter when export is on, so they stay off the command
      # line and the HUD summary until it is
      def field_shown?(field)
        return @values[:export] if %i[o cd of].include?(field.key)

        true
      end

      def switch_text(field)
        value = @values[field.key]
        return nil if value.nil? || value == false || value.to_s.strip.empty?

        value == true ? field.flag : "#{field.flag} #{value}"
      end

      def command_switches(segments)
        Form::FIELDS.reject { |f| %i[target modules].include?(f.key) }.each do |field|
          next unless field_shown?(field)

          value = @values[field.key]
          next if value.nil? || value == false || value.to_s.strip.empty?

          segments << [field.flag, :flag]
          segments << [value.to_s, :value] unless value == true
        end
      end

      def carried_segments
        segments = skip_flags.map { |flag| [flag, :mod] }
        @carried.each { |key, value| segments << ["-#{key}", :flag] << [value.to_s, :value] }
        headers = header_count
        segments << [headers, :flag] if headers
        segments
      end

      def carried_switches
        @carried.map { |key, value| "-#{key} #{value}" } + [header_count].compact
      end

      # The module skips the Runner honors, in the order they were passed
      def skip_flags
        @argv & CLI::Runner::SKIPPABLE_MODULES.map { |name| "--no-#{name}" }
      end

      # Security: header values can carry session cookies, so the form shows only how many were passed
      def header_count
        count = RequestHeaders.cli_values(@argv).length
        "-H ×#{count}" if count.positive?
      end
    end
  end
end
