# Evaluate Epix.InjectionDetector's offline heuristics against public prompt-
# injection benchmark datasets.
#
#   mix run bench/injection_eval.exs              # default datasets
#   mix run bench/injection_eval.exs deepset      # one dataset by slug
#
# Datasets are RESOLVED, not vendored: each is downloaded once from the public
# Hugging Face datasets-server (no auth) into bench/data/<slug>.jsonl (gitignored)
# and reused on later runs. Delete that file to re-fetch. See bench/README.md.
#
# This measures only the cheap, offline `basic_detect/1` stage — no model calls,
# so no API key or EPIX_MODEL is needed. The model stage is evaluated by the
# tagged live tests instead.

alias Epix.InjectionDetector

# label semantics: 1 = injection (positive), 0 = legitimate (negative).
#
# Nothing here is vendored: every set is resolved on demand into bench/data/
# (gitignored). The downloader pages the datasets-server at 100 rows/request, so
# pull time scales with row count — that, not file size, is why the 327k-row
# `jayavibhav` set is not in the default selection. Pull it explicitly with
# `mix run bench/injection_eval.exs jayavibhav` (or use the faster parquet path
# in bench/README.md).
catalog = %{
  # Canonical, distinct. Train + test combined (662 rows).
  "deepset" => %{hf: "deepset/prompt-injections", splits: ["train", "test"], cap: nil},
  # Broader mix; test split (~2k rows). xTRam1 and jayavibhav share lineage.
  "safeguard" => %{hf: "xTRam1/safe-guard-prompt-injection", splits: ["test"], cap: nil},
  # Large superset (~327k rows / 77MB). Resolvable, just slow over the rows API.
  "jayavibhav" => %{hf: "jayavibhav/prompt-injection", splits: ["test"], cap: nil}
}

# Run all but the large set unless the user names datasets explicitly.
default_slugs = ["deepset", "safeguard"]

data_dir = Path.join(__DIR__, "data")
File.mkdir_p!(data_dir)

defmodule Bench do
  @server "https://datasets-server.huggingface.co/rows"
  @page 100

  # Returns [%{text, label}], from the local cache or by downloading.
  def load(slug, %{hf: hf, splits: splits, cap: cap}, data_dir) do
    path = Path.join(data_dir, "#{slug}.jsonl")

    if File.exists?(path) do
      read_jsonl(path)
    else
      IO.puts("  downloading #{hf} #{inspect(splits)} -> #{Path.relative_to_cwd(path)} ...")
      rows = Enum.flat_map(splits, &download(hf, &1, cap))
      write_jsonl(path, rows)
      rows
    end
  end

  defp download(hf, split, cap), do: download(hf, split, 0, cap, [])

  defp download(hf, split, offset, cap, acc) do
    url =
      "#{@server}?dataset=#{URI.encode_www_form(hf)}" <>
        "&config=default&split=#{split}&offset=#{offset}&length=#{@page}"

    case Req.get(url, retry: :transient, max_retries: 3) do
      {:ok, %{status: 200, body: %{"rows" => rows} = body}} ->
        parsed =
          for %{"row" => r} <- rows, is_binary(r["text"]) do
            %{text: r["text"], label: to_int(r["label"])}
          end

        acc = acc ++ parsed
        total = body["num_rows_total"] || offset + length(rows)

        cond do
          rows == [] -> acc
          cap && length(acc) >= cap -> Enum.take(acc, cap)
          offset + @page >= total -> acc
          true -> download(hf, split, offset + @page, cap, acc)
        end

      other ->
        raise "download failed for #{hf}/#{split} at offset #{offset}: #{inspect(other)}"
    end
  end

  defp to_int(n) when is_integer(n), do: n
  defp to_int(s) when is_binary(s), do: String.to_integer(String.trim(s))

  defp read_jsonl(path) do
    path
    |> File.stream!()
    |> Enum.map(fn line ->
      %{"text" => t, "label" => l} = Jason.decode!(line)
      %{text: t, label: l}
    end)
  end

  defp write_jsonl(path, rows) do
    body = Enum.map_join(rows, "\n", &Jason.encode!(%{text: &1.text, label: &1.label}))
    File.write!(path, body)
  end

  # Confusion matrix of basic_detect/1 (predicted positive = a detection) against
  # the gold label (positive = 1).
  def evaluate(rows) do
    counts =
      Enum.reduce(rows, %{tp: 0, fp: 0, tn: 0, fn: 0}, fn %{text: text, label: label}, acc ->
        predicted_positive? = match?({:error, _}, InjectionDetector.basic_detect(text))

        key =
          case {label, predicted_positive?} do
            {1, true} -> :tp
            {1, false} -> :fn
            {0, true} -> :fp
            {0, false} -> :tn
          end

        Map.update!(acc, key, &(&1 + 1))
      end)

    Map.put(counts, :metrics, metrics(counts))
  end

  defp metrics(%{tp: tp, fp: fp, tn: tn, fn: fn_}) do
    %{
      precision: ratio(tp, tp + fp),
      recall: ratio(tp, tp + fn_),
      fpr: ratio(fp, fp + tn),
      fnr: ratio(fn_, fn_ + tp),
      accuracy: ratio(tp + tn, tp + fp + tn + fn_),
      f1: f1(ratio(tp, tp + fp), ratio(tp, tp + fn_))
    }
  end

  defp ratio(_num, 0), do: 0.0
  defp ratio(num, den), do: num / den

  defp f1(p, r) when p + r == 0, do: 0.0
  defp f1(p, r), do: 2 * p * r / (p + r)

  def pct(x), do: :erlang.float_to_binary(x * 100, decimals: 1) <> "%"
end

# ---

selected =
  case System.argv() do
    [] -> default_slugs
    slugs -> slugs
  end

IO.puts("\nEpix.InjectionDetector — basic_detect/1 vs benchmark datasets\n")

for slug <- selected do
  spec = catalog[slug] || raise "unknown dataset slug: #{slug} (have: #{inspect(Map.keys(catalog))})"
  rows = Bench.load(slug, spec, data_dir)
  pos = Enum.count(rows, &(&1.label == 1))
  neg = length(rows) - pos
  %{tp: tp, fp: fp, tn: tn, fn: fn_, metrics: m} = Bench.evaluate(rows)

  IO.puts("""
  ── #{slug}  (#{spec.hf})
     rows: #{length(rows)}   injections: #{pos}   legitimate: #{neg}
     confusion:  TP=#{tp}  FN=#{fn_}  |  FP=#{fp}  TN=#{tn}
     recall (catch rate) : #{Bench.pct(m.recall)}   (missed injections: FNR #{Bench.pct(m.fnr)})
     precision           : #{Bench.pct(m.precision)}
     false-positive rate : #{Bench.pct(m.fpr)}   (benign wrongly flagged)
     accuracy            : #{Bench.pct(m.accuracy)}   F1: #{Bench.pct(m.f1)}
  """)
end
