defmodule PearTest do
  use ExUnit.Case
  doctest Pear

  test "full_hop_chain includes every sender, forwarder, and receiver" do
    assert Pear.Reader.full_hop_chain(["ada", "bob"], "alice") == "bob → ada → alice"
  end
end
