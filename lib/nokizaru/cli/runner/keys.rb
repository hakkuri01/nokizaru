# frozen_string_literal: true

module Nokizaru
  class CLI
    class Runner
      # Banner rendering and API key persistence helpers
      module Keys
        VALID_KEYS = %w[
          bevigil binedge facebook netlas shodan virustotal zoomeye hunter chaos censys_api_id censys_api_secret
          wappalyzer
        ].freeze

        private

        def banner
          puts("#{CLI::G}#{banner_art}#{CLI::W}\n")
          puts("#{CLI::G}⟦+⟧#{CLI::C} Created By   :#{CLI::W} hakkuri")
          puts("#{CLI::G} ├─◈#{CLI::C} ⟦GIT⟧       :#{CLI::W} https://github.com/hakkuri01")
          puts("#{CLI::G} └─◈#{CLI::C} ⟦LOG⟧       :#{CLI::W} Issues/PRs welcome")
          puts("#{CLI::G}⟦+⟧#{CLI::C} Version      :#{CLI::W} #{Nokizaru::VERSION}")
        end

        def banner_art
          <<~ART

                 ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢻⣿⣶⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
                 ⠀⠀⠀⠀⢤⣤⣀⠀⠀⣀⡀⠀⠀⠀⠀⠀⠸⣿⣿⣀⣀⣀⠀⠀⠀⠀⠀⠀⠀⠀
                 ⠀⠀⠀⠀⠀⠹⣿⣧⣀⣾⣿⣿⠆⠀⣀⣠⣴⣿⣿⠿⠟⠛⠀⠀⠀⠀⠀⠀⠀⠀
                 ⠀⠀⠀⠀⠀⠀⣻⣿⣿⠿⠋⠁⠀⠀⠉⠉⢹⣿⣿⠀⠀⠀⣀⣠⣤⣄⠀⠀⠀⠀
                 ⠀⠀⠀⢀⣤⠾⠿⣿⡇⠀⢀⠀⣀⣀⣤⣴⡾⠿⠛⠛⠛⠉⠙⠛⠛⠛⠛⠀⠀⠀
                 ⠀⠀⠀⠀⠀⠀⠀⣿⡇⠀⠈⢿⠿⠛⣉⠁⢀⣀⣠⣤⣦⣄⠀⠀⠀⠀⠀⠀⠀⠀
                 ⠀⠀⠀⠀⠀⠀⣼⣿⣿⠀⠀⠀⠀⢺⣿⡟⠋⠉⠁⣼⣿⡿⠁⠀⠀⠀⠀⠀⠀⠀
                 ⠀⠀⠀⠀⢀⣾⣿⣿⣿⠀⠀⠀⠀⠈⣿⣷⣤⣤⣤⣿⣿⠁⢀⣀⣀⠀⠀⠀⠀⠀
                 ⠀⠀⠀⣠⣿⠟⠁⢸⣿⠀⠀⠀⠀⠀⠹⣿⣿⣯⡉⠉⠀⣠⣾⣿⠟⠀⠀⠀⠀⠀
                 ⠀⣠⣾⠟⠁⠀⠀⢸⣿⠀⠀⠀⠀⠀⣠⣿⣿⡁⠙⢷⣾⡟⠉⠀⠀⠀⠀⠀⠀⠀
                 ⠈⠉⠀⠀⠀⠀⠀⢸⣿⠀⠀⠀⢀⣼⡿⠋⣿⡇⠀⠀⠙⣿⣦⣄⠀⠀⠀⠀⠀⠀
                 ⠀⠀⠀⠀⠀⠀⠀⣾⣿⠀⣠⣴⠟⠋⠀⢀⣿⡇⠀⠀⠀⡈⠻⣿⣷⣦⣄⠀⠀⠀
                 ⠀⠀⠀⠱⣶⣤⣴⣿⣿⠀⠁⠀⠀⠀⠀⢸⣿⡇⣀⣴⡾⠁⠀⠈⠻⠿⠿⠿⠷⠖
                 ⠀⠀⠀⠀⠈⠻⣿⣿⡇⠀⠀⠀⠀⠀⢀⣾⣿⣿⣿⠟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
                 ⠀⠀⠀⠀⠀⠀⠈⠉⠀⠀⠀⠀⠀⠀⠀⢻⡿⠟⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
             ▐ ▄       ▄ •▄ ▪  ·▄▄▄▄• ▄▄▄· ▄▄▄  ▄• ▄▌
            •█▌▐█▪     █▌▄▌▪██ ▪▀·.█▌▐█ ▀█ ▀▄ █·█▪██▌
            ▐█▐▐▌ ▄█▀▄ ▐▀▀▄·▐█·▄█▀▀▀•▄█▀▀█ ▐▀▀▄ █▌▐█▌
            ██▐█▌▐█▌.▐▌▐█.█▌▐█▌█▌▪▄█▀▐█ ▪▐▌▐█•█▌▐█▄█▌
            ▀▀ █▪ ▀█▄▀▪·▀  ▀▀▀▀·▀▀▀ • ▀  ▀ .▀  ▀ ▀▀▀
          ART
        end

        def save_key(key_string)
          key_name, key_value = parse_key_parts(key_string)
          validate_key_parts!(key_name, key_value)
          persist_key(key_name, key_value)
          UI.line(:info, "#{key_name} key saved (not validated)")
          exit(0)
        end

        def parse_key_parts(key_string)
          key_string.to_s.strip.split('@', 2)
        end

        def validate_key_parts!(key_name, key_value)
          return invalid_key_syntax! if key_name.to_s.strip.empty? || key_value.to_s.strip.empty?
          return if VALID_KEYS.include?(key_name)

          invalid_key_name!
        end

        def invalid_key_syntax!
          UI.line(:error, 'Invalid key syntax')
          UI.line(:plus, 'Use : -k name@key (example: shodan@ABC123)')
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
          File.write(Paths.keys_file, JSON.pretty_generate(keys_json))
        end

        def load_keys_json
          JSON.parse(File.read(Paths.keys_file))
        rescue StandardError
          {}
        end
      end
    end
  end
end
