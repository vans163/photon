defmodule Photon.HTTP do
    def recv(socket, to_recv \\ 0, timeout \\ :infinity) do
        if is_port(socket) do
            {:ok, bin} = :gen_tcp.recv(socket, to_recv, timeout)
            bin
        else
            {:ok, bin} = :ssl.recv(socket, to_recv, timeout)
            bin
        end
    end

    def read_body_all(socket, r) do
        #TODO: add support for chunk-encoding and other fun stuff
        cl = Map.fetch!(r.headers, "content-length")
        |> :erlang.binary_to_integer()
        to_recv = cl - byte_size(r.buf)
        if to_recv > 0 do
            bin = recv(socket, to_recv)
            {%{r|buf: ""}, r.buf<>bin}
        else
            <<bin::binary-size(cl), buf::binary>> = r.buf
            {%{r|buf: buf}, bin}
        end
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
                chunk_size = :httpd_util.hexlist_to_integer('#{chunk_size}')
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
        response = response_next(socket)

        response = cond do
            response.headers["content-length"] ->
                {response, body} = read_body_all(socket, response)
                body = if response.headers["content-encoding"] == "gzip" do :zlib.gunzip(body) else body end

                contentType = response.headers["content-type"]
                json_opts = opts[:json_opts] || [{:labels, :attempt_atom}]
                body = if !!contentType and String.starts_with?(contentType, "application/json") do JSX.decode!(body, json_opts) else body end
                Map.put(response, :body, body)
            true ->
                response
        end

        if is_port(socket) do
            :ok = :gen_tcp.close(socket)
        else
            :ok = :ssl.close(socket)
        end

        response
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
        req = Photon.HTTP.Request.build(%{method: method, path: uri.path || "/", headers: headers, body: body})
        if is_port(socket) do
            :ok = :gen_tcp.send(socket, req)
        else
            :ok = :ssl.send(socket, req)
        end
    end

    def response_next(socket, timeout \\ 30_000, acc \\ %{buf: ""}) do
        bin = if is_port(socket) do
            {:ok, bin} = :gen_tcp.recv(socket, 0, timeout)
            bin
        else
            {:ok, bin} = :ssl.recv(socket, 0, timeout)
            bin
        end
        case Photon.HTTP.Response.parse(%{acc | buf: acc.buf <> bin}) do
            acc = %{step: :body} -> acc
            {:partial, acc} -> response_next(socket, timeout, acc)
            acc -> response_next(socket, timeout, acc)
        end
    end
end
