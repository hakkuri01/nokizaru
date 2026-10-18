# frozen_string_literal: true

module Nokizaru
  class CLI
    class Runner
      module Keys
        VALID_KEYS = %w[
          alienvault bevigil binedge facebook netlas shodan virustotal zoomeye hunter chaos censys_api_id
          censys_api_secret wappalyzer
        ].freeze

        private

        def banner
          puts("#{UI::R}#{banner_art}#{UI::W}\n")
          UI.rows(:plus, [%w[AUTHOR hakkuri], ['VERSION', Nokizaru::VERSION]])
          UI.row(:plus, 'GIT', 'https://github.com/hakkuri01', label_width: 7)
          puts
        end

        def banner_art
          Nokizaru::Banner::TEXT
        end

        def save_key(key_string)
          key_name, key_value = parse_key_parts(key_string)
          validate_key_name!(key_name)
          key_value = read_key_value(key_name) if key_value.nil?
          invalid_key_syntax! if key_value.to_s.strip.empty?
          persist_key(key_name, key_value.strip)
          UI.line(:info, "#{key_name} key saved (not validated)")
          exit(0)
        end

        def parse_key_parts(key_string)
          key_string.to_s.strip.split('@', 2)
        end

        # Security: a key typed on the command line lands in shell history and the process list, so -k NAME alone
        # reads the value without echo, or from piped stdin (cost acceptable: it only runs for -k)
        def read_key_value(key_name)
          return $stdin.gets.to_s unless $stdin.tty?

          require 'io/console'
          $stdin.getpass("#{key_name} key: ").to_s
        end

        def validate_key_name!(key_name)
          return invalid_key_syntax! if key_name.to_s.strip.empty?
          return if VALID_KEYS.include?(key_name)

          invalid_key_name!
        end

        def invalid_key_syntax!
          UI.line(:error, 'Invalid key syntax')
          UI.line(:plus, 'Use : -k name (prompts for the key) or -k name@key')
          Log.write('Invalid key syntax supplied')
          exit(1)
        end

        def invalid_key_name!
          UI.line(:error, 'Invalid key name!')
          UI.row(:plus, 'Valid key names', VALID_KEYS.join(', '))
          Log.write('Invalid key name, exiting')
          exit(1)
        end

        def persist_key(key_name, key_value)
          Paths.sync_default_conf!
          keys_json = load_keys_json
          keys_json[key_name] = key_value
          write_keys_file(JSON.pretty_generate(keys_json))
          Paths.secure_keys_file!
        end

        # A store that does not parse is left as it is, so a hand-edit typo never costs the other saved keys
        def load_keys_json
          keys = JSON.parse(File.read(Paths.keys_file))
          keys.is_a?(Hash) ? keys : unreadable_keys_file!
        rescue JSON::ParserError
          unreadable_keys_file!
        end

        def unreadable_keys_file!
          UI.line(:error, 'keys.json is not a valid JSON object; fix or remove it, then save the key again')
          Log.write('keys.json did not parse, key not saved')
          exit(1)
        end

        # Written beside the store and renamed over it, so neither a reader nor a crash ever sees half a file
        def write_keys_file(json)
          temp = "#{Paths.keys_file}.#{Process.pid}.tmp"
          File.write(temp, json, perm: Paths::PRIVATE_FILE)
          File.rename(temp, Paths.keys_file)
        end
      end
    end
  end
end
