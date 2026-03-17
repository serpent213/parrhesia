exclude_tags =
  if System.get_env("PARRHESIA_NAK_E2E") == "1" do
    []
  else
    [:nak_e2e]
  end

ExUnit.start(exclude: exclude_tags)
