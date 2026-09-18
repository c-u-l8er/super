defmodule Ampd.CoreCanonicalTest do
  use ExUnit.Case, async: true
  alias Ampd.Core

  test "canonical strings preserve existing escape bytes and UTF-8" do
    assert Core.canon("plain") == ~s("plain")
    assert Core.canon("éλ😀") == ~s("éλ😀")
    assert Core.canon(<<0, 11, 31>>) == "\"\\u0000\\u000B\\u001F\""
    assert Core.canon("\"\\\n\r\t\b\f") == "\"\\\"\\\\\\n\\r\\t\\b\\f\""
    assert Core.canon(<<0x2028::utf8, 0x2029::utf8>>) == <<34, 0x2028::utf8, 0x2029::utf8, 34>>
  end

  test "nested canonical ordering and large integer representation stay fixed" do
    value = %{"z" => [true, false, nil, "λ"], "a" => %{"y" => 9_007_199_254_740_993, "x" => -1}}
    expected = ~s({"a":{"x":-1,"y":9007199254740993},"z":[true,false,null,"λ"]})
    assert Core.canon(value) == expected

    assert Core.intent_digest(value) ==
             "sha256:" <> Base.encode16(:crypto.hash(:sha256, expected), case: :lower)
  end

  test "large ASCII input digest keeps the quoted-string identity" do
    input = String.duplicate("a", 65536)
    expected = :crypto.hash(:sha256, ["\"", input, "\""])
    assert Core.intent_digest(input) == "sha256:" <> Base.encode16(expected, case: :lower)

    refute Core.intent_digest(input) ==
             "sha256:" <> Base.encode16(:crypto.hash(:sha256, input), case: :lower)
  end

  test "intent_digest equals the digest of the materialized canonical form" do
    :rand.seed(:exsss, {11, 17, 23})

    pieces = [
      fn -> :binary.copy("a", :rand.uniform(300)) end,
      fn -> <<:rand.uniform(0x7E) - 1>> end,
      fn -> Enum.random(["\"", "\\", "/", "\n", "\t", <<0>>, <<0x7F>>, "é", "λ", "😀"]) end,
      fn ->
        case :rand.uniform(0x10FFFF) - 1 do
          cp when cp in 0xD800..0xDFFF -> "s"
          cp -> <<cp::utf8>>
        end
      end
    ]

    values =
      for _ <- 1..2000 do
        for _ <- 1..:rand.uniform(6), into: "", do: Enum.random(pieces).()
      end

    wrapped = [
      String.duplicate("a", 65536),
      String.duplicate("a", 65536) <> "\"",
      String.duplicate("a", 65536) <> <<0>>,
      %{"input" => String.duplicate("b", 65536), "n" => 1},
      [String.duplicate("c", 1024), true, nil, %{"k" => "v"}]
    ]

    for v <- values ++ wrapped do
      assert Core.intent_digest(v) ==
               "sha256:" <> Base.encode16(:crypto.hash(:sha256, Core.canon(v)), case: :lower)
    end
  end

  test "invalid UTF-8 is refused by the digest exactly as by the canonical form" do
    for v <- [<<0xFF>>, "abc" <> <<0xC3>>, String.duplicate("a", 1000) <> <<0x80>>] do
      canon =
        try do
          {:ok, Core.canon(v)}
        rescue
          e -> {:error, e.__struct__}
        catch
          k, e -> {k, e}
        end

      digest =
        try do
          {:ok, Core.intent_digest(v)}
        rescue
          e -> {:error, e.__struct__}
        catch
          k, e -> {k, e}
        end

      refute match?({:ok, _}, canon)
      assert digest == canon
    end
  end
end
