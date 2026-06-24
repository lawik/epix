# Solve.Controller generates the GenServer `handle_info/2` and invokes our
# handler, which follows Solve's convention of returning the next state map
# rather than a `{:noreply, _}` tuple. Dialyzer reads our spec/return against the
# GenServer callback and reports a mismatch; it is correct at runtime under Solve.
[
  {"lib/epix/chat/controller.ex", :callback_spec_type_mismatch},
  {"lib/epix/chat/controller.ex", :invalid_contract}
]
