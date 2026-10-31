require "../cli/options"
require "./profile"

module Nokizaru
  module Tui
    # The command builder: a vim-modal form whose fields compose a scan (NORMAL
    # navigates and toggles, INSERT types). It owns no I/O; the app drives it with
    # key names and reads back the launch options, the live command, and the HUD
    # profile. Header values ride along from the invocation but are only ever shown
    # as a count, so no secret reaches the command line or the HUD. The Ruby
    # form/form_command/form_keys trio is one class here; the typed CLI::Options
    # carries -H/--no-<module>/-sp/-d, so there is no separate argv to thread.
    class Form
      enum Kind
        Text
        Number
        Toggle
        Modules
      end

      # A live-command segment's role, which picks its color in the view.
      enum Role
        Cmd
        Flag
        Value
        Mod
      end

      record Field,
        key : String,
        label : String,
        flag : String?,
        kind : Kind,
        default : String,
        group : String,
        required : Bool

      MODULE_CHIPS = [
        {"full", "Full"}, {"headers", "Headers"}, {"sslinfo", "SSL"}, {"whois", "Whois"},
        {"dns", "DNS"}, {"sub", "Subs"}, {"arch", "Arch"}, {"ps", "Ports"},
        {"crawl", "Crawl"}, {"dir", "Dir"}, {"wayback", "Wayback"},
      ]

      FIELDS = [
        Field.new("target", "Target", "--target", Kind::Text, "", "TARGET", true),
        Field.new("modules", "Modules", nil, Kind::Modules, "", "TARGET", true),
        Field.new("w", "Wordlist", "-w", Kind::Text, "medium", "OPTIONS", false),
        Field.new("e", "Extensions", "-e", Kind::Text, "", "OPTIONS", false),
        Field.new("dt", "Dir Threads", "-dt", Kind::Number, "", "OPTIONS", false),
        Field.new("pt", "Port Threads", "-pt", Kind::Number, "", "OPTIONS", false),
        Field.new("p", "Ports", "-p", Kind::Text, "", "OPTIONS", false),
        Field.new("T", "Timeout", "-T", Kind::Number, "", "OPTIONS", false),
        Field.new("r", "Follow Redirects", "-r", Kind::Toggle, "", "OPTIONS", false),
        Field.new("insecure", "Insecure TLS", "--insecure", Kind::Toggle, "", "OPTIONS", false),
        Field.new("export", "Export", "--export", Kind::Toggle, "", "EXPORT", false),
        Field.new("o", "Formats", "-o", Kind::Text, "txt,json,html", "EXPORT", false),
        Field.new("cd", "Directory", "-cd", Kind::Text, "", "EXPORT", false),
        Field.new("of", "Filename", "-of", Kind::Text, "", "EXPORT", false),
      ]

      # The screens change on return: Run launches, Quit exits, Help opens help,
      # nil stays in the form.
      enum Action
        Help
        Quit
        Run
      end

      getter focus : Int32 = 0
      getter caret : Int32 = 0
      getter chip : Int32 = 0
      getter cols : Int32 = 80
      getter rows : Int32 = 24
      getter? insert : Bool = false
      property? launching : Bool = false
      property error : String? = nil

      @values : Hash(String, String)
      @toggles : Hash(String, Bool)
      @modules : Array(String)
      @request_headers : Array(String)
      @skips : Array(String)
      @carried_ssl_port : Int32?
      @carried_dns_servers : String?

      def initialize(options : CLI::Options = CLI::Options.new)
        @values = {} of String => String
        @toggles = {} of String => Bool
        @modules = [] of String
        FIELDS.each do |field|
          case field.kind
          when .text?, .number? then @values[field.key] = field.default
          when .toggle?         then @toggles[field.key] = false
          end
        end
        @request_headers = options.request_headers.dup
        @skips = CLI::Options::MODULE_ORDER.select { |mod| options.skips.includes?(mod) }
        @carried_ssl_port = options.ssl_port
        @carried_dns_servers = options.dns_servers
        apply_prefill(options)
      end

      def resize(cols : Int32, rows : Int32) : Nil
        @cols = cols
        @rows = rows
      end

      def text(key : String) : String
        @values[key]? || ""
      end

      def toggle?(key : String) : Bool
        @toggles[key]? || false
      end

      def module_on?(key : String) : Bool
        @modules.includes?(key)
      end

      def ready? : Bool
        return false if text("target").strip.empty?

        @modules.includes?("full") || !module_keys.empty?
      end

      def key(name : String) : Action?
        @error = nil
        return nil if @launching

        @insert ? insert_key(name) : normal_key(name)
      end

      # What the top HUD cluster shows while composing.
      def profile : Profile
        target = text("target").empty? ? "(enter a target)" : text("target")
        Profile.new(target: target, ip: "pending run", modules: modules_summary,
          switches: switches_summary, modules_enabled: enabled_modules, notice: nil)
      end

      # The live command as [text, role] segments.
      def command_segments : Array(Tuple(String, Role))
        segments = [{"nokizaru", Role::Cmd}]
        if @modules.includes?("full")
          segments << {"--full", Role::Mod}
        else
          module_keys.each { |key| segments << {"--#{key}", Role::Mod} }
        end
        unless text("target").strip.empty?
          segments << {"--target", Role::Flag}
          segments << {text("target"), Role::Value}
        end
        command_switches(segments)
        carried_segments(segments)
        segments
      end

      # The typed options a scan runs with. Only set fields are populated, so the
      # runner's defaults still apply; the carried headers, skips, and -sp/-d ride
      # along from the invocation.
      def to_options : CLI::Options
        opts = CLI::Options.new
        opts.target = text("target").strip
        apply_modules(opts)
        @skips.each { |mod| opts.skips << mod }
        opts.wordlist = expand(text("w")) if present?("w")
        opts.extensions = text("e") if present?("e")
        opts.ports = text("p") if present?("p")
        opts.dir_threads = text("dt").to_i? if present?("dt")
        opts.port_threads = text("pt").to_i? if present?("pt")
        opts.timeout = text("T").to_f? if present?("T")
        opts.redirects = true if toggle?("r")
        opts.insecure = true if toggle?("insecure")
        apply_export(opts)
        opts.request_headers.concat(@request_headers)
        opts.ssl_port = @carried_ssl_port
        opts.dns_servers = @carried_dns_servers
        opts
      end

      def module_keys : Array(String)
        CLI::Options::MODULE_ORDER.select { |key| @modules.includes?(key) }
      end

      def enabled_modules : Array(String)
        @modules.includes?("full") ? CLI::Options::MODULE_ORDER.dup : module_keys
      end

      private def apply_prefill(options : CLI::Options) : Nil
        options.target.try { |v| @values["target"] = v }
        options.wordlist.try { |v| @values["w"] = v }
        options.extensions.try { |v| @values["e"] = v }
        options.dir_threads.try { |v| @values["dt"] = v.to_s }
        options.port_threads.try { |v| @values["pt"] = v.to_s }
        options.ports.try { |v| @values["p"] = v }
        options.timeout.try { |v| @values["T"] = format_timeout(v) }
        options.formats.try { |v| @values["o"] = v }
        options.export_dir.try { |v| @values["cd"] = v }
        options.export_basename.try { |v| @values["of"] = v }
        @toggles["r"] = true if options.redirects
        @toggles["insecure"] = true if options.insecure?
        @toggles["export"] = true if options.export?
        @modules << "full" if options.full?
        CLI::Options::MODULE_ORDER.each { |key| @modules << key if options.modules.includes?(key) }
      end

      private def format_timeout(value : Float64) : String
        value == value.floor ? value.to_i.to_s : value.to_s
      end

      private def normal_key(name : String) : Action?
        case name
        when "j", "down" then move(1)
        when "k", "up"   then move(-1)
        when "i"         then begin_insert
        when "left"      then move_chip(-1)
        when "right"     then move_chip(1)
        when " "         then toggle
        when "h"         then return Action::Help
        when "q"         then return Action::Quit
        when "enter"     then return run_action
        end
        nil
      end

      private def insert_key(name : String) : Action?
        case name
        when "enter"     then return run_action
        when "esc"       then @insert = false
        when "left"      then @caret = [@caret - 1, 0].max
        when "right"     then @caret = [@caret + 1, current.size].min
        when "home"      then @caret = 0
        when "end"       then @caret = current.size
        when "backspace" then delete_before
        when "delete"    then delete_at
        else                  insert_char(name)
        end
        nil
      end

      private def run_action : Action?
        ready? ? Action::Run : nil
      end

      private def move(delta : Int32) : Nil
        @focus = (@focus + delta) % FIELDS.size
        @insert = false
        @caret = 0
      end

      private def move_chip(delta : Int32) : Nil
        return unless field.kind.modules?

        @chip = (@chip + delta) % MODULE_CHIPS.size
      end

      private def toggle : Nil
        case field.kind
        when .toggle?  then @toggles[field.key] = !toggle?(field.key)
        when .modules? then toggle_chip
        end
      end

      private def toggle_chip : Nil
        key = MODULE_CHIPS[@chip][0]
        @modules.includes?(key) ? @modules.delete(key) : @modules << key
      end

      private def begin_insert : Nil
        return unless field.kind.text? || field.kind.number?

        @insert = true
        @caret = current.size
      end

      private def field : Field
        FIELDS[@focus]
      end

      private def current : String
        text(field.key)
      end

      private def insert_char(name : String) : Nil
        return if name.size != 1
        return if field.kind.number? && !name.matches?(/\A[\d.]\z/)

        value = current
        @values[field.key] = value[0, @caret] + name + value[@caret..]
        @caret += 1
      end

      private def delete_before : Nil
        return if @caret.zero?

        value = current
        @values[field.key] = value[0, @caret - 1] + value[@caret..]
        @caret -= 1
      end

      private def delete_at : Nil
        value = current
        return if @caret >= value.size

        @values[field.key] = value[0, @caret] + value[(@caret + 1)..]
      end

      private def apply_modules(opts : CLI::Options) : Nil
        if @modules.includes?("full")
          opts.full = true
        else
          module_keys.each { |key| opts.modules << key }
        end
      end

      private def apply_export(opts : CLI::Options) : Nil
        return unless toggle?("export")

        opts.export = true
        opts.formats = text("o") if present?("o")
        opts.export_dir = expand(text("cd")) if present?("cd")
        opts.export_basename = text("of") if present?("of")
      end

      private def present?(key : String) : Bool
        !text(key).strip.empty?
      end

      # A shell would expand a leading ~ in a path, so the form does too.
      private def expand(value : String) : String
        value.starts_with?("~") ? Path[value].expand(home: true).to_s : value
      end

      private def command_switches(segments : Array(Tuple(String, Role))) : Nil
        FIELDS.each do |field|
          next if field.key == "target" || field.kind.modules?
          next unless field_shown?(field)

          flag = field.flag
          next unless flag

          if field.kind.toggle?
            segments << {flag, Role::Flag} if toggle?(field.key)
          elsif present?(field.key)
            segments << {flag, Role::Flag}
            segments << {text(field.key), Role::Value}
          end
        end
      end

      private def carried_segments(segments : Array(Tuple(String, Role))) : Nil
        skip_flags.each { |flag| segments << {flag, Role::Mod} }
        if port = @carried_ssl_port
          segments << {"-sp", Role::Flag}
          segments << {port.to_s, Role::Value}
        end
        if dns = @carried_dns_servers
          segments << {"-d", Role::Flag}
          segments << {dns, Role::Value}
        end
        if headers = header_count
          segments << {headers, Role::Flag}
        end
      end

      # The export formats, directory, and filename only matter when export is on.
      private def field_shown?(field : Field) : Bool
        return toggle?("export") if {"o", "cd", "of"}.includes?(field.key)

        true
      end

      private def modules_summary : String
        skips = skip_flags.map(&.lchop("--"))
        return (["full"] + skips).join("  ") if @modules.includes?("full")
        return "(none selected)" if module_keys.empty?

        (module_keys + skips).join("  ")
      end

      private def switches_summary : String
        parts = FIELDS.compact_map do |field|
          next if field.key == "target" || field.kind.modules?
          next unless field_shown?(field)

          switch_text(field)
        end
        parts.concat(carried_switches)
        parts.empty? ? "none" : parts.join("  ")
      end

      private def switch_text(field : Field) : String?
        flag = field.flag
        return nil unless flag

        if field.kind.toggle?
          toggle?(field.key) ? flag : nil
        elsif present?(field.key)
          "#{flag} #{text(field.key)}"
        end
      end

      private def carried_switches : Array(String)
        parts = [] of String
        @carried_ssl_port.try { |port| parts << "-sp #{port}" }
        @carried_dns_servers.try { |dns| parts << "-d #{dns}" }
        header_count.try { |headers| parts << headers }
        parts
      end

      private def skip_flags : Array(String)
        @skips.map { |mod| "--no-#{mod}" }
      end

      # Security: header values can carry session cookies, so the form shows only
      # how many were passed.
      private def header_count : String?
        @request_headers.empty? ? nil : "-H ×#{@request_headers.size}"
      end
    end
  end
end
