require "json"

module Nokizaru
  struct ModuleOutcome
    include JSON::Serializable

    getter status : String
    getter error : String
    getter timed_out : Bool?
    @[JSON::Field(key: "module")]
    getter module_name : String?
    getter label : String?
    getter open_ports : Array(String)?
    getter ports : Array(String)?

    def initialize(@status, @error, *, @timed_out = nil, @module_name = nil, @label = nil, @open_ports = nil, @ports = nil)
    end
  end
end
