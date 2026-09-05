# frozen_string_literal: true

module Nokizaru
  module Paths
    def self.default_config_template
      File.join(project_root, 'conf/config.json')
    end

    def self.default_keys_template
      File.join(project_root, 'conf/keys.json')
    end
  end
end
