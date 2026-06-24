defmodule Epix.SessionTest do
  use ExUnit.Case, async: true

  alias Epix.Session

  test "decode_args parses JSON objects and defaults malformed/empty input to %{}" do
    assert Session.decode_args(~s({"x": 1, "y": "z"})) == %{"x" => 1, "y" => "z"}
    # Malformed JSON degrades silently to an empty map (dispatch then surfaces a
    # missing-arg error) rather than crashing the run.
    assert Session.decode_args("{not json") == %{}
    assert Session.decode_args(nil) == %{}
    assert Session.decode_args("") == %{}
    # A non-object JSON value (e.g. a bare array) is also normalized to %{}.
    assert Session.decode_args("[1, 2]") == %{}
  end
end
