defmodule Photon.Util do
    def alphanumeric(string) do
        string
        |> String.to_charlist()
        |> Enum.filter(fn(char)->
            char in 97..122
            || char in 65..90
            || char in 48..57
        end)
        |> List.to_string()
    end

    def alphanumeric_under_dash(string) do
        string
        |> String.to_charlist()
        |> Enum.filter(fn(char)->
            char in 97..122
            || char in 65..90
            || char in 48..57
            || char in [95, 45] #"_-"
        end)
        |> List.to_string()
    end

    def hostname(string) do
        string
        |> String.to_charlist()
        |> Enum.filter(fn(char)->
            char in 97..122
            || char in 48..57
            || char == 45 # -
        end)
        |> List.to_string()
    end

    def sbash(term) do
        term = "#{term}"
        term = String.replace(term, "'", "")
        if term == "" do "" else "'#{term}'" end
    end

    def b3sum(path, format \\ :raw) do
        {b3sum, 0} = System.shell("b3sum --no-names --raw #{U.b(path)}")
        case format do
            :base58 -> Base58.encode(b3sum)
            :hex32 -> Base.hex_encode32(b3sum, padding: false, case: :lower)
            :raw -> b3sum
        end
    end
end

defmodule U do
  def b(term) do
    Photon.Util.sbash(term)
  end
end

defmodule Base58 do
  @alnum ~c(123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz)

  def encode(e) when is_integer(e) or is_float(e) or is_atom(e), do: encode("#{e}")
  # see https://github.com/dwyl/base58/issues/5#issuecomment-459088540
  def encode(<<0, binary::binary>>), do: "1" <> encode(binary)
  def encode(""), do: ""
  # see https://github.com/dwyl/base58/pull/3#discussion_r252291127
  def encode(binary), do: encode(:binary.decode_unsigned(binary), "")
  def encode(0, acc), do: acc
  def encode(n, acc), do: encode(div(n, 58), <<Enum.at(@alnum, rem(n, 58))>> <> acc)

  def decode(""), do: "" # return empty string unmodified
  def decode("\0"), do: "" # treat null values as empty
  def decode(binary), do: decode(binary, 0)
  def decode("", acc), do: :binary.encode_unsigned(acc)
  def decode(<<head, tail::binary>>, acc),
    do: decode(tail, acc * 58 + Enum.find_index(@alnum, &(&1 == head)))

  def decode_to_int(encoded), do: encoded |> decode() |> String.to_integer()
end