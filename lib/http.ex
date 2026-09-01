defmodule Photon.HTTP do
    def read_body_all(socket, r) do
        cond do
            String.contains?(r.headers["transfer-encoding"]||"", "chunked") ->
                {leftover, body} = read_body_chunked(socket, r.buf, <<>>)
                {%{r|buf: leftover}, body}

            true ->
                cl = Map.fetch!(r.headers, "content-length")
                |> :erlang.binary_to_integer()
                to_recv = cl - byte_size(r.buf)
                if to_recv > 0 do
                    bin = Photon.GenTCP.recv(socket, to_recv)
                    {%{r|buf: ""}, r.buf<>bin}
                else
                    <<bin::binary-size(cl), buf::binary>> = r.buf
                    {%{r|buf: buf}, bin}
                end
        end
    end

    #chunked transfer bounded by chunk framing (keep-alive safe); leftover buf returned
    def read_body_chunked(socket, buf, acc) do
        case :binary.split(buf, "\r\n") do
            [size_line, rest] ->
                [hexsize | _] = :binary.split(size_line, ";")
                size = :erlang.binary_to_integer(String.trim(hexsize), 16)
                if size == 0 do
                    {read_chunk_trailer(socket, rest), acc}
                else
                    {chunk, rest} = take_bytes(socket, rest, size + 2)
                    <<data::binary-size(size), _crlf::binary>> = chunk
                    read_body_chunked(socket, rest, acc<>data)
                end
            [partial] ->
                read_body_chunked(socket, partial <> Photon.GenTCP.recv(socket, 0, 30_000), acc)
        end
    end

    #consume optional trailer headers up to the terminating empty line
    def read_chunk_trailer(socket, buf) do
        case :binary.split(buf, "\r\n") do
            ["", rest] -> rest
            [_line, rest] -> read_chunk_trailer(socket, rest)
            [partial] -> read_chunk_trailer(socket, partial <> Photon.GenTCP.recv(socket, 0, 30_000))
        end
    end

    def take_bytes(_socket, buf, n) when byte_size(buf) >= n do
        {:erlang.binary_part(buf, 0, n), :erlang.binary_part(buf, n, byte_size(buf) - n)}
    end
    def take_bytes(socket, buf, n) do
        take_bytes(socket, buf <> Photon.GenTCP.recv(socket, 0, 30_000), n)
    end

    def read_body_all_json(socket, r, json_args \\ [{:labels, :attempt_atom}]) do
        {r, bin} = read_body_all(socket, r)
        {r, JSX.decode!(bin, json_args)}
    end

    def download_chunks(state, f) do
        r = state.request
        cond do
            r.headers["content-length"] ->
                cl = Map.fetch!(r.headers, "content-length") |> :erlang.binary_to_integer()
                to_recv = cl - byte_size(r.buf)
                if to_recv > 0 do
                    :ok = :file.write(f, r.buf)
                    download_chunks_1(state, f, to_recv)
                else
                    <<bin::binary-size(cl), buf::binary>> = r.buf
                    :ok = :file.write(f, bin)
                    put_in(state, [:request, :buf], buf)
                end
            #r.headers["transfer-encoding"] == "chunked" ->
            true -> download_chunked_encoding(state, f)
        end
    end

    defp download_chunks_1(state, f, to_recv) do
        #TODO: autoscale bigger buffer for faster inet
        chunk = min(to_recv, 8_388_608)
        {:ok, bin} = :gen_tcp.recv(state.socket, chunk, 120_000)
        recv_size = byte_size(bin)
        left = to_recv - recv_size
        if left > 0 do
            :ok = :file.write(f, bin)
            download_chunks_1(state, f, left)
        else
            <<payload::binary-size(to_recv), buf::binary>> = bin
            :ok = :file.write(f, payload)
            put_in(state, [:request, :buf], buf)
        end
    end

    defp download_chunked_encoding(state, f) do
        case :binary.split(state.request.buf, <<13,10>>) do
            ["",""] -> :ok
            ["0", rest] ->
                state = put_in(state, [:request, :buf], rest)
                download_chunked_encoding(state, f)
            [chunk_size, rest] ->
                chunk_size = :erlang.binary_to_integer(chunk_size, 16)
                case rest do
                    <<bin::binary-size(chunk_size), "\r\n", rest::binary>> ->
                        :ok = :file.write(f, bin)
                        state = put_in(state, [:request, :buf], rest)
                        download_chunked_encoding(state, f)
                    _ ->
                        {:ok, extra} = :gen_tcp.recv(state.socket, 0, 120_000)
                        state = put_in(state, [:request, :buf], state.request.buf<>extra)
                        download_chunked_encoding(state, f)
                end
            [bin] ->
                if byte_size(bin) > 16 do
                    throw %{error: :photon_chunked_encoding_no_chunk}
                end
                {:ok, extra} = :gen_tcp.recv(state.socket, 0, 120_000)
                state = put_in(state, [:request, :buf], state.request.buf<>extra)
                download_chunked_encoding(state, f)
        end
    end

    def read_body_to_file(state, path) do
        File.mkdir_p!(Path.dirname(path))
        {:ok, f} = :file.open(path, [:raw, :write])
        state = download_chunks(state, f)
        :file.close(f)
        state
    end

    def parse_query(query, to_atom \\ true) do
        String.split(query, "&")
        |> Enum.into(%{}, fn(line)->
            [k,v] = :binary.split(line, "=")
            k = if !to_atom do k else
                try do
                    String.to_existing_atom(k)
                catch _,_ -> k end
            end
            {k,v}
        end)
    end

    def merge_query_body(socket, r, query) do
        if r.method in ["PUT", "POST", "PATCH"] do
            {r, json} = read_body_all_json(socket, r)
            {r, Map.merge(query||%{}, json)}
        else {r, query} end
    end

    def sanitize_path(path) do
        dir = :filename.dirname(path)
        |> :re.replace("[^0-9A-Za-z\\-\\_\\/]", "", [:global, {:return, :binary}])
        filename = :filename.basename(path)
        |> :re.replace("[^0-9A-Za-z\\-\\_\\.]", "", [:global, {:return, :binary}])
        
        sanitize_path_1("#{dir}/#{filename}")
    end

    defp sanitize_path_1(path) do
        path = :binary.replace(path,"//","/")
        case :binary.match(path,"//") do
            :nomatch ->
                case path do
                    <<"/", path::binary>> -> path
                    _ -> path
                end
            _ -> sanitize_path_1(path)
        end
    end

    def request(method, url, headers \\ %{}, body \\ nil, opts \\ %{}) do
        socket = Photon.GenTCP.connect_url(url, opts[:inet_opts]||[])

        request_next(socket, method, url, headers, body, opts)
        timeout = opts[:timeout] || 30_000
        response = response_next(socket, timeout)

        response = proc_response_body(socket, response, opts)

        case socket do
            socket when is_tuple(socket) and :erlang.element(1, socket) == :sslsocket -> :ok = :ssl.close(socket)
            _ -> :ok = :gen_tcp.close(socket)
        end

        response
    end

    #keep-alive: run many requests over a caller-owned socket (Photon.GenTCP.connect_url);
    #the socket is NOT closed here — on errors close it (Photon.GenTCP.close) and reconnect
    def request_on(socket, method, url, headers \\ %{}, body \\ nil, opts \\ %{}) do
        headers = Map.merge(%{"Connection"=> "keep-alive"}, headers)
        request_next(socket, method, url, headers, body, opts)
        timeout = opts[:timeout] || 30_000
        response = response_next(socket, timeout)
        proc_response_body(socket, response, opts)
    end

    def proc_response_body(socket, response, opts) do
        cond do
            response.headers["content-length"] || String.contains?(response.headers["transfer-encoding"]||"", "chunked") ->
                {response, body} = read_body_all(socket, response)
                body = if response.headers["content-encoding"] == "gzip" do :zlib.gunzip(body) else body end

                contentType = response.headers["content-type"]
                json_opts = opts[:json_opts] || [{:labels, :attempt_atom}]
                body = if !!contentType and String.starts_with?(contentType, "application/json") do JSX.decode!(body, json_opts) else body end
                Map.put(response, :body, body)
            true ->
                response
        end
    end

    def request_next(socket, method, url, headers \\ %{}, body \\ nil, _opts \\ %{}) do
        uri = URI.parse(url)
        body = if is_nil(body) or is_binary(body) do body else JSX.encode!(body) end
        headers = %{
            "Host"=> uri.host,
            "Connection"=> "close",
        }
        |> case do h when is_binary(body)-> Map.put(h, "Content-Length", byte_size(body)); h-> h end
        |> Map.merge(headers)
        path = (uri.path || "/") <> (if uri.query, do: "?"<>uri.query, else: "")
        req = Photon.HTTP.Request.build(%{method: method, path: path, headers: headers, body: body})
        case socket do
            socket when is_tuple(socket) and :erlang.element(1, socket) == :sslsocket -> :ok = :ssl.send(socket, req)
            _ -> :ok = :gen_tcp.send(socket, req)
         end
    end

    def response_next(socket, timeout \\ 30_000, acc \\ %{buf: ""}) do
        bin = Photon.GenTCP.recv(socket, 0, timeout)
        case Photon.HTTP.Response.parse(%{acc | buf: acc.buf <> bin}) do
            acc = %{step: :body} -> acc
            {:partial, acc} -> response_next(socket, timeout, acc)
            acc -> response_next(socket, timeout, acc)
        end
    end
end
