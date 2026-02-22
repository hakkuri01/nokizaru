# frozen_string_literal: true

require 'set'

module Nokizaru
  # Nokizaru::Diff implementation
  module Diff
    module_function

    # Compute a diff between two run objects (old_run, new_run)
    # Returns a hash with added/removed for key artifact sets
    # Compare artifact sets between runs and keep only added or removed values
    def compute(old_run, new_run)
      old_art = artifacts_for(old_run)
      new_art = artifacts_for(new_run)
      keys_for(old_art, new_art).each_with_object({}) do |key, out|
        change = artifact_change(old_art[key], new_art[key])
        out[key] = change if change
      end
    end

    def artifacts_for(run)
      run.fetch('artifacts', {})
    end

    def keys_for(old_art, new_art)
      (old_art.keys + new_art.keys).uniq.sort
    end

    def artifact_change(old_values, new_values)
      old_set = Array(old_values).to_set
      new_set = Array(new_values).to_set
      added = (new_set - old_set).to_a.sort
      removed = (old_set - new_set).to_a.sort
      return nil if added.empty? && removed.empty?

      { 'added' => added, 'removed' => removed }
    end
  end
end
