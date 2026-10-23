require "../terminal_text"
require "./hud"
require "./view"

module Nokizaru
  module Tui
    # The opening screen: the banner and wordmark centered with the HUD,
    # materializing under a static-flicker reveal that settles to a hold. The
    # reveal borrows Jekyll // Hyde's static populate, in Nokizaru's chrome red with
    # no wordmark gradient. A pure renderer: the caller passes the elapsed time and
    # a seed, so any frame is reproducible in a test.
    module Scene
      extend self

      # Static glyphs the reveal flickers through. Generic ASCII noise, not a
      # design-language signature.
      GLITCH = "/\\|=+*%#<>[]".chars

      REVEAL_END = 0.9
      BURST_END  = 1.4
      HOLD       = BURST_END

      STANDBY = "#{Hud::R}○#{Hud::W} STANDBY"
      CHEATS  = [Hud::Cheat.new("any key", "compose"), Hud::Cheat.new("ctrl+c", "quit")]

      # The frame at elapsed seconds: a top-to-bottom static reveal, then a fading
      # all-over burst, then the hold.
      def frame(banner : Array(String), cols : Int32, rows : Int32, elapsed : Float64, seed : Int32) : Array(String)
        settled = base(banner, cols, rows)
        rng = Random.new(seed)
        return reveal(settled, elapsed / REVEAL_END, rng) if elapsed < REVEAL_END
        return burst(settled, (BURST_END - elapsed) / (BURST_END - REVEAL_END) * 0.35, rng) if elapsed < BURST_END

        settled
      end

      def animating?(elapsed : Float64) : Bool
        elapsed < HOLD
      end

      # The settled opening: identity cluster, centered banner and wordmark, STANDBY
      # status and cheatsheet. Routed through View.compose so the trunks draw at the
      # same length as the form and dashboard.
      def base(banner : Array(String), cols : Int32, rows : Int32) : Array(String)
        geo = Layout.measure(cols, rows, 0)
        return centered_banner(banner, cols, rows) unless geo.mode.full?

        View.compose(geo, Hud.identity_rows(geo, CHEATS), banner_middle(banner, geo),
          Hud.bottom([STANDBY], CHEATS, geo))
      end

      # The banner centered in the pane region, as a row-index to content map for
      # compose (the trunks are added by framing).
      private def banner_middle(banner : Array(String), geo : Layout::Geometry) : Hash(Int32, String)
        status_row = geo.status_row || geo.rows
        width = banner.max_of? { |line| TerminalText.width(line) } || 0
        pad = " " * [(geo.pane_width - width) // 2, 0].max
        start = [geo.pane_top + ((geo.pane_height - banner.size) // 2), geo.pane_top].max
        middle = {} of Int32 => String
        banner.each_with_index do |line, index|
          row = start + index
          middle[row] = TerminalText.truncate("#{pad}#{Hud::R}#{line}#{Hud::W}", geo.pane_width) if row < status_row
        end
        middle
      end

      private def centered_banner(banner : Array(String), cols : Int32, rows : Int32) : Array(String)
        frame = Array.new(rows, "")
        width = banner.max_of? { |line| TerminalText.width(line) } || 0
        left = " " * [(cols - width) // 2, 0].max
        top = [(rows - banner.size) // 2, 0].max
        banner.each_with_index do |line, index|
          frame[top + index] = "#{left}#{Hud::R}#{line}#{Hud::W}" if top + index < rows
        end
        frame
      end

      # Cells resolve from the top down behind a static front: clean above, heavy
      # static at the front, a thinning residual below.
      private def reveal(settled : Array(String), progress : Float64, rng : Random) : Array(String)
        front = progress * settled.size
        residual = (1.0 - progress) * 0.08
        settled.map_with_index do |row, index|
          distance = index - front
          if distance > 1
            ""
          elsif distance > -2
            glitch(row, 0.55, rng)
          elsif residual > 0
            glitch(row, residual, rng)
          else
            row
          end
        end
      end

      private def burst(settled : Array(String), intensity : Float64, rng : Random) : Array(String)
        settled.map { |row| glitch(row, intensity, rng) }
      end

      # Replaces a fraction of the row's visible characters with static, keeping SGR
      # color intact.
      private def glitch(row : String, intensity : Float64, rng : Random) : String
        return row if intensity <= 0

        String.build do |io|
          row.scan(TerminalText::TOKEN) do |match|
            token = match[0]
            if token.starts_with?('\e') || token == " "
              io << token
            elsif rng.rand < intensity
              io << GLITCH.sample(rng)
            else
              io << token
            end
          end
        end
      end
    end
  end
end
