defmodule Photon.WS do
    import Bitwise

    def connect(url, headers \\ %{}, opts \\ []) do
        req = build_connect(url, headers)
        uri = URI.parse(url)
        transport = if uri.scheme == "wss", do: :ssl, else: :gen_tcp
        socket = Photon.GenTCP.connect_url(url, opts)
        :ok = transport.send(socket, req)

        #TODO make this nicer :P
        buf = Enum.reduce_while(1..6, %{buf: <<>>}, fn(_, response)->
            {:ok, bin} = transport.recv(socket, 0, 30_000)
            response = %{buf: response.buf <> bin}
            response = Photon.HTTP.Response.parse(response)
            cond do
                response[:step] == :next -> {:halt, response.buf}
                response[:step] in [:next,:body,:headers] and response[:status_code] != 101 ->
                    throw %{error: :ws_connect, detail: url, response: response}
                true -> {:cont, response}
            end
        end)
        ts_m = :os.system_time(1000)
        %{socket: socket, buf: buf, transport: transport, lrx: ts_m,  ltx: ts_m}
    end

    def build_connect(host, headers \\ %{}) do
        uri = URI.parse(host)
        key = Base.encode64(:crypto.strong_rand_bytes(16))
        origin = "#{uri.scheme}://#{uri.host}"
        origin = if uri.port, do: origin<>":#{uri.port}", else: origin
        headers2 = %{
            "Connection"=> "upgrade",
            "Upgrade"=> "websocket",
            "Host"=> uri.host,
            "Origin"=> origin,
            "Pragma"=> "no-cache",
            "Cache-Control"=> "no-cache",
            "Sec-WebSocket-Version"=> "13",
            "Sec-WebSocket-Key"=> key
        }
        headers = Map.merge(headers2, headers)
        Photon.HTTP.Request.build(
            %{method: "GET", path: uri.path || "/", status_code: 101, headers: headers})
    end

    def handshake(request, opts) do
        wskey = Map.fetch!(request.headers, "sec-websocket-key")
        extensions = String.split(request.headers["sec-websocket-extensions"]||"", "; ")
        |> Enum.into(%{}, fn(line)-> 
            case String.split(line,"=") do
                [v] -> {v,v}
                [k,v] -> {k,v}
            end
        end)
        compress = opts[:compress]
        inject_headers = opts[:inject_headers] || %{}

        headers = %{
            "Upgrade"=> "websocket",
            "Connection"=> "upgrade",
            "Sec-WebSocket-Accept"=> useless_hash(wskey)
        }
        
        state = %{buf: request.buf}
        {state, headers} = if !!extensions["permessage-deflate"] and !!compress do
            state = Map.merge(state, %{
                zinflate: inflate_init(), zdeflate: deflate_init(compress)})
            headers = Map.put(headers, "Sec-WebSocket-Extensions", "permessage-deflate")
            {state, headers}
        else {state, headers} end

        sec_proto = request.headers["sec-websocket-protocol"]
        headers = if sec_proto do
            [proto|_] = String.split(sec_proto, ",")
            Map.put(headers, "sec-websocket-protocol", proto)
        else headers end

        headers = Map.merge(headers, inject_headers)

        reply = Photon.HTTP.Response.build(
            %{status_code: 101, headers: headers})
        {state, reply}
    end

    def useless_hash(wskey) do
        :crypto.hash(:sha, [wskey, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"])
        |> :base64.encode()
    end

    def inflate_init() do
        z = :zlib.open()
        :zlib.inflateInit(z, -15)
        z
    end

    def deflate_init(opts) do
        level = opts[:level] || 1
        mem_level = opts[:mem_level] || 8
        window_bits = opts[:window_bits] || 15
        strategy = opts[:strategy] || :default

        z = :zlib.open()
        :zlib.deflateInit(z, level, :deflated, -window_bits, mem_level, strategy)
        z
    end

    def deflate(z, payload) do
        bin = :zlib.deflate(z, payload, :sync)
        |> :erlang.iolist_to_binary()
        len = byte_size(bin)
        case bin do
            <<body::binary-size(len),0,0,255,255>> -> body
            _ -> bin
        end
    end

    def xor(payload, mask), do: xor(payload, mask<>mask, <<>>)

    def xor(<<>>, _mask, acc), do: acc
    def xor(<<chunk::64, rest::binary>>, m=<<mask::64,_::binary>>, acc), do:
        xor(rest, m, <<acc::binary, (bxor(chunk, mask))::64>>)
    def xor(<<chunk::32, rest::binary>>, m=<<mask::32,_::binary>>, acc), do:
        xor(rest, m, <<acc::binary, (bxor(chunk, mask))::32>>)
    def xor(<<chunk::24, rest::binary>>, m=<<mask::24,_::binary>>, acc), do:
        xor(rest, m, <<acc::binary, (bxor(chunk, mask))::24>>)
    def xor(<<chunk::16, rest::binary>>, m=<<mask::16,_::binary>>, acc), do:
        xor(rest, m, <<acc::binary, (bxor(chunk, mask))::16>>)
    def xor(<<chunk::8, rest::binary>>, m=<<mask::8,_::binary>>, acc), do:
        xor(rest, m, <<acc::binary, (bxor(chunk, mask))::8>>)

    def decode_one(state) do
        case decode_frame(state.buf) do
            {:ok, op, _fin, rsv1, payload, buf} ->
                state = Map.put(state, :buf, buf)
                op = case op do
                    0 -> :bin
                    1 -> :text
                    2 -> :bin
                    8 -> :close
                    9 -> :ping
                    10 -> :pong
                end
                payload = case rsv1 do
                    0 -> payload
                    1 ->
                        :zlib.inflate(state.zinflate, <<payload::binary,0,0,255,255>>)
                        |> :erlang.iolist_to_binary()
                end
                frame = %{op: op, payload: payload}
                {state, frame}
            {:incomplete, _} -> {state, nil}
        end
    end

    def decode_frame(<<f::1, r1::1,_r2::1,_r3::1, op::4, 0::1, 127::7, 
        plen::64, payload::binary-size(plen), rest::binary>>), do: {:ok, op, f, r1, payload, rest}
    def decode_frame(bin = <<_::1, _::1,_::1,_::1, _::4, 0::1, 127::7, _::binary>>), do: {:incomplete, bin}
    def decode_frame(<<f::1, r1::1,_r2::1,_r3::1, op::4, 0::1, 126::7, 
        plen::16, payload::binary-size(plen), rest::binary>>), do: {:ok, op, f, r1, payload, rest}
    def decode_frame(bin = <<_::1, _::1,_::1,_::1, _::4, 0::1, 126::7, _::binary>>), do: {:incomplete, bin}
    def decode_frame(<<f::1, r1::1,_r2::1,_r3::1, op::4, 0::1,
        plen::7, payload::binary-size(plen), rest::binary>>), do: {:ok, op, f, r1, payload, rest}
    
    def decode_frame(<<f::1, r1::1,_r2::1,_r3::1, op::4, 1::1, 127::7, 
        plen::64, mask::4-binary, payload::binary-size(plen), rest::binary>>), do: 
    {:ok, op, f, r1, xor(payload, mask), rest}
    def decode_frame(bin = <<_::1, _::1,_::1,_::1, _::4, 1::1, 127::7, _::binary>>), do: {:incomplete, bin}
    def decode_frame(<<f::1, r1::1,_r2::1,_r3::1, op::4, 1::1, 126::7, 
        plen::16, mask::4-binary, payload::binary-size(plen), rest::binary>>), do: 
    {:ok, op, f, r1, xor(payload, mask), rest}
    def decode_frame(bin = <<_::1, _::1,_::1,_::1, _::4, 1::1, 126::7, _::binary>>), do: {:incomplete, bin}
    def decode_frame(<<f::1, r1::1,_r2::1,_r3::1, op::4, 1::1,
        plen::7, mask::4-binary, payload::binary-size(plen), rest::binary>>), do: 
    {:ok, op, f, r1, xor(payload, mask), rest}
    def decode_frame(bin), do: {:incomplete, bin}

    #error 1000 Normal Closure 
    def encode(:close_normal), do: encode(<<3, 232>>, 0, 8)
    def encode(:ping), do: encode(<<>>, 0, 9)
    def encode(:pong), do: encode(<<>>, 0, 10)

    def encode(:close, bin), do: encode(bin, 0, 8) 
    def encode(:text, bin), do: encode(bin, 0, 1)
    def encode(:text_compress, bin), do: encode(bin, 1, 1)
    def encode(:bin, bin), do: encode(bin, 0, 2)
    def encode(:bin_compress, bin), do: encode(bin, 1, 2)

    def encode(bin, rsv1, type) when byte_size(bin) <= 125, do:
        <<1::1, rsv1::1, 0::1, 0::1, type::4, 0::1, (byte_size(bin))::7, bin::binary>>
    def encode(bin, rsv1, type) when byte_size(bin) <= 65536, do:
        <<1::1, rsv1::1, 0::1, 0::1, type::4, 0::1, 126::7, (byte_size(bin))::16, bin::binary>>
    def encode(bin, rsv1, type), do:
        <<1::1, rsv1::1, 0::1, 0::1, type::4, 0::1, 127::7, (byte_size(bin))::64, bin::binary>>

    def encode_mask(:close_normal), do: encode_mask(<<3, 232>>, 0, 8)
    def encode_mask(:ping), do: encode_mask(<<>>, 0, 9)
    def encode_mask(:pong), do: encode_mask(<<>>, 0, 10)
    def encode_mask(:close, bin), do: encode_mask(bin, 0, 8)
    def encode_mask(:text, bin), do: encode_mask(bin, 0, 1)
    def encode_mask(:text_compress, bin), do: encode_mask(bin, 1, 1)
    def encode_mask(:bin, bin), do: encode_mask(bin, 0, 2)
    def encode_mask(:bin_compress, bin), do: encode_mask(bin, 1, 2)

    def encode_mask(bin, rsv1, type) when byte_size(bin) <= 125, do:
        <<1::1, rsv1::1, 0::1, 0::1, type::4, 1::1, (byte_size(bin))::7, 0::32, bin::binary>>
    def encode_mask(bin, rsv1, type) when byte_size(bin) <= 65536, do:
        <<1::1, rsv1::1, 0::1, 0::1, type::4, 1::1, 126::7, (byte_size(bin))::16, 0::32, bin::binary>>
    def encode_mask(bin, rsv1, type), do:
        <<1::1, rsv1::1, 0::1, 0::1, type::4, 1::1, 127::7, (byte_size(bin))::64, 0::32, bin::binary>>
end
