# Most tests inject their own model_fun, so no provider is ever contacted. These
# stub values only satisfy Epix.Model.default/0, which otherwise requires explicit
# configuration. They are defaults: a real EPIX_MODEL/EPIX_API_KEY (e.g. for the
# llm_live tests below) is left untouched.
System.get_env("EPIX_MODEL") || System.put_env("EPIX_MODEL", "openai:stub")
System.get_env("EPIX_BASE_URL") || System.put_env("EPIX_BASE_URL", "http://localhost")

# Live tests hit the network (and, for LLMs, cost credits), so they never run by
# default. Opt in explicitly:
#
#   * `mix test --include kagi_live`  — requires KAGI_API_KEY
#   * `mix test --include llm_live`   — requires a real EPIX_MODEL/EPIX_API_KEY,
#     e.g. EPIX_MODEL=anthropic:claude-haiku-4-5 EPIX_API_KEY=...
ExUnit.start(exclude: [:kagi_live, :llm_live])
