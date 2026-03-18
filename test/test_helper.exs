exclude_tags =
  if System.get_env("PARRHESIA_NAK_E2E") == "1" do
    []
  else
    [:nak_e2e]
  end

# Suppress Postgrex disconnect logs that fire during sandbox teardown.
# When a sandbox-owning process exits, the connection pool detects the
# dead client and logs an error asynchronously. This is expected cleanup
# noise, not a real failure — silence it so test output stays pristine.
:logger.add_primary_filter(
  :suppress_sandbox_disconnect,
  {fn
     %{msg: {:string, chars}}, _extra ->
       if :string.find(IO.chardata_to_string(chars), "(DBConnection.ConnectionError)") != :nomatch do
         :stop
       else
         :ignore
       end

     _event, _extra ->
       :ignore
   end, []}
)

# Suppress Req retry warnings (e.g. transient socket closures during tests).
# These are expected when tests tear down HTTP connections mid-flight.
:logger.add_primary_filter(
  :suppress_req_retry,
  {fn
     %{msg: {:string, chars}}, _extra ->
       str = IO.chardata_to_string(chars)

       if :string.find(str, "retry:") != :nomatch or
            :string.find(str, "Req.TransportError") != :nomatch do
         :stop
       else
         :ignore
       end

     _event, _extra ->
       :ignore
   end, []}
)

ExUnit.start(exclude: exclude_tags)
