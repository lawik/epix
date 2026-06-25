# Evaluate the ProtectAI DeBERTa-v3 prompt-injection classifier (ONNX, run on CPU
# via Ortex — no Python) against the same datasets as bench/injection_eval.exs.
#
#   mix run bench/onnx_eval.exs                 # default sets
#   mix run bench/onnx_eval.exs deepset
#
# Requires the model + tokenizer in bench/data/protectai/ and the dataset caches
# in bench/data/ (run bench/injection_eval.exs first to populate the latter).
# See bench/README.md for the model download.

model_dir = Path.join(__DIR__, "data/protectai")
data_dir = Path.join(__DIR__, "data")
default_slugs = ["deepset", "safeguard"]
max_tokens = 512

unless File.exists?(Path.join(model_dir, "model.onnx")) do
  IO.puts("Missing #{model_dir}/model.onnx — see bench/README.md to download it.")
  System.halt(1)
end

defmodule OnnxBench do
  # 0 = SAFE, 1 = INJECTION (from the model's config.json id2label).
  @injection_label 1

  def load(model_dir, max_tokens) do
    model = Ortex.load(Path.join(model_dir, "model.onnx"))
    {:ok, tok} = Tokenizers.Tokenizer.from_file(Path.join(model_dir, "tokenizer.json"))
    {model, tok, max_tokens}
  end

  # Returns {predicted_injection?, microseconds}.
  def classify({model, tok, max_tokens}, text) do
    {:ok, enc} = Tokenizers.Tokenizer.encode(tok, text)
    ids = Tokenizers.Encoding.get_ids(enc) |> Enum.take(max_tokens)
    mask = Tokenizers.Encoding.get_attention_mask(enc) |> Enum.take(max_tokens)
    types = Tokenizers.Encoding.get_type_ids(enc) |> Enum.take(max_tokens)

    inputs = {
      Nx.tensor([ids], type: :s64),
      Nx.tensor([mask], type: :s64),
      Nx.tensor([types], type: :s64)
    }

    {micros, {logits}} = :timer.tc(fn -> Ortex.run(model, inputs) end)

    label =
      logits
      |> Nx.backend_transfer()
      |> Nx.argmax(axis: -1)
      |> Nx.to_flat_list()
      |> hd()

    {label == @injection_label, micros}
  end

  def read_jsonl(path) do
    path
    |> File.stream!()
    |> Enum.map(fn line ->
      %{"text" => t, "label" => l} = Jason.decode!(line)
      %{text: t, label: l}
    end)
  end

  def metrics(%{tp: tp, fp: fp, tn: tn, fn: fn_}) do
    %{
      precision: ratio(tp, tp + fp),
      recall: ratio(tp, tp + fn_),
      fpr: ratio(fp, fp + tn),
      fnr: ratio(fn_, fn_ + tp),
      accuracy: ratio(tp + tn, tp + fp + tn + fn_),
      f1: f1(ratio(tp, tp + fp), ratio(tp, tp + fn_))
    }
  end

  defp ratio(_n, 0), do: 0.0
  defp ratio(n, d), do: n / d
  defp f1(p, r) when p + r == 0, do: 0.0
  defp f1(p, r), do: 2 * p * r / (p + r)

  def pct(x), do: :erlang.float_to_binary(x * 100, decimals: 1) <> "%"
end

selected = if System.argv() == [], do: default_slugs, else: System.argv()

IO.puts("\nProtectAI deberta-v3 (ONNX/Ortex, CPU) vs benchmark datasets\n")
IO.puts("loading model ...")
engine = OnnxBench.load(model_dir, max_tokens)

for slug <- selected do
  path = Path.join(data_dir, "#{slug}.jsonl")

  unless File.exists?(path) do
    IO.puts("── #{slug}: no cache at #{Path.relative_to_cwd(path)} — run bench/injection_eval.exs first.")
    System.halt(1)
  end

  rows = OnnxBench.read_jsonl(path)
  pos = Enum.count(rows, &(&1.label == 1))

  {counts, total_micros} =
    Enum.reduce(rows, {%{tp: 0, fp: 0, tn: 0, fn: 0}, 0}, fn %{text: text, label: label}, {acc, t} ->
      {predicted?, micros} = OnnxBench.classify(engine, text)

      key =
        case {label, predicted?} do
          {1, true} -> :tp
          {1, false} -> :fn
          {0, true} -> :fp
          {0, false} -> :tn
        end

      {Map.update!(acc, key, &(&1 + 1)), t + micros}
    end)

  m = OnnxBench.metrics(counts)
  %{tp: tp, fp: fp, tn: tn, fn: fn_} = counts
  avg_ms = total_micros / max(length(rows), 1) / 1000

  IO.puts("""
  ── #{slug}
     rows: #{length(rows)}   injections: #{pos}   legitimate: #{length(rows) - pos}
     confusion:  TP=#{tp}  FN=#{fn_}  |  FP=#{fp}  TN=#{tn}
     recall (catch rate) : #{OnnxBench.pct(m.recall)}   (FNR #{OnnxBench.pct(m.fnr)})
     precision           : #{OnnxBench.pct(m.precision)}
     false-positive rate : #{OnnxBench.pct(m.fpr)}
     accuracy            : #{OnnxBench.pct(m.accuracy)}   F1: #{OnnxBench.pct(m.f1)}
     avg latency / text  : #{:erlang.float_to_binary(avg_ms, decimals: 1)} ms (CPU)
  """)
end
