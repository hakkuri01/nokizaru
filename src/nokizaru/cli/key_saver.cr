require "../keystore"
require "../ui"
require "../log"

module Nokizaru::CLI
  # The `-k` flow: save an API key to the store. A key on the command line lands
  # in shell history and the process list, so `-k name` alone reads the value
  # without echo (or from piped stdin). Returns the process exit code.
  module KeySaver
    extend self

    def run(key_string : String, interactive : Bool = STDIN.tty?, input : IO = STDIN) : Int32
      parts = key_string.strip.split('@', 2)
      name = parts[0]
      value = parts[1]?
      return invalid_syntax if name.empty?
      return invalid_name(name) unless KeyStore.valid_name?(name)

      value = read_value(name, interactive, input) if value.nil?
      return invalid_syntax if value.nil? || value.strip.empty?

      persist(name, value.strip)
    end

    private def persist(name : String, value : String) : Int32
      KeyStore.save(name, value)
      UI.line(:info, "#{name} key saved (not validated)")
      0
    rescue KeyStore::UnreadableStore
      UI.line(:error, "keys.json is not a valid JSON object; fix or remove it, then save the key again")
      Log.write("keys.json did not parse, key not saved")
      1
    end

    private def read_value(name : String, interactive : Bool, input : IO) : String?
      return input.gets unless interactive

      STDOUT.print("#{name} key: ")
      result = STDIN.noecho(&.gets)
      STDOUT.puts
      result
    end

    private def invalid_syntax : Int32
      UI.line(:error, "Invalid key syntax")
      UI.line(:plus, "Use : -k name (prompts for the key) or -k name@key")
      Log.write("Invalid key syntax supplied")
      1
    end

    private def invalid_name(name : String) : Int32
      UI.line(:error, "Invalid key name!")
      UI.row(:plus, "Valid key names", KeyStore::VALID_KEYS.join(", "))
      Log.write("Invalid key name, exiting")
      1
    end
  end
end
