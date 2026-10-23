module Nokizaru
  module Tui
    # The run summary the HUD shows. The form fills it while composing and the
    # runner fills it once a scan is planned; both produce the same shape so the
    # opening, the form, and the dashboard render it the same way. Header values
    # are never carried here, only ever a count in the switches summary, so no
    # secret can reach the HUD.
    record Profile,
      target : String,
      ip : String,
      modules : String,
      switches : String,
      modules_enabled : Array(String),
      notice : String? = nil
  end
end
