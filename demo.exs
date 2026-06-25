# Live end-to-end demo against the configured model (see Epix.Model / EPIX_* env).
# Run: source .envrc && mix run demo.exs
Logger.configure(level: :info)

{:ok, session} = Epix.start_session([verbose: true] ++ Epix.Model.from_env())

prompt =
  "Define a reusable Lua tool named `triple` that triples a number using host.add " <>
    "(no multiplication), then run it on 14 and tell me the result."

IO.puts("\n>>> #{prompt}\n")

case Epix.Session.run(session, prompt) do
  {:ok, answer} -> IO.puts("\n=== ANSWER ===\n#{answer}")
  {:error, reason} -> IO.puts("\n=== ERROR ===\n#{inspect(reason)}")
end

IO.puts("\n=== defined tools ===")
IO.inspect(Epix.Lua.Sandbox.list_tools(Epix.Session.sandbox(session)))
