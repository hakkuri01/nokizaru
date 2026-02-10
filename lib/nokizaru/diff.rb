# frozen_string_literal: true

require 'set'

module Nokizaru
  module Diff
    module_function

    # Compute a diff between two run objects (old_run, new_run)
    # Returns a hash with added/removed for key artifact sets
    # Compare artifact sets between runs and keep only added or removed values
    def compute(old_run, new_run)
      old_art = old_run.fetch('artifacts', {})
      new_art = new_run.fetch('artifacts', {})

      keys = (old_art.keys + new_art.keys).uniq.sort
      out = {}

      keys.each do |k|
        o = Array(old_art[k]).to_set
        n = Array(new_art[k]).to_set
        added = (n - o).to_a.sort
        removed = (o - n).to_a.sort
        next if added.empty? && removed.empty?

        out[k] = { 'added' => added, 'removed' => removed }
      end

      out
    end
  end
end
