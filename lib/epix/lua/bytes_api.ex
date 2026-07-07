defmodule Epix.Lua.BytesApi do
  @moduledoc """
  Installs the `bytes` table: pure helpers for inspecting and reshaping binary
  data as text.

  Raw bytes cannot cross the model boundary — a tool result is JSON text, and
  non-UTF-8 bytes have no JSON form (they come back as `<unencodable ...>`). These
  helpers let the model *read* binary it obtained elsewhere (a file via `fs.read`,
  a blob via `git.read`, a fetched page) by reformatting it into a legible
  encoding (hex, octal, bits, base64, or an `xxd`-style hexdump), and *constrain*
  how much it pulls in with `slice`. `from_hex`/`from_base64` decode back to raw
  bytes, so the model can also construct binary to `fs.write`.

  The table is always available (like `time`): it is pure computation over Lua
  strings — no I/O, and no capability to gate.
  """

  @width 16

  @doc "Installs `bytes.*` into a Lua state."
  @spec install(Lua.t()) :: Lua.t()
  def install(%Lua{} = lua) do
    lua
    |> Lua.set!(["bytes", "slice"], wrap(&do_slice/1))
    |> Lua.set!(["bytes", "hex"], wrap(&do_hex/1))
    |> Lua.set!(["bytes", "from_hex"], wrap(&do_from_hex/1))
    |> Lua.set!(["bytes", "base64"], wrap(&do_base64/1))
    |> Lua.set!(["bytes", "from_base64"], wrap(&do_from_base64/1))
    |> Lua.set!(["bytes", "octal"], wrap(&do_octal/1))
    |> Lua.set!(["bytes", "bits"], wrap(&do_bits/1))
    |> Lua.set!(["bytes", "hexdump"], wrap(&do_hexdump/1))
  end

  @doc "Renders the bytes API as a markdown list for the system prompt."
  @spec docs() :: String.t()
  def docs() do
    """
    - `bytes.slice(data, offset, len)` — a byte slice (0-based `offset`), clamped to
      the data. Grab a bounded window of a large blob before formatting it.
    - `bytes.hex(data)` / `bytes.from_hex(hex)` — lowercase hex, and back to bytes.
    - `bytes.base64(data)` / `bytes.from_base64(b64)` — Base64, and back to bytes.
    - `bytes.octal(data)` — space-separated octal, one number per byte.
    - `bytes.bits(data)` — space-separated binary, 8 bits per byte.
    - `bytes.hexdump(data[, offset, len])` — an `xxd`-style dump (offset, hex, ASCII).

    Binary data cannot be returned to you directly (results are text) — reformat it
    with these first, e.g. `bytes.hexdump(data, 0, 64)`, where `data` is bytes you
    read elsewhere. `from_hex`/`from_base64` turn an encoding back into raw bytes,
    e.g. to reconstruct a binary file before storing it.
    """
  end

  # Adapts an args -> result function into a Lua host function that returns the
  # single result and leaves the VM untouched.
  defp wrap(fun), do: fn args, lua -> {[fun.(args)], lua} end

  defp do_slice([data, offset, len])
       when is_binary(data) and is_number(offset) and is_number(len),
       do: slice(data, trunc(offset), trunc(len))

  defp do_slice(_args), do: raise(Lua.RuntimeException, "bytes.slice expects (data, offset, len)")

  defp do_hex([data]) when is_binary(data), do: Base.encode16(data, case: :lower)
  defp do_hex(_args), do: raise(Lua.RuntimeException, "bytes.hex expects (data)")

  defp do_from_hex([hex]) when is_binary(hex) do
    case hex |> strip_ws() |> Base.decode16(case: :mixed) do
      {:ok, bytes} -> bytes
      :error -> raise Lua.RuntimeException, "bytes.from_hex: not a valid hex string"
    end
  end

  defp do_from_hex(_args), do: raise(Lua.RuntimeException, "bytes.from_hex expects (hex)")

  defp do_base64([data]) when is_binary(data), do: Base.encode64(data)
  defp do_base64(_args), do: raise(Lua.RuntimeException, "bytes.base64 expects (data)")

  defp do_from_base64([b64]) when is_binary(b64) do
    case Base.decode64(b64, ignore: :whitespace) do
      {:ok, bytes} -> bytes
      :error -> raise Lua.RuntimeException, "bytes.from_base64: not a valid base64 string"
    end
  end

  defp do_from_base64(_args),
    do: raise(Lua.RuntimeException, "bytes.from_base64 expects (base64)")

  defp do_octal([data]) when is_binary(data),
    do: data |> :binary.bin_to_list() |> Enum.map_join(" ", &pad(&1, 3, 8))

  defp do_octal(_args), do: raise(Lua.RuntimeException, "bytes.octal expects (data)")

  defp do_bits([data]) when is_binary(data),
    do: data |> :binary.bin_to_list() |> Enum.map_join(" ", &pad(&1, 8, 2))

  defp do_bits(_args), do: raise(Lua.RuntimeException, "bytes.bits expects (data)")

  defp do_hexdump([data]) when is_binary(data), do: hexdump(data, 0)

  defp do_hexdump([data, offset, len])
       when is_binary(data) and is_number(offset) and is_number(len) do
    start = trunc(offset)
    hexdump(slice(data, start, trunc(len)), start)
  end

  defp do_hexdump(_args),
    do: raise(Lua.RuntimeException, "bytes.hexdump expects (data) or (data, offset, len)")

  # --- helpers -------------------------------------------------------------

  defp slice(data, offset, len) when offset >= 0 and len >= 0 do
    size = byte_size(data)
    start = min(offset, size)
    binary_part(data, start, min(len, size - start))
  end

  defp slice(_data, _offset, _len),
    do: raise(Lua.RuntimeException, "bytes.slice: offset and len must be non-negative")

  defp hexdump(data, base_offset) do
    data
    |> :binary.bin_to_list()
    |> Enum.chunk_every(@width)
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {row, i} -> hexdump_row(row, base_offset + i * @width) end)
  end

  defp hexdump_row(bytes, addr) do
    cells = Enum.map(bytes, &pad(&1, 2, 16)) ++ List.duplicate("  ", @width - length(bytes))
    {left, right} = Enum.split(cells, 8)
    hex = Enum.join(left, " ") <> "  " <> Enum.join(right, " ")
    ascii = bytes |> Enum.map(&printable/1) |> IO.iodata_to_binary()
    "#{pad(addr, 8, 16)}  #{hex}  |#{ascii}|"
  end

  defp printable(byte) when byte >= 32 and byte <= 126, do: <<byte>>
  defp printable(_byte), do: "."

  defp pad(value, width, base) do
    value
    |> Integer.to_string(base)
    |> String.downcase()
    |> String.pad_leading(width, "0")
  end

  defp strip_ws(string), do: String.replace(string, ~r/\s/, "")
end
