# frozen_string_literal: true

module Nokizaru
  module TUI
    # The opening screen: the banner and wordmark centered with the HUD, materializing under a static-flicker
    # reveal that settles to a hold. The reveal borrows Jekyll // Hyde's static populate, in Nokizaru's chrome red
    # with no wordmark gradient. A pure renderer: the app passes the clock, so any frame is reproducible in a test
    module Scene
      module_function

      # Static glyphs the reveal flickers through. Generic ASCII noise, not a design-language signature
      GLITCH = '/\\|=+*%#<>[]'.chars.freeze
      REVEAL_END = 0.9
      BURST_END = 1.4
      HOLD = BURST_END

      STANDBY = "#{Hud::R}○#{Hud::W} STANDBY".freeze
      CHEATS = [['any key', 'compose'], ['ctrl+c', 'quit']].freeze

      # The frame at elapsed seconds: a top-to-bottom static reveal, then a fading all-over burst, then the hold
      def frame(profile, banner, cols, rows, elapsed, seed)
        base = base(profile, banner, cols, rows)
        rng = Random.new(seed)
        return reveal(base, elapsed / REVEAL_END, rng) if elapsed < REVEAL_END
        return burst(base, (BURST_END - elapsed) / (BURST_END - REVEAL_END) * 0.35, rng) if elapsed < BURST_END

        base
      end

      def animating?(elapsed)
        elapsed < HOLD
      end

      # The settled opening: identity cluster, centered banner and wordmark, STANDBY status and cheatsheet.
      # Routed through View.compose so the left and right trunks draw at the same length as the form and dashboard
      def base(profile, banner, cols, rows)
        geo = Layout.measure(cols, rows, 0)
        return centered_banner(banner, cols, rows) unless geo.mode == :full

        View.compose(geo, Hud.identity_rows(geo, CHEATS), banner_middle(banner, geo),
                     Hud.bottom(profile_status(profile), CHEATS, geo))
      end

      def profile_status(_profile)
        STANDBY
      end

      # The banner centered in the pane region, as a row hash for compose (the trunks are added by framing)
      def banner_middle(banner, geo)
        width = banner.map { |line| TerminalText.width(line) }.max.to_i
        pad = ' ' * [(geo.pane_width - width) / 2, 0].max
        start = [geo.pane_top + ((geo.pane_height - banner.length) / 2), geo.pane_top].max
        middle = {}
        banner.each_with_index do |line, index|
          row = start + index
          middle[row] = TerminalText.truncate("#{pad}#{Hud::R}#{line}#{Hud::W}", geo.pane_width) if row < geo.status_row
        end
        middle
      end

      def centered_banner(banner, cols, rows)
        frame = Array.new(rows, '')
        width = banner.map { |line| TerminalText.width(line) }.max.to_i
        left = ' ' * [(cols - width) / 2, 0].max
        top = [(rows - banner.length) / 2, 0].max
        banner.each_with_index do |line, index|
          frame[top + index] = "#{left}#{Hud::R}#{line}#{Hud::W}" if top + index < rows
        end
        frame
      end

      # Cells resolve from the top down behind a static front: clean above, heavy static at the front, empty below
      def reveal(base, progress, rng)
        front = progress * base.length
        residual = (1.0 - progress) * 0.08
        base.each_with_index.map do |row, index|
          distance = index - front
          next '' if distance > 1
          next glitch(row, 0.55, rng) if distance > -2

          residual.positive? ? glitch(row, residual, rng) : row
        end
      end

      def burst(base, intensity, rng)
        base.map { |row| glitch(row, intensity, rng) }
      end

      # Replaces a fraction of the row's visible characters with static, keeping SGR color intact
      def glitch(row, intensity, rng)
        return row if intensity <= 0

        row.scan(TerminalText::TOKEN).map do |token|
          next token if token.getbyte(0) == 27 || token == ' '

          rng.rand < intensity ? GLITCH.sample(random: rng) : token
        end.join
      end
    end
  end
end
