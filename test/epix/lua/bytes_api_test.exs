defmodule Epix.Lua.BytesApiTest do
  @moduledoc "Exercises the always-on `bytes` binary helpers through the Sandbox."
  use ExUnit.Case, async: true

  alias Epix.Lua.Sandbox

  setup do
    {:ok, s} = Sandbox.start_link()
    %{sandbox: s}
  end

  describe "encodings" do
    test "hex round-trips", %{sandbox: s} do
      assert {:ok, ~s("deadbeef")} = Sandbox.eval(s, ~S|return bytes.hex("\xde\xad\xbe\xef")|)
      assert {:ok, ~s("abc")} = Sandbox.eval(s, ~S|return bytes.from_hex("616263")|)
    end

    test "from_hex tolerates whitespace and mixed case", %{sandbox: s} do
      assert {:ok, ~s("abc")} = Sandbox.eval(s, ~S|return bytes.from_hex("61 62 63")|)
      assert {:ok, ~s("abc")} = Sandbox.eval(s, ~S|return bytes.from_hex("616263")|)
    end

    test "base64 round-trips", %{sandbox: s} do
      assert {:ok, ~s("aGVsbG8=")} = Sandbox.eval(s, ~S|return bytes.base64("hello")|)
      assert {:ok, ~s("hello")} = Sandbox.eval(s, ~S|return bytes.from_base64("aGVsbG8=")|)
    end

    test "octal and bits render one group per byte", %{sandbox: s} do
      assert {:ok, ~s("101 102")} = Sandbox.eval(s, ~S|return bytes.octal("AB")|)
      assert {:ok, ~s("01000001 01000010")} = Sandbox.eval(s, ~S|return bytes.bits("AB")|)
    end

    test "invalid input raises a readable error", %{sandbox: s} do
      assert {:error, msg} = Sandbox.eval(s, ~S|return bytes.from_base64("!!!not base64!!!")|)
      assert msg =~ "base64"

      assert {:error, hex} = Sandbox.eval(s, ~S|return bytes.from_hex("xyz")|)
      assert hex =~ "hex"
    end
  end

  describe "slice" do
    test "grabs a 0-based window, clamped to the data", %{sandbox: s} do
      assert {:ok, ~s("ell")} = Sandbox.eval(s, ~S|return bytes.slice("hello", 1, 3)|)
      # len past the end is clamped
      assert {:ok, ~s("lo")} = Sandbox.eval(s, ~S|return bytes.slice("hello", 3, 999)|)
      # offset past the end yields empty
      assert {:ok, ~s("")} = Sandbox.eval(s, ~S|return bytes.slice("hello", 99, 4)|)
    end
  end

  describe "hexdump" do
    test "renders an xxd-style dump with ascii gutter", %{sandbox: s} do
      # "ABC" plus a NUL: hex + printable ascii, non-printable shown as '.'
      assert {:ok, json} = Sandbox.eval(s, ~S|return bytes.hexdump("ABC\0")|)
      dump = Jason.decode!(json)
      assert dump =~ "00000000"
      assert dump =~ "41 42 43 00"
      assert dump =~ "|ABC.|"
    end

    test "a bounded slice keeps the absolute offset in the address column", %{sandbox: s} do
      assert {:ok, json} =
               Sandbox.eval(s, ~S|return bytes.hexdump(string.rep("x", 40), 16, 4)|)

      dump = Jason.decode!(json)
      assert dump =~ "00000010"
      assert dump =~ "78 78 78 78"
    end
  end

  test "the bytes table is available without any capabilities configured", %{sandbox: s} do
    # A bare sandbox (no store/web/git/fs) still exposes bytes.
    assert {:ok, ~s("6869")} = Sandbox.eval(s, ~S|return bytes.hex("hi")|)
  end
end
