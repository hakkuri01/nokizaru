# frozen_string_literal: true

module Nokizaru
  module TUI
    # Vim-modal key handling for the form: NORMAL navigation and toggles, INSERT text editing at a caret
    module FormKeys
      private

      def apply_prefill(prefill)
        return if prefill.nil? || prefill.empty?

        Form::FIELDS.each do |f|
          next if f.key == :modules

          value = prefill[f.key]
          @values[f.key] = f.kind == :toggle ? (value == true) : value.to_s unless value.nil?
        end
        @modules << :full if prefill[:full]
        Form.run_order.each { |key| @modules << key if prefill[key] }
        @carried = prefill.slice(*FormCommand::CARRIED_OPTIONS).compact
      end

      def normal_key(name)
        case name
        when 'j', 'down' then move(1)
        when 'k', 'up' then move(-1)
        when 'i' then begin_insert
        when 'left' then move_chip(-1)
        when 'right' then move_chip(1)
        when ' ' then toggle
        when 'h' then return :help
        when 'q' then return :quit
        when 'enter' then return run_action
        end
        nil
      end

      def insert_key(name)
        case name
        when 'enter' then return run_action
        when 'esc' then @insert = false
        when 'left' then @caret = [@caret - 1, 0].max
        when 'right' then @caret = [@caret + 1, current.length].min
        when 'home' then @caret = 0
        when 'end' then @caret = current.length
        when 'backspace' then delete_before
        when 'delete' then delete_at
        else insert_char(name)
        end
        nil
      end

      def run_action
        ready? ? :run : nil
      end

      def move(delta)
        @focus = (@focus + delta) % Form::FIELDS.length
        @insert = false
        @caret = 0
      end

      def move_chip(delta)
        return unless field.kind == :modules

        @chip = (@chip + delta) % Form::MODULE_CHIPS.length
      end

      def toggle
        case field.kind
        when :toggle then @values[field.key] = !@values[field.key]
        when :modules then toggle_chip
        end
      end

      def toggle_chip
        key = Form::MODULE_CHIPS[@chip].first
        @modules.include?(key) ? @modules.delete(key) : @modules << key
      end

      def begin_insert
        return unless %i[text number].include?(field.kind)

        @insert = true
        @caret = current.length
      end

      def current
        @values[field.key].to_s
      end

      def insert_char(name)
        return unless name.length == 1
        return if field.kind == :number && !name.match?(/\A[\d.]\z/)

        value = current
        @values[field.key] = value[0, @caret].to_s + name + value[@caret..].to_s
        @caret += 1
      end

      def delete_before
        return if @caret.zero?

        value = current
        @values[field.key] = value[0, @caret - 1].to_s + value[@caret..].to_s
        @caret -= 1
      end

      def delete_at
        value = current
        return if @caret >= value.length

        @values[field.key] = value[0, @caret].to_s + value[(@caret + 1)..].to_s
      end
    end
  end
end
