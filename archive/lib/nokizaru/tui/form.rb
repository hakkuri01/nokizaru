# frozen_string_literal: true

module Nokizaru
  module TUI
    # The command builder: a vim-modal form whose fields compose a scan (NORMAL navigates and toggles, INSERT
    # types). It owns no I/O; the app drives it with key names and reads back the options, the live command, and
    # the HUD profile (built in FormCommand). Enter runs when a target and at least one module are set
    class Form
      include FormCommand
      include FormKeys

      Field = Data.define(:key, :label, :flag, :kind, :default, :group, :required)

      MODULE_CHIPS = [[:full, 'Full'], [:headers, 'Headers'], [:sslinfo, 'SSL'], [:whois, 'Whois'], [:dns, 'DNS'],
                      [:sub, 'Subs'], [:arch, 'Arch'], [:ps, 'Ports'], [:crawl, 'Crawl'], [:dir, 'Dir'],
                      [:wayback, 'Wayback']].freeze
      FIELDS = [
        Field.new(:target, 'Target', '--target', :text, '', 'TARGET', true),
        Field.new(:modules, 'Modules', nil, :modules, nil, 'TARGET', true),
        Field.new(:w, 'Wordlist', '-w', :text, 'medium', 'OPTIONS', false),
        Field.new(:e, 'Extensions', '-e', :text, '', 'OPTIONS', false),
        Field.new(:dt, 'Dir Threads', '-dt', :number, '', 'OPTIONS', false),
        Field.new(:pt, 'Port Threads', '-pt', :number, '', 'OPTIONS', false),
        Field.new(:p, 'Ports', '-p', :text, '', 'OPTIONS', false),
        Field.new(:T, 'Timeout', '-T', :number, '', 'OPTIONS', false),
        Field.new(:r, 'Follow Redirects', '-r', :toggle, false, 'OPTIONS', false),
        Field.new(:s, 'Verify SSL', '-s', :toggle, false, 'OPTIONS', false),
        Field.new(:export, 'Export', '--export', :toggle, false, 'EXPORT', false),
        Field.new(:o, 'Formats', '-o', :text, 'txt,json,html', 'EXPORT', false),
        Field.new(:cd, 'Directory', '-cd', :text, '', 'EXPORT', false),
        Field.new(:of, 'Filename', '-of', :text, '', 'EXPORT', false)
      ].freeze

      attr_reader :focus, :insert, :caret, :chip, :cols, :rows
      attr_accessor :launching, :error

      # The runner's module order, read on use because the TUI loads before the runner
      def self.run_order
        CLI::Runner::Workflow::MODULE_ORDER
      end

      # argv is the invocation, kept for the flags the form has no field for (see FormCommand#to_request)
      def initialize(prefill: {}, argv: [])
        @values = FIELDS.to_h { |field| [field.key, field.default] }
        @argv = Array(argv)
        @carried = {}
        @modules = []
        @focus = 0
        @insert = false
        @caret = 0
        @chip = 0
        @cols = 80
        @rows = 24
        @error = nil
        @launching = false
        apply_prefill(prefill)
      end

      def resize(cols, rows)
        @cols = cols
        @rows = rows
      end

      def value(key)
        @values[key]
      end

      def module_on?(key)
        @modules.include?(key)
      end

      def field
        FIELDS[@focus]
      end

      def ready?
        !@values[:target].to_s.strip.empty? && (@modules.include?(:full) || module_keys.any?)
      end

      # The screens change on return: :run launches, :quit exits, nil stays in the form
      def key(name)
        @error = nil
        return nil if @launching

        @insert ? insert_key(name) : normal_key(name)
      end
    end
  end
end
