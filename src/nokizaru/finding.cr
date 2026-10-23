require "json"

module Nokizaru
  # A security finding produced by the findings rules. Serializes to the exact
  # keys the Ruby tool emitted (`module` is a Crystal keyword, so the field is
  # named source_module with the JSON key restored). Unset optional fields are
  # omitted, matching the Ruby hash.
  struct Finding
    include JSON::Serializable

    property id : String
    property severity : String
    property title : String
    property evidence : String?
    property recommendation : String?

    @[JSON::Field(key: "module")]
    property source_module : String?

    property tags : Array(String)

    def initialize(
      @id : String,
      @severity : String,
      @title : String,
      @source_module : String?,
      @tags : Array(String),
      @evidence : String? = nil,
      @recommendation : String? = nil,
    )
    end
  end
end
