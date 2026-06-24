defmodule EpixTest do
  use ExUnit.Case
  doctest Epix

  test "greets the world" do
    assert Epix.hello() == :world
  end
end
